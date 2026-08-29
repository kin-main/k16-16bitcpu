/*==============================================================================
 * モジュール名 : cpu
 * 概要         : k16 16bit RISC 2段パイプライン CPU コア (ノイマン型アーキテクチャ)
 * 
 * 【アーキテクチャの特徴】
 * 1. 2段パイプライン:
 *    - Stage 1 (IF/ID)     : 命令フェッチ & デコード
 *    - Stage 2 (EX/MEM/WB) : 条件判定、ALU演算、メモリアクセス、レジスタ書き戻し
 * 
 * 2. ノイマン型単一バス調停 (ステートマシン不要のKISS設計):
 *    - 命令フェッチとデータアクセスで単一の共有メモリバス(mem_addr等)を使用。
 *    - 通常の命令 (ALU演算/分岐等) : 毎サイクル 1命令 (1クロック) で完了。
 *    - Load / Store 命令の実行時   : 
 *        1) 実行サイクルでバスを「データアクセス」に割り当てる (mem_addr = ALU結果)。
 *        2) このサイクルは命令フェッチができないため、次サイクルの命令レジスタ (ir)
 *           に強制的に NOP (バブル) を挿入し、PC (+1) を1サイクル停止 (pc_hold)。
 *        3) 次サイクルでバスが空き、保持していたPCで正しく次命令を再フェッチ。
 *      => 明示的なFSM (ステートマシン) を一切使わず、組み合わせ論理の切り替えと
 *         NOP挿入だけで自然に「Load/Store = 2クロック」の動作を実現しています。
 *============================================================================*/

module cpu (
    input  wire        clk,
    input  wire        rst,

    // 統合メモリインターフェース (ノイマン型: 命令・データ共用の単一バス)
    output wire [15:0] mem_addr,     // メモリアドレス (命令フェッチ時=PC, データアクセス時=ALU結果)
    output wire [23:0] mem_wdata,    // メモリ書き込みデータ
    input  wire [23:0] mem_rdata,    // メモリ読み出しデータ (命令 or データ)
    output wire        mem_we        // メモリ書き込みイネーブル
);

    //==========================================================
    // パイプラインレジスタ & 内部信号
    //==========================================================

    // Stage 1 (Fetch / Decode) -> Stage 2 (Execute)
    reg  [23:0] ir;                  // 命令レジスタ (Instruction Register)

    // デコーダ出力信号
    wire [2:0]  cond;
    wire [1:0]  op;
    wire [3:0]  rd;
    wire [3:0]  rs1;
    wire [3:0]  rs2;
    wire [15:0] imm;
    wire [2:0]  alu_funct;
    wire        is_alu_reg;
    wire        is_alu_imm;
    wire        is_load;
    wire        is_store;
    wire        alu_src_imm;
    wire        reg_write_req;
    wire        flag_write_req;

    // 条件判定
    wire        cond_match;

    // レジスタファイル信号
    wire [15:0] pc;
    wire [15:0] rddata_a;
    wire [15:0] rddata_b;
    wire [7:0]  topout;
    wire [15:0] wtdata;
    wire        wtenable;
    wire [3:0]  wtaddr;
    wire        topenable;

    // ALU信号
    wire [15:0] alu_result;
    wire        zf;
    wire        cf;
    wire        nf;
    wire        flag_en;

    // フォワーディング用レジスタ
    reg  [3:0]  prev_wtaddr;
    reg  [15:0] prev_wtdata;
    reg         prev_wtenable;

    //==========================================================
    // ノイマン型 単一メモリバスの調停 (ステートマシン不要の2クロック制御)
    //==========================================================
    //
    // 【なぜFSM(ステートマシン)なしで2クロック動作ができるのか？】
    // 1. is_mem_access の判定:
    //    実行中の命令が「条件成立した Load または Store」のとき 1 になります。
    // 2. バスの切り替え:
    //    is_mem_access=1 のサイクルは、共有アドレスバス (shared_addr) を
    //    PC ではなく ALU結果 (データアドレス) に切り替えてデータアクセスを実行します。
    // 3. パイプラインバブルの挿入:
    //    このサイクルは命令フェッチができないため、次サイクルの ir に NOP をラッチし、
    //    regfile の pc_hold=1 によって PC の +1 を1クロック停止させます。
    // 4. 次サイクル:
    //    挿入された NOP が実行され、解放されたバスを使って保持していた PC で
    //    次命令が正しくフェッチされます。
    //
    // ※ 条件不成立でスキップされるLoad/Storeは is_mem_access=0 となるため、
    //    ストールは発生せず 1サイクル で通過します。
    wire is_mem_access = cond_match && (is_load || is_store);

    // 共有アドレスバス: データアクセス時はALU結果、それ以外(通常フェッチ)はPC
    wire [15:0] shared_addr = is_mem_access ? alu_result : pc;

    //==========================================================
    // Stage 1: 命令フェッチ & パイプラインラッチ
    //==========================================================

    assign mem_addr = shared_addr;

    // NOP命令定数 (cond = 3'b100 Never: 実行条件が不成立で何も行わない命令)
    localparam NOP_INST = 24'b100_00_0000_0000_0000_0000_000;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ir <= NOP_INST;
        end else if (is_mem_access) begin
            // [調停バブル]: 単一バスをデータアクセスに使用したためフェッチ不可 -> 次サイクルにNOPを挿入
            ir <= NOP_INST;
        end else if (wtenable && (wtaddr == 4'd15)) begin
            // [分岐フラッシュ]: PC(r15)書き込み成立時、既にフェッチされていた直後の命令を破棄してNOP化
            ir <= NOP_INST;
        end else begin
            // 通常の命令フェッチ
            ir <= mem_rdata;
        end
    end

    //==========================================================
    // デコーダ接続 (Stage 1 ID)
    //==========================================================

    decoder u_decoder (
        .inst          (ir),
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

 cond_check u_cond_check (
        .cond   (cond),
        .zf     (zf),
        .cf     (cf),
        .nf     (nf),
        .match  (cond_match)  // ← 左側(.match)はcond_checkのポート名、右側(cond_match)はcpu.vのワイヤ名
    );

    //==========================================================
    // レジスタファイル接続
    //==========================================================

    regfile u_regfile (
        .clk           (clk),
        .rst           (rst),
        .zf            (zf),
        .cf            (cf),
        .nf            (nf),
        .wtdata        (wtdata),
        .wtenable      (wtenable),
        .wtaddr        (wtaddr),
        .topin         (mem_rdata[23:16]), // Load時: 24bitメモリの上位8bit
        .topenable     (topenable),
        .topout        (topout),           // Store時: r13[7:0]をメモリ[23:16]へ
        .rdaddr_a      (rs1),
        .rdaddr_b      (rs2),
        .rddata_a      (rddata_a),
        .rddata_b      (rddata_b),
        .pc            (pc),
        .pc_hold       (is_mem_access)     // Load/Store実行中はPCの+1を停止し値を保持
    );

    //==========================================================
    // フォワーディング (RAWハザード回避)
    //==========================================================
    // 直前のサイクルで書き込まれるレジスタの値(prev_wtdata)を、
    // レジスタ書き込みを待たずに次サイクルのALU入力へ直接バイパスします。

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            prev_wtaddr   <= 4'd0;
            prev_wtdata   <= 16'd0;
            prev_wtenable <= 1'b0;
        end else begin
            prev_wtaddr   <= wtaddr;
            prev_wtdata   <= wtdata;
            prev_wtenable <= wtenable && (wtaddr != 4'd0) && (wtaddr != 4'd14);
        end
    end

    wire [15:0] fwd_data_a = (prev_wtenable && (prev_wtaddr == rs1)) ? prev_wtdata : rddata_a;
    wire [15:0] fwd_data_b = (prev_wtenable && (prev_wtaddr == rs2)) ? prev_wtdata : rddata_b;

    // ALU オペランドの選択 (即値演算またはLoad/Store時は第2入力にimmを選択)
    wire [15:0] alu_in_a = fwd_data_a;
    wire [15:0] alu_in_b = alu_src_imm ? imm : fwd_data_b;

    //==========================================================
    // ALU 接続
    //==========================================================

    assign flag_en = cond_match && flag_write_req;

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
    // データメモリ・レジスタ書き込み制御
    //==========================================================

    // メモリ書き込みデータ: 上位8bit=r13[7:0], 下位16bit=rdの値 (fwd_data_b)
    assign mem_wdata = {topout, fwd_data_b};

    // メモリライトイネーブル: 条件成立かつStore命令時
    // (is_store成立時は必ずis_mem_access=1となり、shared_addr=alu_resultが選択される)
    assign mem_we    = cond_match && is_store;

    // レジスタ書き込み先・データ・イネーブル
    assign wtaddr    = rd;
    assign wtdata    = is_load ? mem_rdata[15:0] : alu_result;
    assign wtenable  = cond_match && reg_write_req;
    assign topenable = cond_match && is_load;

endmodule
