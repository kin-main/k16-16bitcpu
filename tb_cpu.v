`timescale 1ns / 1ps

module tb_cpu;

    reg clk;
    reg rst;

    reg uart_rx;
    wire uart_tx;

    localparam CLKS_PER_BIT = 10;

    //==========================================================================
    // SoC
    //==========================================================================

    k16_soc #(
        .CLKS_PER_BIT (CLKS_PER_BIT),
        .INIT_FILE    ("")
    ) u_soc (
        .clk     (clk),
        .rst     (rst),
        .uart_rx (uart_rx),
        .uart_tx (uart_tx)
    );

    //==========================================================================
    // Clock
    //==========================================================================

    always #5 clk = ~clk;

    //==========================================================================
    // Instruction encoding
    //==========================================================================

    function [23:0] encode_r(
        input [2:0] cond,
        input [3:0] rd,
        input [3:0] rs1,
        input [3:0] rs2,
        input [2:0] funkt
    );
        begin
            encode_r =
                (cond  << 21) |
                (2'b00 << 19) |
                (rd    << 15) |
                (rs1   << 11) |
                (rs2   << 7)  |
                (funkt & 3'b111);
        end
    endfunction

    function [23:0] encode_i(
        input [2:0] cond,
        input [3:0] rd,
        input [3:0] rs,
        input [7:0] im,
        input [2:0] funkt
    );
        begin
            encode_i =
                (cond  << 21) |
                (2'b01 << 19) |
                (rd    << 15) |
                (rs    << 11) |
                ((im & 8'hFF) << 3) |
                (funkt & 3'b111);
        end
    endfunction

    function [23:0] encode_ls(
        input [2:0] cond,
        input [3:0] rd,
        input [3:0] base,
        input [8:0] im,
        input [1:0] funkt
    );
        begin
            encode_ls =
                (cond  << 21) |
                (2'b11 << 19) |
                (rd    << 15) |
                (base  << 11) |
                ((im & 9'h1FF) << 2) |
                (funkt & 2'b11);
        end
    endfunction

    //==========================================================================
    // UART helper
    //==========================================================================

    task send_uart_byte(input [7:0] data);

        integer i;

        begin

            uart_rx = 1'b0;
            #(CLKS_PER_BIT * 10);

            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = data[i];
                #(CLKS_PER_BIT * 10);
            end

            uart_rx = 1'b1;
            #(CLKS_PER_BIT * 10);

        end

    endtask

    //==========================================================================
    // Test
    //==========================================================================

    integer errors;

    initial begin

        clk     = 1'b0;
        rst     = 1'b1;
        uart_rx = 1'b1;

        errors  = 0;

        $dumpfile("tb_cpu.vcd");
        $dumpvars(0, tb_cpu);

        //======================================================================
        // 16K RAM initialization
        //
        // IMPORTANT:
        // RAM is 0..16383 only.
        //======================================================================

        for (integer i = 0; i < 16384; i = i + 1) begin
            u_soc.u_ram.memory[i] =
                24'b100_00_0000_0000_0000_0000_000;
        end

        //======================================================================
        // Program
        //======================================================================

        // 0: r1 = 10
        u_soc.u_ram.memory[0] =
            encode_i(3'b000, 4'd1, 4'd0, 8'd10, 3'b100);

        // 1: r2 = 5
        u_soc.u_ram.memory[1] =
            encode_i(3'b000, 4'd2, 4'd0, 8'd5, 3'b100);

        // 2: r3 = r1 + r2 = 15
        u_soc.u_ram.memory[2] =
            encode_r(3'b000, 4'd3, 4'd1, 4'd2, 3'b100);

        // 3: r4 = r1 - r2 = 5
        u_soc.u_ram.memory[3] =
            encode_r(3'b000, 4'd4, 4'd1, 4'd2, 3'b101);

        // 4: r5 = r1 & r2 = 0
        u_soc.u_ram.memory[4] =
            encode_r(3'b000, 4'd5, 4'd1, 4'd2, 3'b010);

        // 5: r6 = r1 | r2 = 15
        u_soc.u_ram.memory[5] =
            encode_r(3'b000, 4'd6, 4'd1, 4'd2, 3'b001);

        // 6: r7 = r1 ^ r2 = 15
        u_soc.u_ram.memory[6] =
            encode_r(3'b000, 4'd7, 4'd1, 4'd2, 3'b011);

        // 7: r8 = r1 >> 1 = 5
        u_soc.u_ram.memory[7] =
            encode_r(3'b000, 4'd8, 4'd1, 4'd0, 3'b111);

        // 8: r9 = r1 - r1 = 0
        u_soc.u_ram.memory[8] =
            encode_r(3'b000, 4'd9, 4'd1, 4'd1, 3'b101);

        // 9: Z==0なら実行。現在Z=1なのでスキップ
        u_soc.u_ram.memory[9] =
            encode_i(3'b001, 4'd11, 4'd0, 8'd88, 3'b100);

        // 10: Z==1ならr10=77
        u_soc.u_ram.memory[10] =
            encode_i(3'b101, 4'd10, 4'd0, 8'd77, 3'b100);

        // 11: r13 = 0x5A
        u_soc.u_ram.memory[11] =
            encode_i(3'b000, 4'd13, 4'd0, 8'h5A, 3'b100);

        // 12: mem[r1+2] = {r13[7:0],r3}
        u_soc.u_ram.memory[12] =
            encode_ls(3'b000, 4'd3, 4'd1, 9'd2, 2'b10);

        // 13: r12 = mem[r1+2]
        u_soc.u_ram.memory[13] =
            encode_ls(3'b000, 4'd12, 4'd1, 9'd2, 2'b00);

        // 14: r15 = 20
        u_soc.u_ram.memory[14] =
            encode_i(3'b000, 4'd15, 4'd0, 8'd20, 3'b100);

        // 15: should be flushed
        u_soc.u_ram.memory[15] =
            encode_i(3'b000, 4'd12, 4'd0, 8'd99, 3'b100);

        // 16..19 remain NOP

        // 20: r1 = r1 + 1 = 11
        u_soc.u_ram.memory[20] =
            encode_i(3'b000, 4'd1, 4'd1, 8'd1, 3'b100);

        // 21: NAND
        u_soc.u_ram.memory[21] =
            encode_r(3'b000, 4'd2, 4'd1, 4'd1, 3'b000);

        // 22: r4 = 0 - 50 = -50
        u_soc.u_ram.memory[22] =
            encode_i(3'b000, 4'd4, 4'd0, 8'd50, 3'b101);

        // 23: N==0 -> skip
        u_soc.u_ram.memory[23] =
            encode_i(3'b011, 4'd6, 4'd0, 8'd200, 3'b100);

        // 24: N==1 -> r5=123
        u_soc.u_ram.memory[24] =
            encode_i(3'b111, 4'd5, 4'd0, 8'd123, 3'b100);

        // 25: r13=0x77
        u_soc.u_ram.memory[25] =
            encode_i(3'b000, 4'd13, 4'd0, 8'h77, 3'b100);

        // 26: r7=99
        u_soc.u_ram.memory[26] =
            encode_i(3'b000, 4'd7, 4'd0, 8'd99, 3'b100);

        // 27: mem[r1-1] = {77,99}
        u_soc.u_ram.memory[27] =
            encode_ls(3'b000, 4'd7, 4'd1, 9'd1, 2'b11);

        // 28: r8 = mem[r1-1]
        u_soc.u_ram.memory[28] =
            encode_ls(3'b000, 4'd8, 4'd1, 9'd1, 2'b01);

        // 29: r3 = r13
        u_soc.u_ram.memory[29] =
            encode_r(3'b000, 4'd3, 4'd13, 4'd0, 3'b100);

        // 30: r9 = ~0 = FFFF
        u_soc.u_ram.memory[30] =
            encode_r(3'b000, 4'd9, 4'd0, 4'd0, 3'b000);

        // 31: r9 = FFFF - FF = FF00
        u_soc.u_ram.memory[31] =
            encode_i(3'b000, 4'd9, 4'd9, 8'hFF, 3'b101);

        // 32: UART status
        u_soc.u_ram.memory[32] =
            encode_ls(3'b000, 4'd11, 4'd9, 9'd1, 2'b00);

        // 33: r7='K'
        u_soc.u_ram.memory[33] =
            encode_i(3'b000, 4'd7, 4'd0, 8'h4B, 3'b100);

        // 34: UART TX
        u_soc.u_ram.memory[34] =
            encode_ls(3'b000, 4'd7, 4'd9, 9'd0, 2'b10);

        // 35: TX status
        u_soc.u_ram.memory[35] =
            encode_ls(3'b000, 4'd10, 4'd9, 9'd1, 2'b00);

        // 36: RX status
        u_soc.u_ram.memory[36] =
            encode_ls(3'b000, 4'd12, 4'd9, 9'd1, 2'b00);

        // 37: mask RX_READY bit
        u_soc.u_ram.memory[37] =
            encode_i(3'b000, 4'd12, 4'd12, 8'd2, 3'b010);

        // 38: if Z==1, jump to 36
        u_soc.u_ram.memory[38] =
            encode_i(3'b101, 4'd15, 4'd0, 8'd36, 3'b100);

        // 39: RX data
        u_soc.u_ram.memory[39] =
            encode_ls(3'b000, 4'd6, 4'd9, 9'd0, 2'b00);

        // 40: r0 write
        u_soc.u_ram.memory[40] =
            encode_i(3'b000, 4'd0, 4'd0, 8'd55, 3'b100);

        // 41: r2 = r0
        u_soc.u_ram.memory[41] =
            encode_r(3'b000, 4'd2, 4'd0, 4'd0, 3'b100);

        // 42: r11 = r14
        u_soc.u_ram.memory[42] =
            encode_r(3'b000, 4'd11, 4'd14, 4'd0, 3'b100);

        // 43: r14 write, should be ignored
        u_soc.u_ram.memory[43] =
            encode_i(3'b000, 4'd14, 4'd0, 8'd255, 3'b100);

        // 44: read r14
        u_soc.u_ram.memory[44] =
            encode_r(3'b000, 4'd5, 4'd14, 4'd0, 3'b100);

        // 45: read PC
        u_soc.u_ram.memory[45] =
            encode_r(3'b000, 4'd8, 4'd15, 4'd0, 3'b100);

        //======================================================================
        // Start
        //======================================================================

        #20;
        rst = 1'b0;

        // RX = 'Z'
        send_uart_byte(8'h5A);

        #6000;

        //======================================================================
        // Results
        //======================================================================

        $display("");
        $display("==============================================");
        $display(" k16 CPU TEST RESULT");
        $display("==============================================");

        // 1
        if (u_soc.u_cpu.u_regfile.regs[1] === 16'd11) begin
            $display("[PASS] r1 = 11");
        end else begin
            $display("[FAIL] r1 = %0d expected=11",
                     u_soc.u_cpu.u_regfile.regs[1]);
            errors = errors + 1;
        end

        // 2
        if (u_soc.u_cpu.u_regfile.regs[4] === 16'hFFCE) begin
            $display("[PASS] r4 = 0xFFCE");
        end else begin
            $display("[FAIL] r4 = 0x%04X expected=FFCE",
                     u_soc.u_cpu.u_regfile.regs[4]);
            errors = errors + 1;
        end

        // 3
        if (u_soc.u_ram.memory[12] === 24'h5A000F) begin
            $display("[PASS] mem[12] = 0x5A000F");
        end else begin
            $display("[FAIL] mem[12] = 0x%06X expected=5A000F",
                     u_soc.u_ram.memory[12]);
            errors = errors + 1;
        end

        // 4
        if (u_soc.u_ram.memory[10] === 24'h770063) begin
            $display("[PASS] mem[10] = 0x770063");
        end else begin
            $display("[FAIL] mem[10] = 0x%06X expected=770063",
                     u_soc.u_ram.memory[10]);
            errors = errors + 1;
        end

        // 5
        if (u_soc.u_cpu.u_regfile.regs[3][7:0] === 8'h77) begin
            $display("[PASS] r3[7:0] = 0x77");
        end else begin
            $display("[FAIL] r3[7:0] = 0x%02X expected=77",
                     u_soc.u_cpu.u_regfile.regs[3][7:0]);
            errors = errors + 1;
        end

        // 6
        if (u_soc.u_cpu.u_regfile.regs[10][0] === 1'b1) begin
            $display("[PASS] UART TX busy");
        end else begin
            $display("[FAIL] UART TX busy");
            errors = errors + 1;
        end

        // 7
        if (u_soc.u_cpu.u_regfile.regs[6][7:0] === 8'h5A) begin
            $display("[PASS] UART RX = 0x5A");
        end else begin
            $display("[FAIL] UART RX = 0x%02X expected=5A",
                     u_soc.u_cpu.u_regfile.regs[6][7:0]);
            errors = errors + 1;
        end

        // 8
        if ((u_soc.u_cpu.u_regfile.regs[0] === 16'd0) &&
            (u_soc.u_cpu.u_regfile.regs[2] === 16'd0)) begin
            $display("[PASS] r0");
        end else begin
            $display("[FAIL] r0");
            errors = errors + 1;
        end

        // 9
        if (u_soc.u_cpu.u_regfile.regs[11] === 16'd1) begin
            $display("[PASS] r14 flag read");
        end else begin
            $display("[FAIL] r14 flag read: %0d",
                     u_soc.u_cpu.u_regfile.regs[11]);
            errors = errors + 1;
        end

        // 10
        if (u_soc.u_cpu.u_regfile.regs[5] === 16'd0) begin
            $display("[PASS] r14 write ignored");
        end else begin
            $display("[FAIL] r14 write ignored: %0d",
                     u_soc.u_cpu.u_regfile.regs[5]);
            errors = errors + 1;
        end

        // 11
        if (u_soc.u_cpu.u_regfile.regs[8] === 16'd47) begin
            $display("[PASS] r15 read = 47");
        end else begin
            $display("[FAIL] r15 read = %0d expected=47",
                     u_soc.u_cpu.u_regfile.regs[8]);
            errors = errors + 1;
        end

        //======================================================================
        // Summary
        //======================================================================

        if (errors == 0) begin
            $display("");
            $display(">>> ALL TESTS PASSED <<<");
        end else begin
            $display("");
            $display(">>> %0d TEST(S) FAILED <<<", errors);
        end

        $finish;

    end

endmodule
