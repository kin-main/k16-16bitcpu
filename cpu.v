/*==============================================================================
 * k16 16-bit RISC CPU
 *
 * 16-bit data path
 * 24-bit instruction / memory word
 * 16K-word RAM
 *
 * 2-stage pipeline:
 *   IF/ID
 *   ID/EX
 *
 * Neumann architecture:
 *   instruction fetch and data access share one memory bus.
 *============================================================================*/

module cpu (
    input  wire        clk,
    input  wire        rst,

    output wire [15:0] mem_addr,
    output wire [23:0] mem_wdata,
    input  wire [23:0] mem_rdata,
    output wire        mem_we
);

    //==========================================================================
    // NOP
    //
    // cond = 100 (Never)
    //
    // 24bit:
    // [23:21] cond
    // [20:19] op
    // [18:15] rd
    // [14:11] rs1
    // [10:7]  rs2 / immediate
    // [6:3]   immediate / reserved
    // [2:0]   funct
    //
    // IMPORTANT:
    // 100_00_0000_0000_0000_000 is only 20 bits.
    // It would be zero-extended and become cond=000.
    // Therefore the NOP must explicitly contain 24 bits.
    //==========================================================================

    localparam [23:0] NOP_INST =
        24'b100_00_0000_0000_0000_0000_000;

    //==========================================================================
    // IF/ID
    //==========================================================================

    reg [23:0] if_id_ir;

    //==========================================================================
    // Decoder
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
    // ID/EX
    //==========================================================================

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

    //==========================================================================
    // ALU / condition
    //==========================================================================

    wire zf;
    wire cf;
    wire nf;

    wire ex_cond_match;

    cond_check u_cond_check (
        .cond  (id_ex_cond),
        .zf    (zf),
        .cf    (cf),
        .nf    (nf),
        .match (ex_cond_match)
    );

    //==========================================================================
    // Memory access
    //==========================================================================

    wire ex_is_mem_access;

    assign ex_is_mem_access =
        ex_cond_match &&
        (id_ex_is_load || id_ex_is_store);

    //==========================================================================
    // Register forwarding
    //==========================================================================

    reg        load_active_q;
    reg [3:0]  load_rd_q;

    reg        prev_wtenable;
    reg [3:0]  prev_wtaddr;
    reg [15:0] prev_wtdata;

    wire        wtenable;
    wire [3:0]  wtaddr;
    wire [15:0] wtdata;

    // r14 is the flag register.
    // It is read directly from the current ALU flags.
    wire [15:0] ex_rddata_a =
        (id_ex_rs1 == 4'd14)
        ? {13'b0, nf, cf, zf}
        : id_ex_rddata_a;

    wire [15:0] ex_rddata_b =
        (id_ex_rs2 == 4'd14)
        ? {13'b0, nf, cf, zf}
        : id_ex_rddata_b;

    //--------------------------------------------------------------------------
    // Load forwarding
    //--------------------------------------------------------------------------

    wire [15:0] load_fwd_r13 =
        {ex_rddata_a[15:8], mem_rdata[23:16]};

    wire [15:0] fwd_data_a =
        (load_active_q &&
         (load_rd_q == id_ex_rs1) &&
         (id_ex_rs1 != 4'd0) &&
         (id_ex_rs1 != 4'd14))
        ? wtdata

        : (load_active_q &&
           (id_ex_rs1 == 4'd13))
        ? load_fwd_r13

        : (prev_wtenable &&
           (prev_wtaddr == id_ex_rs1))
        ? prev_wtdata

        : ex_rddata_a;

    wire [15:0] load_fwd_r13_b =
        {ex_rddata_b[15:8], mem_rdata[23:16]};

    wire [15:0] fwd_data_b =
        (load_active_q &&
         (load_rd_q == id_ex_rs2) &&
         (id_ex_rs2 != 4'd0) &&
         (id_ex_rs2 != 4'd14))
        ? wtdata

        : (load_active_q &&
           (id_ex_rs2 == 4'd13))
        ? load_fwd_r13_b

        : (prev_wtenable &&
           (prev_wtaddr == id_ex_rs2))
        ? prev_wtdata

        : ex_rddata_b;

    //==========================================================================
    // ALU
    //==========================================================================

    wire [15:0] alu_in_a = fwd_data_a;

    wire [15:0] alu_in_b =
        id_ex_alu_src_imm
        ? id_ex_imm
        : fwd_data_b;

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
    // Register writeback
    //
    // ALU result:
    //   written in the current EX cycle
    //
    // LOAD:
    //   synchronous RAM returns data one clock later
    //==========================================================================

    assign wtenable =
        (ex_cond_match &&
         id_ex_reg_write &&
         !id_ex_is_load)
        ||
        load_active_q;

    assign wtaddr =
        load_active_q
        ? load_rd_q
        : id_ex_rd;

    assign wtdata =
        load_active_q
        ? mem_rdata[15:0]
        : alu_result;

    //==========================================================================
    // PC / memory bus
    //==========================================================================

    wire [15:0] pc;

    // A register write to r15 is a branch/jump.
    wire pc_write_now =
        wtenable &&
        (wtaddr == 4'd15);

    // Data access has priority over instruction fetch.
    wire [15:0] shared_addr =
        ex_is_mem_access
        ? alu_result
        : pc;

    assign mem_addr = shared_addr;

    //==========================================================================
    // Data access delay
    //
    // RAM is synchronous.
    // The instruction fetch cannot use the same bus during the data access.
    //==========================================================================

    reg data_access_q;

    always @(posedge clk or posedge rst) begin
        if (rst)
            data_access_q <= 1'b0;
        else
            data_access_q <= ex_is_mem_access;
    end

    //==========================================================================
    // Load stall
    //
    // Keep the instruction currently in IF/ID while LOAD is accessing memory.
    //==========================================================================

    wire load_stall =
        ex_cond_match &&
        id_ex_is_load;

    //==========================================================================
    // Pending instruction
    //
    // Because the RAM is synchronous, an instruction may already be returning
    // from the RAM while a LOAD is being executed.
    // Keep that instruction temporarily.
    //==========================================================================

    reg [23:0] pend_inst;
    reg        pend_valid;

    always @(posedge clk or posedge rst) begin

        if (rst) begin
            pend_inst  <= NOP_INST;
            pend_valid <= 1'b0;

        end else if (load_stall && !data_access_q) begin
            pend_inst  <= mem_rdata;
            pend_valid <= 1'b1;

        end else begin
            pend_valid <= 1'b0;
        end
    end

    //==========================================================================
    // Branch flush
    //==========================================================================

    reg branch_flush_q;

    always @(posedge clk or posedge rst) begin
        if (rst)
            branch_flush_q <= 1'b0;
        else
            branch_flush_q <= pc_write_now;
    end

    //==========================================================================
    // IF/ID pipeline register
    //==========================================================================

    always @(posedge clk or posedge rst) begin

        if (rst) begin

            if_id_ir <= NOP_INST;

        end else if (pc_write_now) begin

            // The instruction fetched from the old sequential PC must be killed.
            if_id_ir <= NOP_INST;

        end else if (load_stall) begin

            // Keep the current instruction while LOAD completes.
            if_id_ir <= if_id_ir;

        end else if (branch_flush_q) begin

            // Second branch-flush cycle.
            if_id_ir <= NOP_INST;

        end else if (data_access_q) begin

            // The bus was occupied by a data access in the previous cycle.
            if (pend_valid)
                if_id_ir <= pend_inst;
            else
                if_id_ir <= NOP_INST;

        end else begin

            // Normal synchronous RAM instruction fetch.
            if_id_ir <= mem_rdata;

        end
    end

    //==========================================================================
    // ID -> EX pipeline register
    //==========================================================================

    always @(posedge clk or posedge rst) begin

        if (rst) begin

            id_ex_cond        <= 3'b100;

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

        end else if (load_stall || pc_write_now) begin

            // Insert a bubble.
            id_ex_cond        <= 3'b100;

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

    //==========================================================================
    // LOAD tracking
    //==========================================================================

    always @(posedge clk or posedge rst) begin

        if (rst) begin

            load_active_q <= 1'b0;
            load_rd_q     <= 4'd0;

        end else begin

            load_active_q <=
                ex_cond_match &&
                id_ex_is_load;

            if (ex_cond_match && id_ex_is_load)
                load_rd_q <= id_ex_rd;

        end
    end

    //==========================================================================
    // Register file
    //==========================================================================

    wire [7:0] topout;

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

        .pc_hold   (ex_is_mem_access)
    );

    //==========================================================================
    // Store
    //==========================================================================

    assign mem_wdata =
        {topout, fwd_data_b};

    assign mem_we =
        ex_cond_match &&
        id_ex_is_store;

    //==========================================================================
    // Previous writeback history
    //==========================================================================

    always @(posedge clk or posedge rst) begin

        if (rst) begin

            prev_wtaddr   <= 4'd0;
            prev_wtdata   <= 16'd0;
            prev_wtenable <= 1'b0;

        end else begin

            prev_wtaddr   <= wtaddr;
            prev_wtdata   <= wtdata;

            prev_wtenable <=
                wtenable &&
                (wtaddr != 4'd0) &&
                (wtaddr != 4'd14);

        end
    end

endmodule
