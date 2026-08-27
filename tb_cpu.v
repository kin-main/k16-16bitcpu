`timescale 1ns / 1ps

module tb_cpu;

    reg clk;
    reg rst;

    // CPU - メモリ間インターフェース (ノイマン型: 単一の共有バス)
    wire [15:0] mem_addr;
    wire [23:0] mem_wdata;
    wire [23:0] mem_rdata;
    wire        mem_we;

    // CPUインスタンス
    cpu u_cpu (
        .clk        (clk),
        .rst        (rst),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_rdata  (mem_rdata),
        .mem_we     (mem_we)
    );

    // メモリインスタンス (命令・データ共用の単一ポート)
    ram u_ram (
        .clk        (clk),
        .addr       (mem_addr),
        .wdata      (mem_wdata),
        .rdata      (mem_rdata),
        .we         (mem_we)
    );

    // クロック生成 (10ns周期 = 100MHz)
    always #5 clk = ~clk;

    // テスト命令エンコーディングヘルパー関数
    // 1) レジスタ間演算 (op=00): cond(3) + 00 + rd(4) + rs1(4) + rs2(4) + 0000 + funkt(3)
    function [23:0] encode_r(input [2:0] cond, input [3:0] rd, input [3:0] rs1, input [3:0] rs2, input [2:0] funkt);
        encode_r = {cond, 2'b00, rd, rs1, rs2, 4'b0000, funkt};
    endfunction

    // 2) 即値演算 (op=01): cond(3) + 01 + rd(4) + rs(4) + im(8) + funkt(3)
    function [23:0] encode_i(input [2:0] cond, input [3:0] rd, input [3:0] rs, input [7:0] im, input [2:0] funkt);
        encode_i = {cond, 2'b01, rd, rs, im, funkt};
    endfunction

    // 3) ロード/ストア (op=11): cond(3) + 11 + rd(4) + base(4) + im(9) + funkt(2)
    function [23:0] encode_ls(input [2:0] cond, input [3:0] rd, input [3:0] base, input [8:0] im, input [1:0] funkt);
        encode_ls = {cond, 2'b11, rd, base, im, funkt};
    endfunction

    integer errors = 0;

    initial begin
        // 波形ダンプ
        $dumpfile("tb_cpu.vcd");
        $dumpvars(0, tb_cpu);

        clk = 0;
        rst = 1;

        // メモリ初期化 (全ゼロ)
        for (integer i = 0; i < 65536; i = i + 1) begin
            u_ram.memory[i] = 24'b100_00_0000_0000_0000_0000_000; // NOP
        end

        //======================================================
        // テストプログラム配置
        //======================================================
        // 0: r1 = r0 + 10 (ADDI r1, r0, 10)
        u_ram.memory[0]  = encode_i(3'b000, 4'd1, 4'd0, 8'd10, 3'b100);
        // 1: r2 = r0 + 5  (ADDI r2, r0, 5)
        u_ram.memory[1]  = encode_i(3'b000, 4'd2, 4'd0, 8'd5,  3'b100);
        // 2: r3 = r1 + r2 (ADD r3, r1, r2) -> 15
        u_ram.memory[2]  = encode_r(3'b000, 4'd3, 4'd1, 4'd2,  3'b100);
        // 3: r4 = r1 - r2 (SUB r4, r1, r2) -> 5
        u_ram.memory[3]  = encode_r(3'b000, 4'd4, 4'd1, 4'd2,  3'b101);
        // 4: r5 = r1 & r2 (AND r5, r1, r2) -> 0
        u_ram.memory[4]  = encode_r(3'b000, 4'd5, 4'd1, 4'd2,  3'b010);
        // 5: r6 = r1 | r2 (OR  r6, r1, r2) -> 15
        u_ram.memory[5]  = encode_r(3'b000, 4'd6, 4'd1, 4'd2,  3'b001);
        // 6: r7 = r1 ^ r2 (XOR r7, r1, r2) -> 15
        u_ram.memory[6]  = encode_r(3'b000, 4'd7, 4'd1, 4'd2,  3'b011);
        // 7: r8 = r1 >> 1 (SHR r8, r1)     -> 5
        u_ram.memory[7]  = encode_r(3'b000, 4'd8, 4'd1, 4'd0,  3'b111);
        // 8: r9 = r1 - r1 (SUB r9, r1, r1) -> 0, Z=1
        u_ram.memory[8]  = encode_r(3'b000, 4'd9, 4'd1, 4'd1,  3'b101);
        // 9: 条件付き実行: if (Z==0) r11 = r0 + 88 (不成立 -> スキップ)
        u_ram.memory[9]  = encode_i(3'b001, 4'd11, 4'd0, 8'd88, 3'b100);
        // 10: 条件付き実行: if (Z==1) r10 = r0 + 77 (成立 -> 実行)
        u_ram.memory[10] = encode_i(3'b101, 4'd10, 4'd0, 8'd77, 3'b100);
        // 11: r13の上位バイト設定用: r13 = r0 + 16'h5A
        u_ram.memory[11] = encode_i(3'b000, 4'd13, 4'd0, 8'h5A, 3'b100);
        // 12: Store: mem[r1 + 2] <= {r13[7:0], r3} = {8'h5A, 16'd15}
        u_ram.memory[12] = encode_ls(3'b000, 4'd3, 4'd1, 9'd2, 2'b10);
        // 13: Load: r12 <= mem[r1 + 2] (r12に15, r13[7:0]に8'h5Aが入る)
        u_ram.memory[13] = encode_ls(3'b000, 4'd12, 4'd1, 9'd2, 2'b00);
        // 14: ジャンプ: r15 = r0 + 20 (アドレス20へ分岐)
        u_ram.memory[14] = encode_i(3'b000, 4'd15, 4'd0, 8'd20, 3'b100);
        // 15: スキップされるはずの命令: r12 = r0 + 99
        u_ram.memory[15] = encode_i(3'b000, 4'd12, 4'd0, 8'd99, 3'b100);

        // 20: 分岐先命令: r1 = r1 + 1 (10 + 1 = 11)
        u_ram.memory[20] = encode_i(3'b000, 4'd1, 4'd1, 8'd1, 3'b100);
        // 21: NANDテスト: r2 = ~(r1 & r1) -> ~11
        u_ram.memory[21] = encode_r(3'b000, 4'd2, 4'd1, 4'd1, 3'b000);
        // 22: 負数・Nフラグテスト: r4 = 0 - 50 (SUB r4, r0, 50) -> -50, N=1
        u_ram.memory[22] = encode_i(3'b000, 4'd4, 4'd0, 8'd50, 3'b101);
        // 23: N==0条件テスト (不成立 -> スキップ): if (N==0) r6 = r0 + 200
        u_ram.memory[23] = encode_i(3'b011, 4'd6, 4'd0, 8'd200, 3'b100);
        // 24: N==1条件テスト (成立 -> 実行): if (N==1) r5 = r0 + 123
        u_ram.memory[24] = encode_i(3'b111, 4'd5, 4'd0, 8'd123, 3'b100);
        // 25: 減算オフセットStoreテスト: mem[r1 - 1] (アドレス10) <= {8'h77, 16'd99}
        u_ram.memory[25] = encode_i(3'b000, 4'd13, 4'd0, 8'h77, 3'b100);
        u_ram.memory[26] = encode_i(3'b000, 4'd7,  4'd0, 8'd99,  3'b100);
        u_ram.memory[27] = encode_ls(3'b000, 4'd7, 4'd1, 9'd1, 2'b11);
        // 28: 減算オフセットLoadテスト: r8 <= mem[r1 - 1]
        u_ram.memory[28] = encode_ls(3'b000, 4'd8, 4'd1, 9'd1, 2'b01);

        // リセット解除
        #20;
        rst = 0;

        // プログラム実行
        // ノイマン型化により、Load/Store命令1つにつき単一バスの
        // 調停で1サイクルのストールが追加されるため、
        // ハーバード型時代(45サイクル)より余裕を持たせて待機する。
        #650;

        $display("=== k16 CPU 検証結果 ===");

        // 検証1: r1 = 11 (分岐先でインクリメントされた)
        if (u_cpu.u_regfile.regs[1] === 16'd11) begin
            $display("[PASS] r1 = %d (期待値: 11)", u_cpu.u_regfile.regs[1]);
        end else begin
            $display("[FAIL] r1 = %d (期待値: 11)", u_cpu.u_regfile.regs[1]);
            errors = errors + 1;
        end

        // 検証2: r2 = ~11 (NAND)
        if (u_cpu.u_regfile.regs[2] === 16'hFFF4) begin
            $display("[PASS] r2 = 0x%04X (期待値: 0xFFF4)", u_cpu.u_regfile.regs[2]);
        end else begin
            $display("[FAIL] r2 = 0x%04X (期待値: 0xFFF4)", u_cpu.u_regfile.regs[2]);
            errors = errors + 1;
        end

        // 検証3: r3 = 15 (ADD)
        if (u_cpu.u_regfile.regs[3] === 16'd15) begin
            $display("[PASS] r3 = %d (期待値: 15)", u_cpu.u_regfile.regs[3]);
        end else begin
            $display("[FAIL] r3 = %d (期待値: 15)", u_cpu.u_regfile.regs[3]);
            errors = errors + 1;
        end

        // 検証4: r4 = -50 (SUB 0-50 -> 0xFFCE, N=1)
        if (u_cpu.u_regfile.regs[4] === 16'hFFCE) begin
            $display("[PASS] r4 = 0x%04X (期待値: 0xFFCE)", u_cpu.u_regfile.regs[4]);
        end else begin
            $display("[FAIL] r4 = 0x%04X (期待値: 0xFFCE)", u_cpu.u_regfile.regs[4]);
            errors = errors + 1;
        end

        // 検証5: r5 = 123 (N==1成立で実行)
        if (u_cpu.u_regfile.regs[5] === 16'd123) begin
            $display("[PASS] r5 = %d (期待値: 123)", u_cpu.u_regfile.regs[5]);
        end else begin
            $display("[FAIL] r5 = %d (期待値: 123)", u_cpu.u_regfile.regs[5]);
            errors = errors + 1;
        end

        // 検証6: r6 = 15 (N==0不成立でスキップ、15のまま維持)
        if (u_cpu.u_regfile.regs[6] === 16'd15) begin
            $display("[PASS] r6 = %d (期待値: 15)", u_cpu.u_regfile.regs[6]);
        end else begin
            $display("[FAIL] r6 = %d (期待値: 15)", u_cpu.u_regfile.regs[6]);
            errors = errors + 1;
        end

        // 検証7: r8 = 99 (減算Load)
        if (u_cpu.u_regfile.regs[8] === 16'd99) begin
            $display("[PASS] r8 = %d (期待値: 99)", u_cpu.u_regfile.regs[8]);
        end else begin
            $display("[FAIL] r8 = %d (期待値: 99)", u_cpu.u_regfile.regs[8]);
            errors = errors + 1;
        end

        // 検証8: r10 = 77 (Z==1成立で実行)
        if (u_cpu.u_regfile.regs[10] === 16'd77) begin
            $display("[PASS] r10 = %d (期待値: 77)", u_cpu.u_regfile.regs[10]);
        end else begin
            $display("[FAIL] r10 = %d (期待値: 77)", u_cpu.u_regfile.regs[10]);
            errors = errors + 1;
        end

        // 検証9: r11 = 0 (Z==0不成立でスキップ)
        if (u_cpu.u_regfile.regs[11] === 16'd0) begin
            $display("[PASS] r11 = %d (期待値: 0)", u_cpu.u_regfile.regs[11]);
        end else begin
            $display("[FAIL] r11 = %d (期待値: 0)", u_cpu.u_regfile.regs[11]);
            errors = errors + 1;
        end

        // 検証10: r12 = 15 (Load結果。分岐スキップされた命令99で上書きされていないこと)
        if (u_cpu.u_regfile.regs[12] === 16'd15) begin
            $display("[PASS] r12 = %d (期待値: 15, Load & 分岐フラッシュ成功)", u_cpu.u_regfile.regs[12]);
        end else begin
            $display("[FAIL] r12 = %d (期待値: 15)", u_cpu.u_regfile.regs[12]);
            errors = errors + 1;
        end

        // 検証11: メモリ書き込み値 (Store結果: mem[12] == 24'h5A000F)
        if (u_ram.memory[12] === 24'h5A000F) begin
            $display("[PASS] mem[12] = 0x%06X (期待値: 0x5A000F)", u_ram.memory[12]);
        end else begin
            $display("[FAIL] mem[12] = 0x%06X (期待値: 0x5A000F)", u_ram.memory[12]);
            errors = errors + 1;
        end

        // 検証12: 減算Store値 (mem[10] == 24'h770063)
        if (u_ram.memory[10] === 24'h770063) begin
            $display("[PASS] mem[10] = 0x%06X (期待値: 0x770063)", u_ram.memory[10]);
        end else begin
            $display("[FAIL] mem[10] = 0x%06X (期待値: 0x770063)", u_ram.memory[10]);
            errors = errors + 1;
        end

        // 検証13: r13上位バイト (減算Load時に8'h77がロードされていること)
        if (u_cpu.u_regfile.regs[13][7:0] === 8'h77) begin
            $display("[PASS] r13[7:0] = 0x%02X (期待値: 0x77)", u_cpu.u_regfile.regs[13][7:0]);
        end else begin
            $display("[FAIL] r13[7:0] = 0x%02X (期待値: 0x77)", u_cpu.u_regfile.regs[13][7:0]);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("\n>>> 全てのテストに合格しました！ (ALL TESTS PASSED) <<<");
        end else begin
            $display("\n>>> %0d 件のエラーが発生しました。 <<<", errors);
        end

        $finish;
    end

endmodule
