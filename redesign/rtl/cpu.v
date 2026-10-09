//==============================================================================
// k16 16-bit RISC CPU — 同期RAM対応再設計版 (timing fix)
//
// 修正点 (v2):
//   - saved_* を S_IDLE→S_MEM_RESP遷移時にセットするが、
//     S_MEM_RESPでの書き込みは saved_* を直接使わず、
//     専用の wb_* レジスタ（S_IDLEの組み合わせ値をラッチ）を使う
//   - これにより saved_rd の nonblocking 更新と regfile 書き込みの競合を回避
//==============================================================================

module cpu (
    input  wire        clk,
    input  wire        rst,

    // Memory interface (von Neumann, single port, sync read)
    output wire        mem_data_req,
    output reg  [15:0] mem_addr,
    output wire [23:0] mem_wdata,
    output wire        mem_we,
    input  wire [23:0] mem_rdata,
    input  wire        mem_ready
);

    //==========================================================================
    // State machine
    //==========================================================================
    localparam S_IDLE     = 2'd0;
    localparam S_MEM_RESP = 2'd1;
    localparam S_FLUSH1   = 2'd2;

    reg [1:0] state;

    //==========================================================================
    // Pipeline registers
    //==========================================================================
    reg [23:0] ir;
    reg [15:0] ir_addr;
    reg [15:0] fetch_pc;
    reg [15:0] mem_addr_q;

    reg [23:0] prefetch_buf;
    reg [15:0] prefetch_addr;
    reg        prefetch_valid;

    // Saved control signals for S_MEM_RESP
    reg        saved_is_load;
    reg        saved_is_store;
    reg [3:0]  saved_rd;
    reg        saved_cond_match;
    reg [15:0] saved_data_addr;

    // Latched writeback signals (computed in S_IDLE, used in S_MEM_RESP)
    // These avoid the nonblocking race with saved_rd update
    reg [3:0]  wb_rd_latch;       // rd to write back (for LOAD)
    reg        wb_load_en_latch;  // LOAD writeback enable (cond_match && is_load)
    reg        wb_is_load_r15_latch; // LOAD r15 branch

    // Forwarding
    reg [3:0]  prev_wtaddr;
    reg [15:0] prev_wtdata;
    reg        prev_wtenable;

    localparam [23:0] NOP_INST = 24'h800000;

    //==========================================================================
    // Decoder
    //==========================================================================
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

    //==========================================================================
    // Condition check
    //==========================================================================
    wire cond_match;
    wire zf, cf, nf;
    wire [15:0] alu_in_a, alu_in_b;

    cond_check u_cond_check (
        .cond          (cond),
        .zf            (zf),
        .cf            (cf),
        .nf            (nf),
        .match         (cond_match)
    );

    //==========================================================================
    // ALU
    //==========================================================================
    wire [15:0] alu_result;
    wire        flag_en;

    assign flag_en = cond_match && flag_write_req &&
                     (state == S_IDLE) && !is_mem_access;

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

    //==========================================================================
    // Register file
    //==========================================================================
    wire [15:0] rddata_a_raw;
    wire [15:0] rddata_b_raw;
    wire [7:0]  topout;
    wire [15:0] wtdata;
    reg         wtenable;
    wire [3:0]  wtaddr;
    reg         topenable;

    // r15 read override: return ir_addr (current instruction's address)
    wire [15:0] rddata_a = (rs1 == 4'd15) ? ir_addr : rddata_a_raw;
    wire [15:0] rddata_b = (rs2 == 4'd15) ? ir_addr : rddata_b_raw;

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
        .rddata_a      (rddata_a_raw),
        .rddata_b      (rddata_b_raw),
        .pc_cur        (ir_addr)
    );

    //==========================================================================
    // Forwarding (RAW hazard bypass)
    //==========================================================================
    wire [15:0] fwd_data_a = (prev_wtenable && (prev_wtaddr == rs1)) ? prev_wtdata : rddata_a;
    wire [15:0] fwd_data_b = (prev_wtenable && (prev_wtaddr == rs2)) ? prev_wtdata : rddata_b;

    assign alu_in_a = fwd_data_a;
    assign alu_in_b = alu_src_imm ? imm : fwd_data_b;

    //==========================================================================
    // Control signal computation
    //==========================================================================
    wire is_mem_access  = cond_match && (is_load || is_store);
    wire [15:0] data_addr = alu_result;
    wire is_alu_r15 = cond_match && reg_write_req && (rd == 4'd15) && (state == S_IDLE);

    // During S_MEM_RESP, use saved signals
    wire resp_is_load      = saved_is_load;
    wire resp_is_store     = saved_is_store;
    wire resp_rd           = saved_rd;
    wire resp_cond_match   = saved_cond_match;
    wire resp_data_addr    = saved_data_addr;

    // LOAD r15 branch detection (latched)
    wire is_load_r15_branch = wb_is_load_r15_latch;

    //==========================================================================
    // Writeback signals (combinational, uses latched values in S_MEM_RESP)
    //==========================================================================
    // In S_IDLE: normal ALU writeback
    // In S_MEM_RESP: use latched wb_* signals (avoids nonblocking race)
    assign wtaddr = (state == S_MEM_RESP) ? wb_rd_latch : rd;
    assign wtdata = (state == S_MEM_RESP) ? mem_rdata[15:0] : alu_result;

    always @(*) begin
        case (state)
            S_IDLE: begin
                if (cond_match && reg_write_req && !is_mem_access && !is_alu_r15)
                    wtenable = 1'b1;
                else
                    wtenable = 1'b0;
            end
            S_MEM_RESP: begin
                // Use latched LOAD enable (already gated by cond_match && is_load)
                if (mem_ready && wb_load_en_latch && !wb_is_load_r15_latch)
                    wtenable = 1'b1;
                else
                    wtenable = 1'b0;
            end
            default: wtenable = 1'b0;
        endcase
    end

    always @(*) begin
        case (state)
            S_MEM_RESP:
                // topenable: LOAD writeback (including LOAD r15, which updates r13)
                topenable = (mem_ready && wb_load_en_latch) ? 1'b1 : 1'b0;
            default:
                topenable = 1'b0;
        endcase
    end

    //==========================================================================
    // Memory interface
    //==========================================================================
    assign mem_data_req = ((state == S_IDLE) && is_mem_access) ||
                          ((state == S_MEM_RESP) && !mem_ready);

    assign mem_we = ((state == S_IDLE) && cond_match && is_store) ? 1'b1 : 1'b0;
    assign mem_wdata = {topout, fwd_data_b};

    always @(*) begin
        case (state)
            S_IDLE: begin
                if (is_mem_access)
                    mem_addr = data_addr;
                else if (is_alu_r15)
                    mem_addr = alu_result;
                else
                    mem_addr = fetch_pc;
            end
            S_MEM_RESP: begin
                if (is_load_r15_branch && mem_ready)
                    mem_addr = mem_rdata[15:0];    // LOAD r15: fetch TARGET
                else if (!mem_ready)
                    mem_addr = resp_data_addr;     // MMIO wait: hold
                else
                    mem_addr = fetch_pc;           // Resume fetch
            end
            S_FLUSH1: begin
                mem_addr = fetch_pc;
            end
            default:
                mem_addr = fetch_pc;
        endcase
    end

    //==========================================================================
    // State machine and pipeline register updates
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_IDLE;
            ir              <= NOP_INST;
            ir_addr         <= 16'h0000;
            fetch_pc        <= 16'h0000;
            mem_addr_q      <= 16'h0000;
            prefetch_valid  <= 1'b0;
            prev_wtaddr     <= 4'd0;
            prev_wtdata     <= 16'h0000;
            prev_wtenable   <= 1'b0;
            saved_is_load   <= 1'b0;
            saved_is_store  <= 1'b0;
            saved_rd        <= 4'd0;
            saved_cond_match<= 1'b0;
            saved_data_addr <= 16'h0000;
            wb_rd_latch     <= 4'd0;
            wb_load_en_latch<= 1'b0;
            wb_is_load_r15_latch <= 1'b0;
        end else begin
            mem_addr_q <= mem_addr;

            case (state)
                //==============================================================
                // S_IDLE
                //==============================================================
                S_IDLE: begin
                    if (is_mem_access) begin
                        // Latch writeback signals for S_MEM_RESP
                        // These use CURRENT cycle's combinational values (no race)
                        wb_rd_latch          <= rd;
                        wb_load_en_latch     <= cond_match && is_load;
                        wb_is_load_r15_latch <= cond_match && is_load && (rd == 4'd15);

                        prefetch_buf    <= mem_rdata;
                        prefetch_addr   <= mem_addr_q;
                        prefetch_valid  <= 1'b1;

                        saved_is_load    <= is_load;
                        saved_is_store   <= is_store;
                        saved_rd         <= rd;
                        saved_cond_match <= cond_match;
                        saved_data_addr  <= data_addr;

                        ir              <= NOP_INST;
                        ir_addr         <= 16'h0000;
                        fetch_pc        <= fetch_pc;
                        state           <= S_MEM_RESP;

                        prev_wtaddr     <= 4'd0;
                        prev_wtdata     <= 16'h0000;
                        prev_wtenable   <= 1'b0;
                    end else if (is_alu_r15) begin
                        ir              <= NOP_INST;
                        ir_addr         <= 16'h0000;
                        fetch_pc        <= alu_result + 16'd1;
                        state           <= S_FLUSH1;

                        prev_wtaddr     <= 4'd0;
                        prev_wtdata     <= 16'h0000;
                        prev_wtenable   <= 1'b0;
                    end else begin
                        ir              <= mem_rdata;
                        ir_addr         <= mem_addr_q;
                        fetch_pc        <= fetch_pc + 16'd1;
                        state           <= S_IDLE;

                        prev_wtaddr     <= wtaddr;
                        prev_wtdata     <= wtdata;
                        prev_wtenable   <= wtenable &&
                                           (wtaddr != 4'd0) &&
                                           (wtaddr != 4'd14) &&
                                           (wtaddr != 4'd15);
                    end
                end

                //==============================================================
                // S_MEM_RESP
                //==============================================================
                S_MEM_RESP: begin
                    if (!mem_ready) begin
                        state <= S_MEM_RESP;
                    end else begin
                        if (is_load_r15_branch) begin
                            ir              <= NOP_INST;
                            ir_addr         <= 16'h0000;
                            fetch_pc        <= mem_rdata[15:0] + 16'd1;
                            state           <= S_FLUSH1;
                            prefetch_valid  <= 1'b0;

                            prev_wtaddr     <= 4'd0;
                            prev_wtdata     <= 16'h0000;
                            prev_wtenable   <= 1'b0;
                        end else begin
                            ir              <= prefetch_buf;
                            ir_addr         <= prefetch_addr;
                            prefetch_valid  <= 1'b0;
                            fetch_pc        <= fetch_pc + 16'd1;
                            state           <= S_IDLE;

                            prev_wtaddr     <= wtaddr;
                            prev_wtdata     <= wtdata;
                            prev_wtenable   <= wtenable &&
                                               (wtaddr != 4'd0) &&
                                               (wtaddr != 4'd14) &&
                                               (wtaddr != 4'd15);
                        end
                    end
                end

                //==============================================================
                // S_FLUSH1
                //==============================================================
                S_FLUSH1: begin
                    ir              <= mem_rdata;
                    ir_addr         <= mem_addr_q;
                    fetch_pc        <= fetch_pc + 16'd1;
                    state           <= S_IDLE;

                    prev_wtaddr     <= 4'd0;
                    prev_wtdata     <= 16'h0000;
                    prev_wtenable   <= 1'b0;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
