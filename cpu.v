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
    // ノイマン型 単一メモリバスの調停 (構造的ハザード)
    //==========================================================
    //
    // このCPUは命令メモリとデータメモリを分離しない、単一アドレス空間・
    // 単一ポートの共有メモリ(mem_addr/mem_wdata/mem_rdata/mem_we)を使用する。
    // そのため「次命令のフェッチ」と「現在の命令(Load/Store)のデータアクセス」
    // を同一サイクルに同時実行することはできない。
    //
    // 本設計ではデータアクセスを優先する:
    //   - 現在のIRが条件成立のLoad/Storeの場合(is_mem_access) 、
    //     このサイクルはメモリバスをデータアクセスに割り当てる。
    //   - この間フェッチは行われないため、パイプラインには1サイクルの
    //     バブル(NOP)を挿入し、PCは進めずに保持する。
    //   - 次サイクルでバスが解放されるので、保持していたPCで
    //     正しく命令をフェッチし直す(1サイクルの実行遅延ペナルティ)。
    //
    // is_load/is_storeは条件判定前のデコード結果だが、実際にメモリを
    // 使用する必要があるかどうかはcond_matchで確定するため、
    // cond_matchが不成立(スキップされる条件付きLoad/Store)の場合は
    // バスを占有せず、通常どおり毎サイクル継続してフェッチを行う。
    wire is_mem_access = cond_match && (is_load || is_store);

    // 共有アドレスバス: データアクセス時はALU結果、それ以外はPC(フェッチ)
    wire [15:0] shared_addr = is_mem_access ? alu_result : pc;

    //==========================================================
    // Stage 1: 命令フェッチ & パイプラインラッチ
    //==========================================================

    assign mem_addr = shared_addr;

    // NOP命令定数 (cond = 3'b100 Never)
    localparam NOP_INST = 24'b100_00_0000_0000_0000_0000_000;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ir <= NOP_INST;
        end else if (is_mem_access) begin
            // 単一バスをデータアクセスに使用したためフェッチ不可 -> バブル挿入
            ir <= NOP_INST;
        end else if (wtenable && (wtaddr == 4'd15)) begin
            // 分岐成立 (PC書き込み): 次サイクルのIRにNOPを挿入してパイプラインをフラッシュ
            ir <= NOP_INST;
        end else begin
            ir <= mem_rdata;
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
        .pc            (pc),
        .pc_hold       (is_mem_access)
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
