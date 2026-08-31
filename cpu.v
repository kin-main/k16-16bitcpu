module cpu (
    input  wire        clk,
    input  wire        rst,

    output wire [15:0] mem_addr,
    output wire [23:0] mem_wdata,
    input  wire [23:0] mem_rdata,
    output wire        mem_we
);

    //==========================================================
    // ステート定義 (多サイクルFSM: BRAMの1サイクル読み出し遅延に対応)
    //==========================================================
    localparam S_IF1 = 2'd0;  // 命令アドレス出力
    localparam S_IF2 = 2'd1;  // 命令データ確定 -> ir にラッチ
    localparam S_EX  = 2'd2;  // デコード・ALU実行・条件判定
    localparam S_LD  = 2'd3;  // Load専用: データ確定 -> レジスタ書き込み

    reg [1:0] state;
    reg [23:0] ir;

    localparam NOP_INST = 24'b100_00_0000_0000_0000_0000_000;

    //==========================================================
    // デコーダ・条件判定
    //==========================================================
    wire [2:0]  cond;
    wire [1:0]  op;
    wire [3:0]  rd, rs1, rs2;
    wire [15:0] imm;
    wire [2:0]  alu_funct;
    wire        is_alu_reg, is_alu_imm, is_load, is_store;
    wire        alu_src_imm, reg_write_req, flag_write_req;
    wire        cond_match;

    decoder u_decoder (
        .inst(ir), .cond(cond), .op(op), .rd(rd), .rs1(rs1), .rs2(rs2),
        .imm(imm), .alu_funct(alu_funct),
        .is_alu_reg(is_alu_reg), .is_alu_imm(is_alu_imm),
        .is_load(is_load), .is_store(is_store),
        .alu_src_imm(alu_src_imm),
        .reg_write(reg_write_req), .flag_write(flag_write_req)
    );

    cond_check u_cond_check (
        .cond(cond), .zf(zf), .cf(cf), .nf(nf), .match(cond_match)
    );

    //==========================================================
    // レジスタファイル
    //==========================================================
    wire [15:0] pc, rddata_a, rddata_b, wtdata;
    wire [7:0]  topout;
    wire        wtenable, topenable;
    wire [3:0]  wtaddr;

    // 条件成立かつLoad/Store (旧is_mem_accessと同義)
    wire is_active_load  = cond_match && is_load;
    wire is_active_store = cond_match && is_store;
    wire is_active_mem   = is_active_load || is_active_store;

    // PCを進めるタイミング:
    // ・S_EXでLoad以外が完了する場合 (ALU命令 / Store / 条件不成立)
    // ・S_LDでLoadが完了する場合
    wire pc_advance = (state == S_EX && !is_active_load) || (state == S_LD);
    wire pc_hold    = !pc_advance;

    regfile u_regfile (
        .clk(clk), .rst(rst),
        .zf(zf), .cf(cf), .nf(nf),
        .wtdata(wtdata), .wtenable(wtenable), .wtaddr(wtaddr),
        .topin(mem_rdata[23:16]), .topenable(topenable), .topout(topout),
        .rdaddr_a(rs1), .rdaddr_b(rs2),
        .rddata_a(rddata_a), .rddata_b(rddata_b),
        .pc(pc), .pc_hold(pc_hold)
    );

    //==========================================================
    // ALU (フォワーディング不要: 単一命令が完全に完了してから次に進むため)
    //==========================================================
    wire [15:0] alu_in_a = rddata_a;
    wire [15:0] alu_in_b = alu_src_imm ? imm : rddata_b;
    wire [15:0] alu_result;
    wire        zf, cf, nf;
    wire        flag_en = (state == S_EX) && cond_match && flag_write_req;

    alu u_alu (
        .clk(clk), .rst(rst), .flag_en(flag_en),
        .A(alu_in_a), .B(alu_in_b), .funct(alu_funct),
        .result(alu_result), .Z(zf), .C(cf), .N(nf)
    );

    //==========================================================
    // メモリバス出力
    //==========================================================
    // S_EX中にLoad/Storeのアドレス計算結果を出す。それ以外は常にpc。
    assign mem_addr  = (state == S_EX && is_active_mem) ? alu_result : pc;
    assign mem_wdata = {topout, rddata_b};
    assign mem_we    = (state == S_EX) && is_active_store;

    assign wtaddr    = rd;
    assign wtdata    = is_load ? mem_rdata[15:0] : alu_result;

    // レジスタ書き込み: ALU系はS_EXで、LoadはS_LDで確定
    assign wtenable  = reg_write_req && cond_match &&
                        ( (state == S_EX && !is_active_load) ||
                          (state == S_LD && is_active_load) );

    assign topenable = (state == S_LD) && is_active_load;

    //==========================================================
    // ステート遷移 & ir ラッチ
    //==========================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IF1;
            ir    <= NOP_INST;
        end else begin
            case (state)
                S_IF1: state <= S_IF2;
                S_IF2: begin
                    ir    <= mem_rdata;   // 1サイクル前に出したpcに対応する命令が確定
                    state <= S_EX;
                end
                S_EX:  state <= is_active_load ? S_LD : S_IF1;
                S_LD:  state <= S_IF1;
                default: state <= S_IF1;
            endcase
        end
    end

endmodule
