/*==============================================================================
 * モジュール名 : cpu
 * 概要         : k16 16bit RISC 3段(IF/ID/EX) パイプライン CPU コア (同期BRAM完全対応)
 *============================================================================*/

module cpu (
    input  wire        clk,
    input  wire        rst,

    // 統合メモリインターフェース (ノイマン型: 命令・データ共用の単一バス)
    output wire [15:0] mem_addr,    // メモリアドレス (命令フェッチ時=PC, データアクセス時=ALU結果)
    output wire [23:0] mem_wdata,   // メモリ書き込みデータ
    input  wire [23:0] mem_rdata,   // メモリ読み出しデータ (命令 or データ)
    output wire        mem_we       // メモリ書き込みイネーブル
);

    // NOP命令定数 (cond = 3'b100 Never: 実行条件が不成立で何も行わない命令)
    localparam NOP_INST = 24'b100_00_0000_0000_0000_0000_000;

    //==========================================================
    // Stage 1 -> Stage 2: IF/ID パイプラインレジスタ
    //==========================================================
    reg [23:0] if_id_ir;

    //==========================================================
    // Stage 2: ID (デコード & レジスタファイル読み出し)
    //==========================================================
    wire [2:0]  id_cond;
    wire [1:0]  id_op;
    wire [3:0]  id_rd;
    wire [3:0]  id_rs1;
    wire [3:0]  id_rs2;
    wire [15:0] id_imm;
    wire [2:0]  id_alu_funct;
    wire        id_is_alu_reg;
    wire        id_is_alu_imm;
    wire        id_is_load;
    wire        id_is_store;
    wire        id_alu_src_imm;
    wire        id_reg_write;
    wire        id_flag_write;

    wire [15:0] id_rddata_a;
    wire [15:0] id_rddata_b;

    // デコーダ接続
    decoder u_decoder (
        .inst          (if_id_ir),
        .cond          (id_cond),
        .op            (id_op),
        .rd            (id_rd),
        .rs1           (id_rs1),
        .rs2           (id_rs2),
        .imm           (id_imm),
        .alu_funct     (id_alu_funct),
        .is_alu_reg    (id_is_alu_reg),
        .is_alu_imm    (id_is_alu_imm),
        .is_load       (id_is_load),
        .is_store      (id_is_store),
        .alu_src_imm   (id_alu_src_imm),
        .reg_write     (id_reg_write),
        .flag_write    (id_flag_write)
    );

    //==========================================================
    // Stage 2 -> Stage 3: ID/EX パイプラインレジスタ
    //==========================================================
    reg [2:0]  id_ex_cond;
    reg [3:0]  id_ex_rd;
    reg [3:0]  id_ex_rs1;
    reg [3:0]  id_ex_rs2;
    reg [15:0] id_ex_imm;
    reg [2:0]  id_ex_alu_funct;
    reg        id_ex_is_load;
    reg        id_ex_is_store;
    reg        id_ex_alu_src_imm;
    reg        id_ex_reg_write;
    reg        id_ex_flag_write;
    reg [15:0] id_ex_rddata_a;
    reg [15:0] id_ex_rddata_b;

    // EXステージのメモリアクセス発生判定
    wire ex_is_mem_access;

    // 前方宣言 (フォワーディング & レジスタ書き込みで参照)
    wire        ex_cond_match;
    reg         load_active_q;
    reg [3:0]   load_rd_q;
    wire        wtenable;
    wire [3:0]  wtaddr;
    wire [15:0] wtdata;
    reg [3:0]   prev_wtaddr;
    reg [15:0]  prev_wtdata;
    reg         prev_wtenable;

    // Load命令実行中のストール制御信号
    wire load_stall = ex_cond_match && id_ex_is_load;

    // PC書き込み(分岐成立)の組み合わせ検出
    // ALU命令による r15 書き込み、または Load(r15) の1サイクル遅延書き戻しで1になる
    wire pc_write_now = wtenable && (wtaddr == 4'd15);

    // Loadストール中に取りこぼれる「フェッチ済みのL+2命令」退避レジスタ
    reg  [23:0] pend_inst;
    reg         pend_valid;

    // 分岐フラッシュ2サイクル目用
    // (フェッチ→BRAM出力→IF/ID→ID/EX の深さ分、違反経路を廃棄する)
    reg         branch_flush_q;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            id_ex_cond        <= 3'b100; // Condition: Never
            id_ex_rd          <= 4'd0;
            id_ex_rs1         <= 4'd0;
            id_ex_rs2         <= 4'd0;
            id_ex_imm         <= 16'd0;
            id_ex_alu_funct   <= 3'd0;
            id_ex_is_load     <= 1'b0;
            id_ex_is_store    <= 1'b0;
            id_ex_alu_src_imm <= 1'b0;
            id_ex_reg_write   <= 1'b0;
            id_ex_flag_write  <= 1'b0;
            id_ex_rddata_a    <= 16'd0;
            id_ex_rddata_b    <= 16'd0;
        end else if (load_stall || pc_write_now) begin
            // [Loadデータバブル / 分岐フラッシュ]:
            // - Load実行時は次サイクルの書き戻し衝突を防ぐため EX に NOP を挿入
            // - PC書き込み(分岐)成立時は、IF/IDから流れてくる分岐直後のパス命令(J+1)を NOP 化
            id_ex_cond        <= 3'b100;
            id_ex_rd          <= 4'd0;
            id_ex_rs1         <= 4'd0;
            id_ex_rs2         <= 4'd0;
            id_ex_imm         <= 16'd0;
            id_ex_alu_funct   <= 3'd0;
            id_ex_is_load     <= 1'b0;
            id_ex_is_store    <= 1'b0;
            id_ex_alu_src_imm <= 1'b0;
            id_ex_reg_write   <= 1'b0;
            id_ex_flag_write  <= 1'b0;
            id_ex_rddata_a    <= 16'd0;
            id_ex_rddata_b    <= 16'd0;
        end else begin
            id_ex_cond        <= id_cond;
            id_ex_rd          <= id_rd;
            id_ex_rs1         <= id_rs1;
            id_ex_rs2         <= id_rs2;
            id_ex_imm         <= id_imm;
            id_ex_alu_funct   <= id_alu_funct;
            id_ex_is_load     <= id_is_load;
            id_ex_is_store    <= id_is_store;
            id_ex_alu_src_imm <= id_alu_src_imm;
            id_ex_reg_write   <= id_reg_write;
            id_ex_flag_write  <= id_flag_write;
            id_ex_rddata_a    <= id_rddata_a;
            id_ex_rddata_b    <= id_rddata_b;
        end
    end

    //==========================================================
    // Stage 3: EX (実行 / 条件判定 / ALU / メモリアクセス)
    //==========================================================
    wire zf, cf, nf;

    // 条件判定
    cond_check u_cond_check (
        .cond   (id_ex_cond),
        .zf     (zf),
        .cf     (cf),
        .nf     (nf),
        .match  (ex_cond_match)
    );

    // データメモリへのアクセス発生判定
    assign ex_is_mem_access = ex_cond_match && (id_ex_is_load || id_ex_is_store);

    // --- フォワーディング (RAWハザード回避) ---
    // r14(フラグ)はIDステージでキャプチャせず、EXステージでライブ読み出しする。
    // (直前命令のフラグ更新が1命令分古くなるスタールを防ぐ)
    wire [15:0] ex_rddata_a = (id_ex_rs1 == 4'd14) ? {13'b0, nf, cf, zf} : id_ex_rddata_a;
    wire [15:0] ex_rddata_b = (id_ex_rs2 == 4'd14) ? {13'b0, nf, cf, zf} : id_ex_rddata_b;
    // 1) 1サイクル遅延でBRAM/MMIOから届いたLoadデータの直接バイパス (load_active_q)
    // 2) r13[7:0]へ書き込まれるメモリ上位8bit(topin)の直接バイパス
    // 3) 直前に書き込まれたレジスタ値のバイパス (prev_wtenable)
    wire [15:0] fwd_r13_a = load_active_q ? {ex_rddata_a[15:8], mem_rdata[23:16]} : ex_rddata_a;
    wire [15:0] fwd_r13_b = load_active_q ? {ex_rddata_b[15:8], mem_rdata[23:16]} : ex_rddata_b;

    wire [15:0] fwd_data_a = (load_active_q && (load_rd_q == id_ex_rs1) && (id_ex_rs1 != 4'd0) && (id_ex_rs1 != 4'd14)) ? wtdata :
                             (load_active_q && (id_ex_rs1 == 4'd13)) ? fwd_r13_a :
                             (prev_wtenable && (prev_wtaddr == id_ex_rs1)) ? prev_wtdata : ex_rddata_a;
    wire [15:0] fwd_data_b = (load_active_q && (load_rd_q == id_ex_rs2) && (id_ex_rs2 != 4'd0) && (id_ex_rs2 != 4'd14)) ? wtdata :
                             (load_active_q && (id_ex_rs2 == 4'd13)) ? fwd_r13_b :
                             (prev_wtenable && (prev_wtaddr == id_ex_rs2)) ? prev_wtdata : ex_rddata_b;

    wire [15:0] alu_in_a = fwd_data_a;
    wire [15:0] alu_in_b = id_ex_alu_src_imm ? id_ex_imm : fwd_data_b;
    wire [15:0] alu_result;

    // ALU 接続
    alu u_alu (
        .clk     (clk),
        .rst     (rst),
        .flag_en (ex_cond_match && id_ex_flag_write),
        .A       (alu_in_a),
        .B       (alu_in_b),
        .funct   (id_ex_alu_funct),
        .result  (alu_result),
        .Z       (zf),
        .C       (cf),
        .N       (nf)
    );

    //==========================================================
    // IFステージ (命令フェッチ制御 & メモリバス調停)
    //==========================================================
    wire [15:0] pc;
    wire [15:0] shared_addr = ex_is_mem_access ? alu_result : pc;
    assign mem_addr = shared_addr;

    // データアクセスの翌サイクル判定用レジスタ
    reg data_access_q;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            data_access_q <= 1'b0;
        end else begin
            data_access_q <= ex_is_mem_access;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            if_id_ir <= NOP_INST;
        end else if (pc_write_now) begin
            // [分岐フラッシュ 1/2]: PC書き込みサイクル。
            // バスから返ってくるのは分岐のフォールスルー先(J+2)なので廃棄
            if_id_ir <= NOP_INST;
        end else if (load_stall) begin
            // [Load時フェッチストール]: Load命令実行中は IF/ID 命令レジスタを保持
            if_id_ir <= if_id_ir;
        end else if (branch_flush_q) begin
            // [分岐フラッシュ 2/2]: 分岐実行サイクルにフェッチされた J+3 を廃棄
            if_id_ir <= NOP_INST;
        end else if (data_access_q) begin
            // [バス調停バブル]: データアクセスの翌サイクル。
            // Loadストール時に退避した L+2 命令があればここで IF/ID へ復帰。
            // なければ(BRAMから返るのはストア先/ロードデータのゴミ) NOP 挿入
            if_id_ir <= pend_valid ? pend_inst : NOP_INST;
        end else begin
            if_id_ir <= mem_rdata;
        end
    end

    //==========================================================
    // BRAM 1サイクル遅延吸収論理 (Load データの書き戻し同期)
    //==========================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            load_active_q <= 1'b0;
            load_rd_q     <= 4'd0;
        end else begin
            load_active_q <= ex_cond_match && id_ex_is_load;
            if (ex_cond_match && id_ex_is_load) begin
                load_rd_q <= id_ex_rd;
            end
        end
    end

    //==========================================================
    // Loadストール時の後続命令退避 (L+2 取りこぼし対策)
    //==========================================================
    // LoadがEXで実行されるサイクル、mem_rdataには「前サイクルにフェッチ
    // 済みの L+2 命令」が乗っている。IF/IDを L+1 でホールドしている間に
    // ここへ退避し、翌サイクル(データアクセス翌サイクル)に IF/ID へ復帰させる。
    // 前サイクルがバス占有(ストア等)だった場合はフェッチが発生していないため
    // 退避せず、pc_hold により L+2 以降が後から再フェッチされる。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pend_valid <= 1'b0;
            pend_inst  <= NOP_INST;
        end else if (load_stall && !data_access_q) begin
            pend_valid <= 1'b1;
            pend_inst  <= mem_rdata;
        end else begin
            pend_valid <= 1'b0;
        end
    end

    //==========================================================
    // 分岐フラッシュ2サイクル目
    //==========================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            branch_flush_q <= 1'b0;
        end else begin
            branch_flush_q <= pc_write_now;
        end
    end

    //==========================================================
    // レジスタファイル書き込み & メモリ出力
    //==========================================================
    // 通常書き込み(ALU演算結果) と 1サイクル遅延して返ってきた Load データの書き込みを統合
    assign wtenable = (ex_cond_match && id_ex_reg_write && !id_ex_is_load) || load_active_q;
    assign wtaddr   = load_active_q ? load_rd_q : id_ex_rd;
    assign wtdata   = load_active_q ? mem_rdata[15:0] : alu_result;
    wire [7:0]  topout;

    regfile u_regfile (
        .clk       (clk),
        .rst       (rst),
        .zf        (zf),
        .cf        (cf),
        .nf        (nf),
        .wtdata    (wtdata),
        .wtenable  (wtenable),
        .wtaddr    (wtaddr),
        .topin     (mem_rdata[23:16]), // Load時: メモリ上位8bit
        .topenable (load_active_q),    // BRAMデータ返却サイクルに合わせてイネーブル化
        .topout    (topout),
        .rdaddr_a  (id_rs1),
        .rdaddr_b  (id_rs2),
        .rddata_a  (id_rddata_a),
        .rddata_b  (id_rddata_b),
        .pc        (pc),
        .pc_hold   (ex_is_mem_access) // データアクセス中は PC+1 をストール
    );

    // メモリ書き込み信号 (Store時)
    assign mem_wdata = {topout, fwd_data_b};
    assign mem_we    = ex_cond_match && id_ex_is_store;

    //==========================================================
    // フォワーディング用書き込み履歴更新
    //==========================================================
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

endmodule
