`timescale 1ns/1ps

module tb_uart;
    localparam integer CLKS_PER_BIT = 234;
    localparam integer BIT_NS = CLKS_PER_BIT * 10;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg uart_rx = 1;
    wire uart_tx;
    wire [7:0] led;

    k16_soc #(
        .CLKS_PER_BIT (CLKS_PER_BIT),
        .INIT_FILE    ("firmware.hex")
    ) dut (
        .clk     (clk),
        .rst     (rst),
        .uart_rx (uart_rx),
        .uart_tx (uart_tx),
        .led     (led)
    );

    // ---- TX monitor ----
    integer i;
    reg [7:0] rxb;
    initial begin
        forever begin
            @(negedge uart_tx);
            #(BIT_NS/2);
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                rxb[i] = uart_tx;
            end
            #(BIT_NS);
            $write("%c", rxb);
            $fflush();
        end
    end

    // ---- RX driver ----
    task send_byte(input [7:0] d);
        integer k;
        begin
            uart_rx = 1'b0;
            #(BIT_NS);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = d[k];
                #(BIT_NS);
            end
            uart_rx = 1'b1;
            #(BIT_NS);
        end
    endtask

    task gap(input integer bits);
        begin
            #(BIT_NS * bits);
        end
    endtask

    integer mode;
    initial begin
        #1000 rst = 0;
        if (!$value$plusargs("MODE=%d", mode)) mode = 0;
        // 0 = realistic typing (2 idle bit), 1 = paste (0 gap), 2 = start immediately
        case (mode)
          0: begin #(BIT_NS*150); $display("\n[TB] mode 0: realistic, after prompt"); end
          1: begin #(BIT_NS*150); $display("\n[TB] mode 1: paste, after prompt"); end
          default: begin #(BIT_NS*20); $display("\n[TB] mode 2: during prompt"); end
        endcase
        send_byte("("); gap(mode == 1 ? 0 : 2);
        send_byte("5"); gap(mode == 1 ? 0 : 2);
        send_byte(","); gap(mode == 1 ? 0 : 2);
        send_byte("4"); gap(mode == 1 ? 0 : 2);
        send_byte(","); gap(mode == 1 ? 0 : 2);
        send_byte("3"); gap(mode == 1 ? 0 : 2);
        send_byte(","); gap(mode == 1 ? 0 : 2);
        send_byte("2"); gap(mode == 1 ? 0 : 2);
        send_byte(","); gap(mode == 1 ? 0 : 2);
        send_byte("1"); gap(mode == 1 ? 0 : 2);
        send_byte(")"); gap(mode == 1 ? 0 : 2);

        // wait for result
        #(BIT_NS * 4000);
        $display("\n[TB] done. PC=%04x r8=%04x r9=%04x r12=%04x r15=%04x",
                 dut.u_cpu.u_regfile.regs[15], dut.u_cpu.u_regfile.regs[8],
                 dut.u_cpu.u_regfile.regs[9], dut.u_cpu.u_regfile.regs[12],
                 dut.u_cpu.u_regfile.regs[15]);
        $finish;
    end
endmodule
