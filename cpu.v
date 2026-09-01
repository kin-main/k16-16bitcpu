/*==============================================================================
 * モジュール名 : cpu
 * 概要         : k16 16bit RISC CPU コア (ノイマン型・BRAM同期読み出し対応版)
 *
 * 【設計方針の変更点】
 * 旧版は「メモリはアドレスを出した"同じサイクル"でデータが返る」という
 * 組み合わせ読み出し前提で作られていたが、実機FPGA(Tang Nano 9K)の
 * BRAMは「アドレスを出した"次のサイクル"でデータが返る」同期読み出ししか
 * 使えない(でないとD-FF不足でエラーになる)。
 *
 * そこで本版では、RAM自体の1サイクル遅延を「メモリバスの自然な特性」として
 * そのまま受け入れ、CPU側でそのタイミングに合わせてデコード・実行を行う
 * ように設計を変更した。
 *
 * 【キーアイデア】
 * 「mem_addrを出す→次サイクルでmem_rdataに返る」を、CPU内部で二重に
 * ラッチする(旧版のバグ)のではなく、返ってきたmem_rdataを"そのまま"
 * decoderに渡して即座にデコード・実行する。これにより通常命令は
 * 今まで通り1サイクルで完結できる。
 *
 * Load/Store命令の実行中や、分岐直後の1サイクルだけは、メモリバスが
 * "命令フェッチ"ではなく"データアクセス"や"分岐先アドレスの先読み"に
 * 使われてしまうため、その次に返ってくるmem_rdataは「次に実行すべき
 * 命令」ではない。これを bubble / branch_flush というフラグで検知し、
 * その1サイクルだけ強制的にNOPをdecoderに食わせることでごまかす。
 *
 * 【サイクル数まとめ】
 *   通常のALU演算・条件不成立命令 : 1サイクル
 *   Store命令                    : 1サイクル (書き込みは待ち不要)
 *   Load命令                     : 2サイクル (データ到着を1サイクル待つ)
 *   分岐(PC書き込み)              : 2サイクル (投機フェッチの破棄が1サイクル)
 *============================================================================*/

module cpu (
    input  wire        clk,
    input  wire        rst,

    // 統合メモリインターフェース (ノイマン型: 命令・データ共用の単一バス)
    output wire [15:0] mem_addr,     // メモリアドレス
    output wire [23:0] mem_wdata,    // メモリ書き込みデータ
    input  wire [23:0] mem_rdata,    // メモリ読み出しデータ (1サイクル遅延で返る)
    output wire        mem_we        // メモリ書き込みイネーブル
);

    //==========================================================
    // NOP命令定数
    //==========================================================
    // cond = 3'b100 (NV = Never、実行条件が常に不成立)
    // つまり「何を書いてあっても実行しない」命令として機能する
    localparam NOP_INST = 24'b100_00_0000_0000_0000_0000_000;

    //==========================================================
    // Bubble / Branch-Flush 制御
    //==========================================================
    // bubble       : 直前サイクルがLoad/Storeでバスをデータアクセスに
    //                使ったため、今サイクルのmem_rdataは「命令」ではない
    //                ことを示すフラグ。1のときdecoderにはNOPを渡す。
    // branch_flush : 直前サイクルが分岐(PC書き込み)だったため、今サイクル
    //                のmem_rdataは「分岐前に投機的に読んでしまった命令」
    //                であり、実行してはいけないことを示すフラグ。
    reg bubble;
    reg branch_flush;

    // decoderに実際渡す命令: bubble/branch_flush中は強制的にNOPにすり替える
    wire [23:0] cur_inst = (bubble || branch_flush) ? NOP_INST : mem_rdata;

    //==========================================================
    // デコーダ接続
    //==========================================================
    // decoder.v は完全な組み合わせ回路(assign / always @(*) のみ)なので
    // 「今入力されたcur_instを、今すぐ解釈する」だけの純粋な変換器。
    // クロックの概念を持たないため、cpu.v側のタイミング設計を
    // どう変えても、decoder.v自体は一切変更不要。
    wire [2:0]  cond;          // 実行条件フィールド
    wire [1:0]  op;            // オペコード (00=ALU_R, 01=ALU_I, 11=LD/ST)
    wire [3:0]  rd;            // 宛先レジスタ
    wire [3:0]  rs1;           // ソースレジスタ1 (Load/Storeのbaseにも使用)
    wire [3:0]  rs2;           // ソースレジスタ2 (Store時は書き込みデータ元)
    wire [15:0] imm;           // ゼロ拡張済み即値
    wire [2:0]  alu_funct;     // ALU機能選択
    wire        is_alu_reg;    // レジスタ間演算命令か
    wire        is_alu_imm;    // レジスタ即値演算命令か
    wire        is_load;       // Load命令か
    wire        is_store;      // Store命令か
    wire        alu_src_imm;   // ALU第2オペランドに即値を使うか
    wire        reg_write_req; // レジスタ書き込み要求 (条件判定前の生の要求)
    wire        flag_write_req;// フラグ更新要求 (条件判定前)

    decoder u_decoder (
        .inst          (cur_inst),
        .cond          (cond),
        .op            (op),
        .rd            (rd),
        .rs1           (rs1),
        .rs2           (rs2),
        .imm           (imm),
        .alu_funct     (alu_funct),
        .is_alu_reg    (is_alu_reg),
        .is_alu_imm    (is_alu_imm),
        .is_load       (is_load),
        .is_store      (is_store),
        .alu_src_imm   (alu_src_imm),
        .reg_write     (reg_write_req),
        .flag_write    (flag_write_req)
    );

    //==========================================================
    // 条件判定 (Sub-Decoder)
    //==========================================================
    // cond (3bit) と 現在のALUフラグ(zf,cf,nf) を比較し、
    // この命令を実際に実行してよいか(cond_match)を判定する。
    // cur_instがNOP(bubble/branch_flush中)の場合、cond=100(NV)なので
    // cond_matchは自動的に0になる。
    wire cond_match;

    cond_check u_cond_check (
        .cond   (cond),
        .zf     (zf),
        .cf     (cf),
        .nf     (nf),
        .match  (cond_match)
    );

    //==========================================================
    // レジスタファイル接続
    //==========================================================
    wire [15:0] pc;             // 現在のPC (regfile内部のr15)
    wire [15:0] rddata_a;       // 読み出しポートA (rs1に対応)
    wire [15:0] rddata_b;       // 読み出しポートB (rs2に対応)
    wire [15:0] wtdata;         // 書き込みデータ
    wire [7:0]  topout;         // r13[7:0] (Store時、メモリ上位8bitに使用)
    wire        wtenable;       // 書き込みイネーブル
    wire        topenable;      // r13[7:0]書き込みイネーブル (Load時)
    wire [3:0]  wtaddr;         // 書き込み先レジスタ番号

    // 条件成立かつLoad/Store: このサイクルでメモリバスをデータアクセスに使う
    wire is_active_load  = cond_match && is_load;
    wire is_active_store = cond_match && is_store;
    wire is_active_mem   = is_active_load || is_active_store;

    // 条件成立かつ宛先がr15(PC): 分岐(ジャンプ)命令が実際に実行される
    wire is_branch = cond_match && reg_write_req && (rd == 4'd15);

    // pc_hold: Load/Store実行中はメモリバスがふさがるため、
    // PCの+1を1サイクル止めて、次サイクルに正しく命令を再フェッチできる
    // ようにする (regfile.v は既存のこのインターフェースをそのまま使える)
    wire pc_hold = is_active_mem;

    regfile u_regfile (
        .clk           (clk),
        .rst           (rst),
        .zf            (zf),
        .cf            (cf),
        .nf            (nf),
        .wtdata        (wtdata),
        .wtenable      (wtenable),
        .wtaddr        (wtaddr),
        .topin         (mem_rdata[23:16]), // Load時: メモリ24bitの上位8bit
        .topenable     (topenable),
        .topout        (topout),           // Store時: r13[7:0]をメモリ上位8bitへ
        .rdaddr_a      (rs1),
        .rdaddr_b      (rs2),
        .rddata_a      (rddata_a),
        .rddata_b      (rddata_b),
        .pc            (pc),
        .pc_hold       (pc_hold)
    );

    //==========================================================
    // ALU 接続
    //==========================================================
    // 【フォワーディング不要になった理由】
    // 旧版はパイプラインが2段に重なっており、直前の命令の結果がまだ
    // レジスタに書き戻される前に次の命令がそれを読もうとする
    // RAWハザードが発生しえたため、フォワーディング回路が必要だった。
    // 新版は「1つの命令が完全に完了してから次の命令のフェッチが
    // 始まる」ため、この種のハザードは原理的に発生しない。
    wire [15:0] alu_in_a = rddata_a;
    wire [15:0] alu_in_b = alu_src_imm ? imm : rddata_b;
    wire [15:0] alu_result;
    wire        zf, cf, nf;

    // フラグ更新は「条件成立」かつ「フラグ書き込み要求あり」かつ
    // 「NOP実行中(bubble/branch_flush)ではない」ときだけ行う。
    // NOP中に誤ってフラグを上書きしてしまうと、直前の本物の命令の
    // 結果(条件分岐などで後から参照される)を壊してしまうため。
    wire flag_en = cond_match && flag_write_req && !bubble && !branch_flush;

    alu u_alu (
        .clk           (clk),
        .rst           (rst),
        .flag_en       (flag_en),
        .A             (alu_in_a),
        .B             (alu_in_b),
        .funct         (alu_funct),
        .result        (alu_result),
        .Z             (zf),
        .C             (cf),
        .N             (nf)
    );

    //==========================================================
    // メモリバス出力 (アドレス・書き込みデータ・書き込みイネーブル)
    //==========================================================
    // mem_addr の優先順位:
    //   1. 分岐が成立した瞬間     → ジャンプ先アドレス(alu_result)を先読み
    //   2. Load/Storeが成立した瞬間 → データアクセス先アドレス(alu_result)
    //   3. それ以外(通常フェッチ)  → 現在のPC
    // ※ 分岐命令とLoad/Store命令が同時に成立することは仕様上ないため
    //   優先順位自体は実質的に問題にならない(念のため明示している)。
    assign mem_addr  = is_branch     ? alu_result :
                        is_active_mem ? alu_result :
                                        pc;

    // Store時の書き込みデータ: 上位8bit=r13[7:0], 下位16bit=書き込むレジスタ値
    // (デコーダ側でStore時はrs2=rdとなるよう配線されているため、
    //  rddata_bが「書き込みたいデータ」になる)
    assign mem_wdata = {topout, rddata_b};

    // 書き込みイネーブル: 条件成立かつStore命令のときだけ1
    assign mem_we    = is_active_store;

    //==========================================================
    // Load結果の遅延書き込み制御
    //==========================================================
    // Loadはアドレスを出した"次"のサイクルにならないとデータが
    // 届かない(BRAMの同期読み出し遅延)。そこで「直前のサイクルが
    // Loadだったか」「そのときの宛先レジスタは何だったか」を
    // 1サイクル分だけ記憶しておき、データが届いたサイクルで
    // それを使ってレジスタに書き込む。
    reg       prev_was_load;   // 直前サイクルがLoad成立だったか
    reg [3:0] prev_load_rd;    // 直前サイクルのLoad宛先レジスタ番号

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            prev_was_load <= 1'b0;
            prev_load_rd  <= 4'd0;
        end else begin
            prev_was_load <= is_active_load; // 今サイクルの状態を次サイクルへ持ち越す
            prev_load_rd  <= rd;             // 今サイクルの宛先を記憶
        end
    end

    //==========================================================
    // レジスタ書き込み・PC制御用の各信号
    //==========================================================
    // wtaddr: 直前がLoadなら「そのときの宛先」、そうでなければ「今の宛先」
    assign wtaddr    = prev_was_load ? prev_load_rd : rd;

    // wtdata: 直前がLoadなら「今届いたメモリデータ」、そうでなければALU結果
    //         (通常のALU演算・分岐・Store時のアドレス計算結果も含む)
    assign wtdata    = prev_was_load ? mem_rdata[15:0] : alu_result;

    // wtenable:
    //   ・直前がLoadだった場合 → 無条件に1 (データが届いたので必ず書く)
    //   ・それ以外の場合       → NOP中でなく、条件成立、書き込み要求あり、
    //                            かつ今回はLoadではない(Loadは次サイクルに
    //                            遅延させるため、ここでは書き込まない)
    assign wtenable  = prev_was_load ? 1'b1
                                      : (!bubble && !branch_flush &&
                                         cond_match && reg_write_req && !is_load);

    // topenable: r13[7:0]への書き込みは、Loadデータが実際に届いたサイクルのみ
    assign topenable = prev_was_load;

    //==========================================================
    // Bubble / Branch-Flush フラグの更新
    //==========================================================
    // 「今サイクルの状態」を、そのまま「次サイクルのフラグ」として
    // 1クロック遅延させて保持するだけのシンプルなロジック。
    // これにより、メモリバスが命令フェッチ以外に使われた次のサイクルで
    // 確実にNOPが挿入される。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bubble       <= 1'b0;
            branch_flush <= 1'b0;
        end else begin
            bubble       <= is_active_mem; // 今Load/Storeなら次サイクルはbubble
            branch_flush <= is_branch;     // 今分岐なら次サイクルはflush
        end
    end

endmodule
