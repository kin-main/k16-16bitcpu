/*==============================================================================
 * モジュール名 : cpu
 * 概要          : k16 16-bit RISC CPU コア (同期RAM / ノイマン型単一バス対応)
 *
 * アーキテクチャ特徴:
 *   - データパス幅 : 16-bit
 *   - 命令/メモリワード幅 : 24-bit
 *   - パイプライン : 2段 (IF/ID, EX/MEM/WB)
 *   - メモリ構成 : ノイマン型（単一メモリバスを命令フェッチとデータアクセスで共有）
 *   - RAM前提 : Gowin BRAM等の1クロック遅延同期RAM (Synchronous RAM)
 *============================================================================*/

module cpu (
    input  wire        clk,
    input  wire        rst,

    // 統合メモリバス (ノイマン型)
    output wire [15:0] mem_addr,
    output wire [23:0] mem_wdata,
    input  wire [23:0] mem_rdata,
    output wire        mem_we
);

    //==========================================================================
    // 定数定義 (NOP命令)
    // cond = 100 (Never), op = 00
    // 24bit: 3'b100, 2'b00, 4'b0000, 4'b0000, 4'b0000, 4'b000 (24-bit)
    //==========================================================================
    localparam [23:0] NOP_INST = 24'b100_00_0000_0000_0000_0000_000;

    //==========================================================================
    // パイプラインレジスタ定義
    //==========================================================================

    // Stage 1 -> Stage 2 (IF -> ID/EX)
    reg [23:0] if_id_ir;
    reg [15:0] if_id_pc;

    // Stage 2 (ID/EX -> MEM/WB)
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
    reg [15:0] id_ex_pc;

    //==========================================================================
    // Stage 1 (ID): 命令デコード & レジスタファイル読み出し
    //==========================================================================
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

    decoder u_decoder (
        .inst        (if_id_ir),
        .cond        (id_cond),
        .op          (id_op),
        .rd          (id_rd),
        .rs1         (id_rs1),
        .rs2         (id_rs2),
        .imm         (id_imm),
        .alu_funct   (id_alu_funct),
        .is_alu_reg  (id_is_alu_reg),
        .is_alu_imm  (id_is_alu_imm),
        .is_load     (id_is_load),
        .is_store    (id_is_store),
        .alu_src_imm (id_alu_src_imm),
        .reg_write   (id_reg_write),
        .flag_write  (id_flag_write)
    );

    //==========================================================================
    // Stage 2 (EX/MEM/WB): 実行, 条件判定, ALU, メモリアクセス, 書き戻し
    //==========================================================================
    wire zf, cf, nf;
    wire ex_cond_match;

    cond_check u_cond_check (
        .cond  (id_ex_cond),
        .zf    (zf),
        .cf    (cf),
        .nf    (nf),
        .match (ex_cond_match)
    );

    // 条件成立した Load/Store によるデータアクセス発生判定
    wire ex_is_mem_access = ex_cond_match && (id_ex_is_load || id_ex_is_store);

    //==========================================================================
    // BRAM 同期読み出し遅延制御 & フォワーディング (RAWハザード解消)
    //==========================================================================

    // Loadデータ書き戻しコントロールレジスタ
    reg        load_active_q;
    reg [3:0]  load_rd_q;

    // 前サイクルのレジスタ書き込み履歴（フォワーディング用）
    reg        prev_wtenable;
    reg [3:0]  prev_wtaddr;
    reg [15:0] prev_wtdata;

    wire        wtenable;
    wire [3:0]  wtaddr;
    wire [15:0] wtdata;

    // r14 (フラグレジスタ) のライブアクセス
    wire [15:0] ex_rddata_a = (id_ex_rs1 == 4'd14) ? {13'b0, nf, cf, zf} : id_ex_rddata_a;
    wire [15:0] ex_rddata_b = (id_ex_rs2 == 4'd14) ? {13'b0, nf, cf, zf} : id_ex_rddata_b;

    // r13 (24bitメモリ上位8bit) のLoad直後フォワーディング
    wire [15:0] load_fwd_r13_a = {ex_rddata_a[15:8], mem_rdata[23:16]};
    wire [15:0] load_fwd_r13_b = {ex_rddata_b[15:8], mem_rdata[23:16]};

    // --- フォワーディング・マルチプレクサ ---
    // 優先順位:
    // 1. r0 = 常に0
    // 2. r14 = フラグライブ値
    // 3. r15 = 現在実行中のPC値
    // 4. 今サイクル書き戻しデータ (Load完了またはALU結果)
    // 5. Load完了による r13[7:0] バイパス
    // 6. 1サイクル前の書き込み履歴バイパス
    // 7. レジスタファイルからの読み出し値
    wire [15:0] fwd_data_a =
        (id_ex_rs1 == 4'd0)  ? 16'h0000 :
        (id_ex_rs1 == 4'd14) ? {13'b0, nf, cf, zf} :
        (id_ex_rs1 == 4'd15) ? id_ex_pc :
        (load_active_q && (load_rd_q == id_ex_rs1) && (id_ex_rs1 != 4'd13)) ? mem_rdata[15:0] :
        (load_active_q && (id_ex_rs1 == 4'd13)) ? load_fwd_r13_a :
        (prev_wtenable && (prev_wtaddr == id_ex_rs1)) ? prev_wtdata :
        ex_rddata_a;

    wire [15:0] fwd_data_b =
        (id_ex_rs2 == 4'd0)  ? 16'h0000 :
        (id_ex_rs2 == 4'd14) ? {13'b0, nf, cf, zf} :
        (id_ex_rs2 == 4'd15) ? id_ex_pc :
        (load_active_q && (load_rd_q == id_ex_rs2) && (id_ex_rs2 != 4'd13)) ? mem_rdata[15:0] :
        (load_active_q && (id_ex_rs2 == 4'd13)) ? load_fwd_r13_b :
        (prev_wtenable && (prev_wtaddr == id_ex_rs2)) ? prev_wtdata :
        ex_rddata_b;

    //==========================================================================
    // ALU 演算ユニット
    //==========================================================================
    wire [15:0] alu_in_a = fwd_data_a;
    wire [15:0] alu_in_b = id_ex_alu_src_imm ? id_ex_imm : fwd_data_b;
    wire [15:0] alu_result;

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

    //==========================================================================
    // レジスタファイル書き戻し信号定義
    //==========================================================================
    assign wtenable = (ex_cond_match && id_ex_reg_write && !id_ex_is_load) || load_active_q;
    assign wtaddr   = load_active_q ? load_rd_q : id_ex_rd;
    assign wtdata   = load_active_q ? mem_rdata[15:0] : alu_result;

    // 分岐発生判定 (r15/PCへの書き込み)
    wire pc_write_now = wtenable && (wtaddr == 4'd15);

    //==========================================================================
    // 統合メモリバス調停 (ノイマン型)
    // データアクセス優先: Load/Store実行時はデータアドレスを出力し、通常はPCを出力
    //==========================================================================
    wire [15:0] pc;
    wire [15:0] shared_addr = ex_is_mem_access ? alu_result : pc;
    assign mem_addr = shared_addr;

    // Store時の書き込みデータと信号
    wire [7:0] topout;
    assign mem_wdata = {topout, fwd_data_b};
    assign mem_we    = ex_cond_match && id_ex_is_store;

    //==========================================================================
    // バス調停・ストール・フラッシュ制御レジスタ
    //==========================================================================
    reg data_access_q;    // 前サイクルがデータアクセスだったことを保持
    reg branch_flush_q;   // 分岐フラッシュの2サイクル目を保持

    // Loadストール判定
    wire load_stall = ex_cond_match && id_ex_is_load;

    // BRAM同期リードにおける命令退避用レジスタ
    reg [23:0] pend_inst;
    reg        pend_valid;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            data_access_q  <= 1'b0;
            branch_flush_q <= 1'b0;
            load_active_q  <= 1'b0;
            load_rd_q      <= 4'd0;
            pend_inst      <= NOP_INST;
            pend_valid     <= 1'b0;
        end else begin
            data_access_q  <= ex_is_mem_access;
            branch_flush_q <= pc_write_now;

            // Load有効フラグ更新 (1サイクル遅延でBRAMからデータが返ってくる)
            load_active_q  <= load_stall;
            if (load_stall) begin
                load_rd_q  <= id_ex_rd;
            end

            // 同期RAMにおいてLoadと命令フェッチがバッティングした際の命令退避
            if (load_stall && !data_access_q) begin
                pend_inst  <= mem_rdata;
                pend_valid <= 1'b1;
            end else begin
                pend_valid <= 1'b0;
            end
        end
    end

    //==========================================================================
    // Stage 1 -> Stage 2 (IF/ID) パイプラインレジスタ更新
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            if_id_ir <= NOP_INST;
            if_id_pc <= 16'd0;
        end else if (pc_write_now) begin
            // 【分岐フラッシュ 1/2】: PC書き込み時、パイプラインの命令をキル
            if_id_ir <= NOP_INST;
            if_id_pc <= 16'd0;
        end else if (load_stall) begin
            // 【Loadストール】: Load完了まで現在のIF/ID命令をホールド
            if_id_ir <= if_id_ir;
            if_id_pc <= if_id_pc;
        end else if (branch_flush_q) begin
            // 【分岐フラッシュ 2/2】: 2サイクル目のフラッシュ
            if_id_ir <= NOP_INST;
            if_id_pc <= 16'd0;
        end else if (data_access_q) begin
            // 【バス調停バブル】: データアクセスの翌サイクル
            if (pend_valid) begin
                if_id_ir <= pend_inst;
                if_id_pc <= pc;
            end else begin
                if_id_ir <= NOP_INST;
                if_id_pc <= 16'd0;
            end
        end else begin
            // 通常のフェッチ
            if_id_ir <= mem_rdata;
            if_id_pc <= pc;
        end
    end

    //==========================================================================
    // Stage 2 (ID/EX) パイプラインレジスタ更新
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            id_ex_cond        <= 3'b100; // Never (NOP)
            id_ex_rd          <= 4'd0;
            id_ex_rs1         <= 4'd0;
            id_ex_rs2         <= 4'd0;
            id_ex_imm         <= 16'd0;
            id_ex_alu_funct   <= 3'b000;
            id_ex_is_load     <= 1'b0;
            id_ex_is_store    <= 1'b0;
            id_ex_alu_src_imm <= 1'b0;
            id_ex_reg_write   <= 1'b0;
            id_ex_flag_write  <= 1'b0;
            id_ex_rddata_a    <= 16'd0;
            id_ex_rddata_b    <= 16'd0;
            id_ex_pc          <= 16'd0;
        end else if (load_stall || pc_write_now) begin
            // Load実行時および分岐発動時はEXにNOPを挿入 (バブル化)
            id_ex_cond        <= 3'b100; // Never
            id_ex_rd          <= 4'd0;
            id_ex_rs1         <= 4'd0;
            id_ex_rs2         <= 4'd0;
            id_ex_imm         <= 16'd0;
            id_ex_alu_funct   <= 3'b000;
            id_ex_is_load     <= 1'b0;
            id_ex_is_store    <= 1'b0;
            id_ex_alu_src_imm <= 1'b0;
            id_ex_reg_write   <= 1'b0;
            id_ex_flag_write  <= 1'b0;
            id_ex_rddata_a    <= 16'd0;
            id_ex_rddata_b    <= 16'd0;
            id_ex_pc          <= 16'd0;
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
            id_ex_pc          <= if_id_pc;
        end
    end

    //==========================================================================
    // レジスタファイル (regfile)
    //==========================================================================
    regfile u_regfile (
        .clk       (clk),
        .rst       (rst),

        .zf        (zf),
        .cf        (cf),
        .nf        (nf),

        .wtdata    (wtdata),
        .wtenable  (wtenable),
        .wtaddr    (wtaddr),

        .topin     (mem_rdata[23:16]),
        .topenable (load_active_q),
        .topout    (topout),

        .rdaddr_a  (id_rs1),
        .rdaddr_b  (id_rs2),

        .rddata_a  (id_rddata_a),
        .rddata_b  (id_rddata_b),

        .pc        (pc),

        // 単一バス調停: データアクセス発生時にPCの自動+1をストールさせる
        .pc_hold   (ex_is_mem_access)
    );

    //==========================================================================
    // 1サイクル前のレジスタ書き込み履歴（フォワーディング用）
    //==========================================================================
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
