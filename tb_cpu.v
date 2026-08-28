`timescale 1ns / 1ps

module tb_cpu;

    reg clk;
    reg rst;
    reg uart_rx;
    wire uart_tx;

    // パラメータ: シミュレーション高速化のため 1bit = 10クロック
    localparam CLKS_PER_BIT = 10;

    // SoC インスタンス (CPU + RAM + MMIO/UART)
    // INIT_FILE="firmware.hex" が存在する場合、$readmemh で自動ロード
    // 空文字列を指定した場合は manual 初期化ブロック (後段) のみが有効
    k16_soc #(
        .CLKS_PER_BIT (CLKS_PER_BIT),
        .INIT_FILE    ("firmware.hex")  // firmware.hex から自動ロード
    ) u_soc (
        .clk     (clk),
        .rst     (rst),
        .uart_rx (uart_rx),
        .uart_tx (uart_tx)
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

    // 外部からUART RXピンに1バイト送信するタスク (8-N-1)
    task send_uart_byte(input [7:0] data);
        integer i;
        begin
            // スタートビット (Low)
            uart_rx = 1'b0;
            #(CLKS_PER_BIT * 10);

            // データビット (LSBファースト)
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = data[i];
                #(CLKS_PER_BIT * 10);
            end

            // ストップビット (High)
            uart_rx = 1'b1;
            #(CLKS_PER_BIT * 10);
        end
    endtask

    initial begin
        // 波形ダンプ
        $dumpfile("tb_cpu.vcd");
        $dumpvars(0, tb_cpu);

        clk = 0;
        rst = 1;
        uart_rx = 1;

        // メモリ初期化 (全ゼロ / NOP)
        for (integer i = 0; i < 65536; i = i + 1) begin
            u_soc.u_ram.memory[i] = 24'b100_00_0000_0000_0000_0000_000; // NOP
        end

        //======================================================
        // テストプログラム配置
        //======================================================
        // 0: r1 = r0 + 10 (ADDI r1, r0, 10)
        u_soc.u_ram.memory[0]  = encode_i(3'b000, 4'd1, 4'd0, 8'd10, 3'b100);
        // 1: r2 = r0 + 5  (ADDI r2, r0, 5)
        u_soc.u_ram.memory[1]  = encode_i(3'b000, 4'd2, 4'd0, 8'd5,  3'b100);
        // 2: r3 = r1 + r2 (ADD r3, r1, r2) -> 15
        u_soc.u_ram.memory[2]  = encode_r(3'b000, 4'd3, 4'd1, 4'd2,  3'b100);
        // 3: r4 = r1 - r2 (SUB r4, r1, r2) -> 5
        u_soc.u_ram.memory[3]  = encode_r(3'b000, 4'd4, 4'd1, 4'd2,  3'b101);
        // 4: r5 = r1 & r2 (AND r5, r1, r2) -> 0
        u_soc.u_ram.memory[4]  = encode_r(3'b000, 4'd5, 4'd1, 4'd2,  3'b010);
        // 5: r6 = r1 | r2 (OR  r6, r1, r2) -> 15
        u_soc.u_ram.memory[5]  = encode_r(3'b000, 4'd6, 4'd1, 4'd2,  3'b001);
        // 6: r7 = r1 ^ r2 (XOR r7, r1, r2) -> 15
        u_soc.u_ram.memory[6]  = encode_r(3'b000, 4'd7, 4'd1, 4'd2,  3'b011);
        // 7: r8 = r1 >> 1 (SHR r8, r1)     -> 5
        u_soc.u_ram.memory[7]  = encode_r(3'b000, 4'd8, 4'd1, 4'd0,  3'b111);
        // 8: r9 = r1 - r1 (SUB r9, r1, r1) -> 0, Z=1
        u_soc.u_ram.memory[8]  = encode_r(3'b000, 4'd9, 4'd1, 4'd1,  3'b101);
        // 9: 条件付き実行: if (Z==0) r11 = r0 + 88 (不成立 -> スキップ)
        u_soc.u_ram.memory[9]  = encode_i(3'b001, 4'd11, 4'd0, 8'd88, 3'b100);
        // 10: 条件付き実行: if (Z==1) r10 = r0 + 77 (成立 -> 実行)
        u_soc.u_ram.memory[10] = encode_i(3'b101, 4'd10, 4'd0, 8'd77, 3'b100);
        // 11: r13の上位バイト設定用: r13 = r0 + 16'h5A
        u_soc.u_ram.memory[11] = encode_i(3'b000, 4'd13, 4'd0, 8'h5A, 3'b100);
        // 12: Store: mem[r1 + 2] <= {r13[7:0], r3} = {8'h5A, 16'd15}
        u_soc.u_ram.memory[12] = encode_ls(3'b000, 4'd3, 4'd1, 9'd2, 2'b10);
        // 13: Load: r12 <= mem[r1 + 2] (r12に15, r13[7:0]に8'h5Aが入る)
        u_soc.u_ram.memory[13] = encode_ls(3'b000, 4'd12, 4'd1, 9'd2, 2'b00);

        // 14: 【PC(r15)書き込み・ジャンプテスト】: r15 = r0 + 20 (アドレス20へ分岐)
        u_soc.u_ram.memory[14] = encode_i(3'b000, 4'd15, 4'd0, 8'd20, 3'b100);
        // 15: 【分岐フラッシュ検証】スキップされるはずの命令: r12 = r0 + 99
        u_soc.u_ram.memory[15] = encode_i(3'b000, 4'd12, 4'd0, 8'd99, 3'b100);

        // 20: 分岐先命令: r1 = r1 + 1 (10 + 1 = 11)
        u_soc.u_ram.memory[20] = encode_i(3'b000, 4'd1, 4'd1, 8'd1, 3'b100);
        // 21: NANDテスト: r2 = ~(r1 & r1) -> ~11
        u_soc.u_ram.memory[21] = encode_r(3'b000, 4'd2, 4'd1, 4'd1, 3'b000);
        // 22: 負数・Nフラグテスト: r4 = 0 - 50 (SUB r4, r0, 50) -> -50, N=1
        u_soc.u_ram.memory[22] = encode_i(3'b000, 4'd4, 4'd0, 8'd50, 3'b101);
        // 23: N==0条件テスト (不成立 -> スキップ): if (N==0) r6 = r0 + 200
        u_soc.u_ram.memory[23] = encode_i(3'b011, 4'd6, 4'd0, 8'd200, 3'b100);
        // 24: N==1条件テスト (成立 -> 実行): if (N==1) r5 = r0 + 123
        u_soc.u_ram.memory[24] = encode_i(3'b111, 4'd5, 4'd0, 8'd123, 3'b100);
        // 25: 減算オフセットStoreテスト: mem[r1 - 1] (アドレス10) <= {8'h77, 16'd99}
        u_soc.u_ram.memory[25] = encode_i(3'b000, 4'd13, 4'd0, 8'h77, 3'b100);
        u_soc.u_ram.memory[26] = encode_i(3'b000, 4'd7,  4'd0, 8'd99,  3'b100);
        u_soc.u_ram.memory[27] = encode_ls(3'b000, 4'd7, 4'd1, 9'd1, 2'b11);
        // 28: 減算オフセットLoadテスト: r8 <= mem[r1 - 1]
        u_soc.u_ram.memory[28] = encode_ls(3'b000, 4'd8, 4'd1, 9'd1, 2'b01);
        // 29: r13上位バイト退避: r3 <= r13 + 0 (0x77)
        u_soc.u_ram.memory[29] = encode_r(3'b000, 4'd3, 4'd13, 4'd0, 3'b100);

        // 30〜: MMIO UART IO テスト
        // 30: r9 = ~0 = 0xFFFF
        u_soc.u_ram.memory[30] = encode_r(3'b000, 4'd9, 4'd0, 4'd0, 3'b000);
        // 31: r9 = 0xFFFF - 255 = 0xFF00 (MMIO UARTベースアドレス)
        u_soc.u_ram.memory[31] = encode_i(3'b000, 4'd9, 4'd9, 8'd255, 3'b101);
        // 32: UARTステータス確認 (0xFF01): r11 <= mem[r9 + 1] -> 初期値 0
        u_soc.u_ram.memory[32] = encode_ls(3'b000, 4'd11, 4'd9, 9'd1, 2'b00);
        // 33: UART送信データ設定: r7 = 0x4B ('K')
        u_soc.u_ram.memory[33] = encode_i(3'b000, 4'd7, 4'd0, 8'h4B, 3'b100);
        // 34: UART送信実行: mem[r9 + 0] <= r7 (Store to 0xFF00)
        u_soc.u_ram.memory[34] = encode_ls(3'b000, 4'd7, 4'd9, 9'd0, 2'b10);
        // 35: UART送信中ステータス確認: r10 <= mem[r9 + 1] -> tx_busy=1
        u_soc.u_ram.memory[35] = encode_ls(3'b000, 4'd10, 4'd9, 9'd1, 2'b00);
        // 36: UART受信ステータス確認: r12 <= mem[r9 + 1]
        u_soc.u_ram.memory[36] = encode_ls(3'b000, 4'd12, 4'd9, 9'd1, 2'b00);
        // 37: UART受信データ読み出し: r6 <= mem[r9 + 0]
        u_soc.u_ram.memory[37] = encode_ls(3'b000, 4'd6, 4'd9, 9'd0, 2'b00);

        // 38〜: 特殊レジスタ検証 (r0, r14, r15)
        // 38: r0への書き込み (ADDI r0, r0, 55) -> 無視されるべき
        u_soc.u_ram.memory[38] = encode_i(3'b000, 4'd0, 4'd0, 8'd55, 3'b100);
        // 39: 直後にr0読み出し (ADD r2, r0, 0) -> フォワーディングされず0であること
        u_soc.u_ram.memory[39] = encode_r(3'b000, 4'd2, 4'd0, 4'd0, 3'b100);
        // 40: r14(フラグ)直読み (ADD r11, r14, 0) -> 直前が結果0なので Z=1 -> 1
        u_soc.u_ram.memory[40] = encode_r(3'b000, 4'd11, 4'd14, 4'd0, 3'b100);
        // 41: r14への強制書き込み (ADDI r14, r0, 255) -> 書き込み無視
        u_soc.u_ram.memory[41] = encode_i(3'b000, 4'd14, 4'd0, 8'd255, 3'b100);
        // 42: 直後にr14読み出し (ADD r5, r14, 0) -> 255でなく更新後フラグ値0が読める
        u_soc.u_ram.memory[42] = encode_r(3'b000, 4'd5, 4'd14, 4'd0, 3'b100);
        // 43: r15(PC)読み出し (ADD r8, r15, 0) -> 現在のフェッチPC (44)
        u_soc.u_ram.memory[43] = encode_r(3'b000, 4'd8, 4'd15, 4'd0, 3'b100);

        // リセット解除
        #20;
        rst = 0;

        // サイクル進行および外部UART送信
        #380;
        // 外部から 0x5A ('Z') をUART RXに入力
        send_uart_byte(8'h5A);

        #500;

        $display("=== k16 CPU 検証結果 (ノイマン型 + MMIO + 特殊レジスタ完全検証) ===");

        // 検証1: r1 = 11 (分岐先でインクリメントされた)
        if (u_soc.u_cpu.u_regfile.regs[1] === 16'd11) begin
            $display("[PASS] r1 = %d (期待値: 11)", u_soc.u_cpu.u_regfile.regs[1]);
        end else begin
            $display("[FAIL] r1 = %d (期待値: 11)", u_soc.u_cpu.u_regfile.regs[1]);
            errors = errors + 1;
        end

        // 検証2: r4 = -50 (SUB 0-50 -> 0xFFCE, N=1)
        if (u_soc.u_cpu.u_regfile.regs[4] === 16'hFFCE) begin
            $display("[PASS] r4 = 0x%04X (期待値: 0xFFCE)", u_soc.u_cpu.u_regfile.regs[4]);
        end else begin
            $display("[FAIL] r4 = 0x%04X (期待値: 0xFFCE)", u_soc.u_cpu.u_regfile.regs[4]);
            errors = errors + 1;
        end

        // 検証3: メモリ書き込み値 (Store結果: mem[12] == 24'h5A000F)
        if (u_soc.u_ram.memory[12] === 24'h5A000F) begin
            $display("[PASS] mem[12] = 0x%06X (期待値: 0x5A000F)", u_soc.u_ram.memory[12]);
        end else begin
            $display("[FAIL] mem[12] = 0x%06X (期待値: 0x5A000F)", u_soc.u_ram.memory[12]);
            errors = errors + 1;
        end

        // 検証4: 減算Store値 (mem[10] == 24'h770063)
        if (u_soc.u_ram.memory[10] === 24'h770063) begin
            $display("[PASS] mem[10] = 0x%06X (期待値: 0x770063)", u_soc.u_ram.memory[10]);
        end else begin
            $display("[FAIL] mem[10] = 0x%06X (期待値: 0x770063)", u_soc.u_ram.memory[10]);
            errors = errors + 1;
        end

        // 検証5: r3 (減算Load時上位8bit退避値 -> 8'h77)
        if (u_soc.u_cpu.u_regfile.regs[3][7:0] === 8'h77) begin
            $display("[PASS] r3[7:0] = 0x%02X (期待値: 0x77)", u_soc.u_cpu.u_regfile.regs[3][7:0]);
        end else begin
            $display("[FAIL] r3[7:0] = 0x%02X (期待値: 0x77)", u_soc.u_cpu.u_regfile.regs[3][7:0]);
            errors = errors + 1;
        end

        // 検証6: UART送信中ステータス (tx_busy=1)
        if (u_soc.u_cpu.u_regfile.regs[10][0] === 1'b1) begin
            $display("[PASS] UART送信中ステータス r10[0] = 1 (tx_busy=1)");
        end else begin
            $display("[FAIL] UART送信中ステータス r10[0] = 0 (期待値: 1)");
            errors = errors + 1;
        end

        // 検証7: UART受信データ (r6 == 8'h5A)
        if (u_soc.u_cpu.u_regfile.regs[6][7:0] === 8'h5A) begin
            $display("[PASS] UART受信データ r6 = 0x%02X (期待値: 0x5A 'Z')", u_soc.u_cpu.u_regfile.regs[6][7:0]);
        end else begin
            $display("[FAIL] UART受信データ r6 = 0x%02X (期待値: 0x5A 'Z')", u_soc.u_cpu.u_regfile.regs[6][7:0]);
            errors = errors + 1;
        end

        // 検証8: 特殊レジスタ r0 (書き込み無視 & バイパス防止)
        if (u_soc.u_cpu.u_regfile.regs[2] === 16'd0 && u_soc.u_cpu.u_regfile.regs[0] === 16'd0) begin
            $display("[PASS] 特殊レジスタ r0 (書き込み無視 & 常に0)");
        end else begin
            $display("[FAIL] 特殊レジスタ r0 (書き込み無視)");
            errors = errors + 1;
        end

        // 検証9: 特殊レジスタ r14 (フラグ直読み)
        if (u_soc.u_cpu.u_regfile.regs[11] === 16'd1) begin
            $display("[PASS] 特殊レジスタ r14 (フラグ直読み Z=1 -> 1)");
        end else begin
            $display("[FAIL] 特殊レジスタ r14 (フラグ直読み)");
            errors = errors + 1;
        end

        // 検証10: 特殊レジスタ r14 (書き込み無視)
        if (u_soc.u_cpu.u_regfile.regs[5] === 16'd0) begin
            $display("[PASS] 特殊レジスタ r14 (書き込み無視 255不格納)");
        end else begin
            $display("[FAIL] 特殊レジスタ r14 (書き込み無視)");
            errors = errors + 1;
        end

        // 検証11: 特殊レジスタ r15 (PC値読み出し)
        if (u_soc.u_cpu.u_regfile.regs[8] === 16'd44) begin
            $display("[PASS] 特殊レジスタ r15 (PC読み出し -> 44)");
        end else begin
            $display("[FAIL] 特殊レジスタ r15 (PC読み出し)");
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
