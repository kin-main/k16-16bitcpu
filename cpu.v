module cpu (
    input  wire        clk,
    input  wire        rst,

    // 命令メモリ (ROM/RAM) インターフェース
    output wire [15:0] inst_addr,    // フェッチアドレス (PC)
    input  wire [23:0] inst_data,    // フェッチされた24bit命令

    // データメモリ (RAM) インターフェース
    output wire [15:0] mem_addr,     // データメモリアドレス
    output wire [23:0] mem_wdata,    // データメモリ書き込みデータ
    input  wire [23:0] mem_rdata,    // データメモリ読み出しデータ
    output wire        mem_we        // データメモリ書き込みイネーブル
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
    // Stage 1: 命令フェッチ & パイプラインラッチ
    //==========================================================

    assign inst_addr = pc;

    // NOP命令定数 (cond = 3'b100 Never)
    localparam NOP_INST = 24'b100_00_0000_0000_0000_0000_000;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ir <= NOP_INST;
        end else if (wtenable && (wtaddr == 4'd15)) begin
            // 分岐成立 (PC書き込み): 次サイクルのIRにNOPを挿入してパイプラインをフラッシュ
            ir <= NOP_INST;
        end else begin
            ir <= inst_data;
        end
    end

    //==========================================================
    // デコーダ接続
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
        .cond          (cond),
        .zf            (zf),
        .cf            (cf),
        .nf            (nf),
        .match         (cond_match)
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
        .topin         (mem_rdata[23:16]),
        .topenable     (topenable),
        .topout        (topout),
        .rdaddr_a      (rs1),
        .rdaddr_b      (rs2),
        .rddata_a      (rddata_a),
        .rddata_b      (rddata_b),
        .pc            (pc)
    );

    //==========================================================
    // フォワーディング (RAWハザード回避)
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

    wire [15:0] fwd_data_a = (prev_wtenable && (prev_wtaddr == rs1)) ? prev_wtdata : rddata_a;
    wire [15:0] fwd_data_b = (prev_wtenable && (prev_wtaddr == rs2)) ? prev_wtdata : rddata_b;

    // ALU オペランドの選択
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

    // メモリアドレス: ALU結果 (base + im または base - im)
    assign mem_addr  = alu_result;

    // メモリ書き込みデータ: 上位8bit=r13[7:0], 下位16bit=rdの値 (fwd_data_b)
    assign mem_wdata = {topout, fwd_data_b};

    // メモリライトイネーブル: 条件成立かつStore命令時
    assign mem_we    = cond_match && is_store;

    // レジスタ書き込み先・データ・イネーブル
    assign wtaddr    = rd;
    assign wtdata    = is_load ? mem_rdata[15:0] : alu_result;
    assign wtenable  = cond_match && reg_write_req;
    assign topenable = cond_match && is_load;

endmodule
