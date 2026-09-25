`timescale 1ns / 1ps

//==============================================================================
// k16 CPU Testbench — 同期RAM再設計版
//
// 構成:
//   tb_cpu → memory_subsystem → ram + mmio_stub
//                ↑
//              cpu
//
// テスト項目 (sim_test.py と同じ10ケース + α):
//   1. ALU→ALU forwarding
//   2. LOAD→ALU (load-use)
//   3. LOAD→STORE
//   4. STORE→LOAD
//   5. ALU→r15 (branch)
//   6. LOAD→r15 (branch via memory)
//   7. Conditional LOAD skip
//   8. back-to-back LOAD→ADD
//   9. MMIO LOAD/STORE
//   10. r15 read (PC-relative)
//==============================================================================

module tb_cpu;

    reg clk;
    reg rst;

    // ===== CPU ↔ Memory Subsystem =====
    wire        mem_data_req;
    wire [15:0] mem_addr;
    wire [23:0] mem_wdata;
    wire        mem_we;
    wire [23:0] mem_rdata;
    wire        mem_ready;

    // ===== Memory Subsystem ↔ MMIO stub =====
    wire        mmio_req;
    wire [7:0]  mmio_addr;
    wire [23:0] mmio_wdata;
    wire        mmio_we;
    wire [23:0] mmio_rdata;
    wire        mmio_ready;

    // ===== CPU instance =====
    cpu u_cpu (
        .clk          (clk),
        .rst          (rst),
        .mem_data_req (mem_data_req),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_we       (mem_we),
        .mem_rdata    (mem_rdata),
        .mem_ready    (mem_ready)
    );

    // ===== Memory Subsystem instance =====
    memory_subsystem #(
        .RAM_ADDR_WIDTH (14)
    ) u_memsub (
        .clk        (clk),
        .rst        (rst),
        .mem_data_req (mem_data_req),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_we       (mem_we),
        .mem_rdata    (mem_rdata),
        .mem_ready    (mem_ready),
        .mmio_req     (mmio_req),
        .mmio_addr    (mmio_addr),
        .mmio_wdata   (mmio_wdata),
        .mmio_we      (mmio_we),
        .mmio_rdata   (mmio_rdata),
        .mmio_ready   (mmio_ready)
    );

    // ===== MMIO stub (minimal: LED + BTN) =====
    // We don't instantiate the full mmio.v here for simplicity.
    // This stub implements:
    //   0x10 (LED): R/W 16-bit register
    //   0x20 (BTN): Read-only, returns 0x7 (all buttons pressed for test)
    //   All other addresses: return 0
    reg [15:0] led_reg;
    reg [23:0] mmio_rdata_reg;

    assign mmio_rdata = mmio_rdata_reg;
    assign mmio_ready = 1'b1;  // MMIO always ready in stub

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            led_reg <= 16'b0;
            mmio_rdata_reg <= 24'b0;
        end else begin
            // Write
            if (mmio_req && mmio_we) begin
                case (mmio_addr)
                    8'h10: led_reg <= mmio_wdata[15:0];
                endcase
            end
            // Read (sync, 1-cycle latency)
            if (mmio_req && !mmio_we) begin
                case (mmio_addr)
                    8'h10: mmio_rdata_reg <= {8'b0, led_reg};
                    8'h20: mmio_rdata_reg <= 24'h7;  // BTN = 0b111
                    default: mmio_rdata_reg <= 24'b0;
                endcase
            end
        end
    end

    // ===== Clock =====
    always #5 clk = ~clk;

    // ===== Helpers =====
    function [23:0] encode_r(input [2:0] cond, input [3:0] rd, input [3:0] rs1, input [3:0] rs2, input [2:0] funct);
        encode_r = {cond, 2'b00, rd, rs1, rs2, 4'b0000, funct};
    endfunction

    function [23:0] encode_i(input [2:0] cond, input [3:0] rd, input [3:0] rs, input [7:0] im, input [2:0] funct);
        encode_i = {cond, 2'b01, rd, rs, im, funct};
    endfunction

    function [23:0] encode_ls(input [2:0] cond, input [3:0] rd, input [3:0] base, input [8:0] im, input [1:0] funct);
        encode_ls = {cond, 2'b11, rd, base, im, funct};
    endfunction

    localparam [23:0] NOP = 24'h800000;

    integer errors = 0;
    integer test_num = 0;

    // ===== Load program into RAM =====
    task load_program;
        integer i;
        begin
            // Initialize RAM with NOP
            for (i = 0; i < 16384; i = i + 1)
                u_memsub.u_ram.memory[i] = NOP;

            // Default test program (Test 1: ALU→ALU)
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd1, 4'd0, 8'd10, 3'b100); // r1=10
            u_memsub.u_ram.memory[1] = encode_i(3'b000, 4'd2, 4'd0, 8'd5,  3'b100); // r2=5
            u_memsub.u_ram.memory[2] = encode_r(3'b000, 4'd3, 4'd1, 4'd2,  3'b100); // r3=r1+r2=15
            u_memsub.u_ram.memory[3] = encode_r(3'b000, 4'd4, 4'd3, 4'd1,  3'b100); // r4=r3+r1=25
            u_memsub.u_ram.memory[4] = encode_r(3'b000, 4'd5, 4'd4, 4'd2,  3'b100); // r5=r4+r2=30
            u_memsub.u_ram.memory[5] = NOP;
        end
    endtask

    task reset_cpu;
        begin
            clk = 0;
            rst = 1;
            #20;
            rst = 0;
            #5;
        end
    endtask

    task check_reg(input [3:0] rn, input [15:0] expected, input [127:0] msg);
        begin
            if (u_cpu.u_regfile.regs[rn] === expected) begin
                $display("[PASS] %0s: r%0d = %0d (0x%04h)", msg, rn, u_cpu.u_regfile.regs[rn], u_cpu.u_regfile.regs[rn]);
            end else begin
                $display("[FAIL] %0s: r%0d = %0d (0x%04h), expected %0d (0x%04h)",
                         msg, rn, u_cpu.u_regfile.regs[rn], u_cpu.u_regfile.regs[rn],
                         expected, expected);
                errors = errors + 1;
            end
        end
    endtask

    task check_mem(input [13:0] addr, input [23:0] expected, input [127:0] msg);
        begin
            if (u_memsub.u_ram.memory[addr] === expected) begin
                $display("[PASS] %0s: mem[%0d] = 0x%06h", msg, addr, u_memsub.u_ram.memory[addr]);
            end else begin
                $display("[FAIL] %0s: mem[%0d] = 0x%06h, expected 0x%06h",
                         msg, addr, u_memsub.u_ram.memory[addr], expected);
                errors = errors + 1;
            end
        end
    endtask

    task check_led(input [15:0] expected, input [127:0] msg);
        begin
            if (led_reg === expected) begin
                $display("[PASS] %0s: LED = 0x%04h", msg, led_reg);
            end else begin
                $display("[FAIL] %0s: LED = 0x%04h, expected 0x%04h", msg, led_reg, expected);
                errors = errors + 1;
            end
        end
    endtask

    // ===== Test 1: ALU → ALU =====
    task test_alu_alu;
        begin
            test_num = 1;
            $display("\n=== Test 1: ALU → ALU ===");
            load_program;
            // Program already loaded by load_program
            reset_cpu;
            #100;
            check_reg(4'd1, 16'd10, "r1=10");
            check_reg(4'd2, 16'd5,  "r2=5");
            check_reg(4'd3, 16'd15, "r3=15");
            check_reg(4'd4, 16'd25, "r4=25 (fwd)");
            check_reg(4'd5, 16'd30, "r5=30 (fwd)");
        end
    endtask

    // ===== Test 2: LOAD → ALU =====
    task test_load_alu;
        begin
            test_num = 2;
            $display("\n=== Test 2: LOAD → ALU ===");
            load_program;
            // Setup data
            u_memsub.u_ram.memory[100] = 24'hAB1234;
            // Program
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd2, 4'd0, 8'd100, 3'b100); // r2=100
            u_memsub.u_ram.memory[1] = encode_ls(3'b000, 4'd1, 4'd2, 9'd0, 2'b00);   // r1=mem[100]
            u_memsub.u_ram.memory[2] = encode_r(3'b000, 4'd3, 4'd1, 4'd0, 3'b100);   // r3=r1+0
            u_memsub.u_ram.memory[3] = NOP;
            reset_cpu;
            #200;
            check_reg(4'd1, 16'h1234, "r1=0x1234");
            check_reg(4'd3, 16'h1234, "r3=r1 (load-use)");
            if (u_cpu.u_regfile.regs[13][7:0] === 8'hAB) begin
                $display("[PASS] r13[7:0]=0xAB");
            end else begin
                $display("[FAIL] r13[7:0]=0x%02h, expected 0xAB", u_cpu.u_regfile.regs[13][7:0]);
                errors = errors + 1;
            end
        end
    endtask

    // ===== Test 3: LOAD → STORE =====
    task test_load_store;
        begin
            test_num = 3;
            $display("\n=== Test 3: LOAD → STORE ===");
            load_program;
            u_memsub.u_ram.memory[50] = 24'hDE5678;
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd2, 4'd0, 8'd50, 3'b100); // r2=50
            u_memsub.u_ram.memory[1] = encode_i(3'b000, 4'd3, 4'd0, 8'd60, 3'b100); // r3=60
            u_memsub.u_ram.memory[2] = encode_ls(3'b000, 4'd1, 4'd2, 9'd0, 2'b00);  // r1=mem[50]
            u_memsub.u_ram.memory[3] = encode_ls(3'b000, 4'd1, 4'd3, 9'd0, 2'b10);  // mem[60]={r13,r1}
            u_memsub.u_ram.memory[4] = NOP;
            reset_cpu;
            #200;
            check_mem(14'd60, 24'hDE5678, "mem[60]=0xDE5678");
        end
    endtask

    // ===== Test 4: STORE → LOAD =====
    task test_store_load;
        begin
            test_num = 4;
            $display("\n=== Test 4: STORE → LOAD ===");
            load_program;
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd1,  4'd0, 8'h42,  3'b100); // r1=0x42
            u_memsub.u_ram.memory[1] = encode_i(3'b000, 4'd13, 4'd0, 8'h99,  3'b100); // r13=0x99
            u_memsub.u_ram.memory[2] = encode_i(3'b000, 4'd2,  4'd0, 8'd70,  3'b100); // r2=70
            u_memsub.u_ram.memory[3] = encode_ls(3'b000, 4'd1,  4'd2, 9'd0, 2'b10);   // mem[70]={0x99,0x42}
            u_memsub.u_ram.memory[4] = encode_ls(3'b000, 4'd3,  4'd2, 9'd0, 2'b00);   // r3=mem[70][15:0]
            u_memsub.u_ram.memory[5] = NOP;
            reset_cpu;
            #200;
            check_mem(14'd70, 24'h990042, "mem[70]=0x990042");
            check_reg(4'd3, 16'h0042, "r3=0x42");
            if (u_cpu.u_regfile.regs[13][7:0] === 8'h99) begin
                $display("[PASS] r13[7:0]=0x99");
            end else begin
                $display("[FAIL] r13[7:0]=0x%02h", u_cpu.u_regfile.regs[13][7:0]);
                errors = errors + 1;
            end
        end
    endtask

    // ===== Test 5: ALU → r15 (Branch) =====
    task test_branch;
        begin
            test_num = 5;
            $display("\n=== Test 5: ALU → r15 (Branch) ===");
            load_program;
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd1,  4'd0, 8'd10, 3'b100); // r1=10
            u_memsub.u_ram.memory[1] = encode_i(3'b000, 4'd15, 4'd1, 8'd0,  3'b100); // r15=r1=10 (branch)
            u_memsub.u_ram.memory[2] = encode_i(3'b000, 4'd2,  4'd0, 8'd99, 3'b100); // SKIPPED
            u_memsub.u_ram.memory[3] = encode_i(3'b000, 4'd2,  4'd0, 8'd88, 3'b100); // SKIPPED
            u_memsub.u_ram.memory[10] = encode_i(3'b000, 4'd3, 4'd0, 8'd77, 3'b100); // r3=77 (target)
            u_memsub.u_ram.memory[11] = encode_i(3'b000, 4'd4, 4'd0, 8'd55, 3'b100); // r4=55
            u_memsub.u_ram.memory[12] = NOP;
            reset_cpu;
            #200;
            check_reg(4'd1, 16'd10, "r1=10");
            check_reg(4'd2, 16'd0,  "r2=0 (stale skipped)");
            check_reg(4'd3, 16'd77, "r3=77 (branch target)");
            check_reg(4'd4, 16'd55, "r4=55");
        end
    endtask

    // ===== Test 6: LOAD → r15 =====
    task test_load_r15;
        begin
            test_num = 6;
            $display("\n=== Test 6: LOAD → r15 ===");
            load_program;
            u_memsub.u_ram.memory[50] = 24'hAA0020;  // TARGET=0x20=32
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd1,  4'd0, 8'd50, 3'b100); // r1=50
            u_memsub.u_ram.memory[1] = encode_ls(3'b000, 4'd15, 4'd1, 9'd0, 2'b00);  // r15=mem[50]
            u_memsub.u_ram.memory[2] = encode_i(3'b000, 4'd2,  4'd0, 8'd99, 3'b100); // SKIPPED
            u_memsub.u_ram.memory[3] = encode_i(3'b000, 4'd2,  4'd0, 8'd88, 3'b100); // SKIPPED
            u_memsub.u_ram.memory[32] = encode_i(3'b000, 4'd3, 4'd0, 8'd42, 3'b100); // r3=42 (target)
            u_memsub.u_ram.memory[33] = encode_i(3'b000, 4'd4, 4'd0, 8'd33, 3'b100); // r4=33
            u_memsub.u_ram.memory[34] = NOP;
            reset_cpu;
            #200;
            check_reg(4'd2, 16'd0,  "r2=0 (stale skipped)");
            check_reg(4'd3, 16'd42, "r3=42 (target)");
            check_reg(4'd4, 16'd33, "r4=33");
            if (u_cpu.u_regfile.regs[13][7:0] === 8'hAA) begin
                $display("[PASS] r13[7:0]=0xAA");
            end else begin
                $display("[FAIL] r13[7:0]=0x%02h", u_cpu.u_regfile.regs[13][7:0]);
                errors = errors + 1;
            end
        end
    endtask

    // ===== Test 7: Conditional LOAD skip =====
    task test_conditional_skip;
        begin
            test_num = 7;
            $display("\n=== Test 7: Conditional LOAD skip ===");
            load_program;
            u_memsub.u_ram.memory[50] = 24'hAA1111;
            u_memsub.u_ram.memory[60] = 24'hBB2222;
            u_memsub.u_ram.memory[0] = encode_r(3'b000,  4'd1, 4'd0, 4'd0, 3'b101); // r1=0-0=0, Z=1
            u_memsub.u_ram.memory[1] = encode_ls(3'b001, 4'd2, 4'd0, 9'd50, 2'b00); // LOAD.ne (skip)
            u_memsub.u_ram.memory[2] = encode_r(3'b000,  4'd3, 4'd0, 4'd0, 3'b101); // r3=0-0=0, Z=1
            u_memsub.u_ram.memory[3] = encode_ls(3'b101, 4'd4, 4'd0, 9'd60, 2'b00); // LOAD.eq (exec)
            u_memsub.u_ram.memory[4] = NOP;
            reset_cpu;
            #200;
            check_reg(4'd2, 16'd0,     "r2=0 (LOAD.ne skipped)");
            check_reg(4'd4, 16'h2222,  "r4=0x2222 (LOAD.eq exec)");
            if (u_cpu.u_regfile.regs[13][7:0] === 8'hBB) begin
                $display("[PASS] r13[7:0]=0xBB");
            end else begin
                $display("[FAIL] r13[7:0]=0x%02h", u_cpu.u_regfile.regs[13][7:0]);
                errors = errors + 1;
            end
        end
    endtask

    // ===== Test 8: back-to-back LOAD → ADD =====
    task test_back_to_back_load;
        begin
            test_num = 8;
            $display("\n=== Test 8: back-to-back LOAD → ADD ===");
            load_program;
            u_memsub.u_ram.memory[50] = 24'h00100;
            u_memsub.u_ram.memory[60] = 24'h00200;
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd2, 4'd0, 8'd50, 3'b100); // r2=50
            u_memsub.u_ram.memory[1] = encode_i(3'b000, 4'd4, 4'd0, 8'd60, 3'b100); // r4=60
            u_memsub.u_ram.memory[2] = encode_ls(3'b000, 4'd1, 4'd2, 9'd0, 2'b00);  // r1=mem[50]
            u_memsub.u_ram.memory[3] = encode_ls(3'b000, 4'd3, 4'd4, 9'd0, 2'b00);  // r3=mem[60]
            u_memsub.u_ram.memory[4] = encode_r(3'b000, 4'd5, 4'd1, 4'd3, 3'b100);  // r5=r1+r3
            u_memsub.u_ram.memory[5] = NOP;
            reset_cpu;
            #300;
            check_reg(4'd1, 16'h0100, "r1=0x100");
            check_reg(4'd3, 16'h0200, "r3=0x200");
            check_reg(4'd5, 16'h0300, "r5=0x300");
        end
    endtask

    // ===== Test 9: MMIO LOAD/STORE =====
    task test_mmio;
        begin
            test_num = 9;
            $display("\n=== Test 9: MMIO LOAD/STORE ===");
            load_program;
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd1, 4'd0, 8'hAB, 3'b100); // r1=0xAB
            // Need r2 = 0xFF10. Build via shift+or: 0xFF = 255, 0xFF10 = 0xFF<<8 | 0x10
            // Or use ADC to combine: r2 = 0xFF, then shift left 8 times
            // Simpler: load 0xFF10 directly via two ops:
            //   r2 = 0xFF (immediate)
            //   r3 = 0xFF00 (r2 << 8 — but no shift-left instruction; use ADC chain)
            // Easier: pre-set r2 via separate sequence
            // For test, just use BTN at 0xFF20 (read-only)
            // We'll test MMIO via BTN read
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd2, 4'd0, 8'hFF, 3'b100); // r2=0xFF
            u_memsub.u_ram.memory[1] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // r2=0xFF+0xFF=0x1FE
            u_memsub.u_ram.memory[2] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // r2=0x1FE+0x1FE=0x3FC
            u_memsub.u_ram.memory[3] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // r2=0x3FC+0x3FC=0x7F8
            u_memsub.u_ram.memory[4] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // r2=0x7F8+0x7F8=0xFF0
            u_memsub.u_ram.memory[5] = encode_i(3'b000, 4'd2, 4'd2, 8'h10, 3'b100); // r2=0xFF0+0x10=0x1000
            // Hmm, that's 0x1000 not 0xFF10. Let me try another approach.
            // Use the 9-bit immediate in LOAD/STORE directly with offset
            // LOAD r1, [r0 + 0xFF10] — but offset is 9-bit only (0-511), 0xFF10 doesn't fit
            // Need r2 = 0xFF10 first. Approach: shift 0xFF left 8 times using SHR... no, no SHL.
            // Alternative: Use multiple ADDs to build the address.
            // Actually, easier test: write to LED via STORE [r2 + offset], r1 where r2=0xFF00
            // r2 = 0xFF00: build via 0xFF * 256
            // r2 = 0xFF, then r2 = r2 + r2 = 0x1FE (×2), repeat...
            // After 8 doublings: 0xFF * 256 = 0xFF00
            u_memsub.u_ram.memory[0] = encode_i(3'b000, 4'd2, 4'd0, 8'hFF, 3'b100); // r2=0xFF
            u_memsub.u_ram.memory[1] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // 0x1FE
            u_memsub.u_ram.memory[2] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // 0x3FC
            u_memsub.u_ram.memory[3] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // 0x7F8
            u_memsub.u_ram.memory[4] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // 0xFF0
            u_memsub.u_ram.memory[5] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // 0x1FE0
            u_memsub.u_ram.memory[6] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // 0x3FC0
            u_memsub.u_ram.memory[7] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // 0x7F80
            u_memsub.u_ram.memory[8] = encode_r(3'b000, 4'd2, 4'd2, 4'd2, 3'b100);  // 0xFF00
            u_memsub.u_ram.memory[9] = encode_i(3'b000, 4'd1, 4'd0, 8'hAB, 3'b100); // r1=0xAB
            u_memsub.u_ram.memory[10] = encode_ls(3'b000, 4'd1, 4'd2, 9'h10, 2'b10); // STORE [r2+0x10]=LED, r1
            u_memsub.u_ram.memory[11] = encode_ls(3'b000, 4'd3, 4'd2, 9'h10, 2'b00); // r3=LED
            u_memsub.u_ram.memory[12] = NOP;
            reset_cpu;
            #500;
            check_led(16'hAB, "LED=0xAB");
            check_reg(4'd3, 16'hAB, "r3=LED readback");
        end
    endtask

    // ===== Test 10: r15 read (PC-relative) =====
    task test_pc_relative;
        begin
            test_num = 10;
            $display("\n=== Test 10: r15 read (PC-relative) ===");
            load_program;
            u_memsub.u_ram.memory[0] = encode_r(3'b000, 4'd1, 4'd15, 4'd0, 3'b100); // r1=r15=0
            u_memsub.u_ram.memory[1] = encode_r(3'b000, 4'd2, 4'd15, 4'd0, 3'b100); // r2=r15=1
            u_memsub.u_ram.memory[2] = NOP;
            reset_cpu;
            #100;
            check_reg(4'd1, 16'd0, "r1=PC=0");
            check_reg(4'd2, 16'd1, "r2=PC=1");
        end
    endtask

    // ===== Main =====
    initial begin
        $dumpfile("tb_cpu.vcd");
        $dumpvars(0, tb_cpu);

        $display("======================================");
        $display("k16 CPU Testbench (Sync RAM redesign)");
        $display("======================================");

        test_alu_alu;
        test_load_alu;
        test_load_store;
        test_store_load;
        test_branch;
        test_load_r15;
        test_conditional_skip;
        test_back_to_back_load;
        test_mmio;
        test_pc_relative;

        $display("\n======================================");
        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("TOTAL ERRORS: %0d", errors);
        end
        $display("======================================");
        $finish;
    end

    // Safety timeout
    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
