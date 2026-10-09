`timescale 1ns / 1ps

//==============================================================================
// k16 LED Blink Testbench
//
// firmware.hex をロードして LED チカチカ動作を検証
// シミュレーション用に遅延ループを短縮したファームウェアを使用
//==============================================================================

module tb_blink;

    reg clk;
    reg rst;

    wire        mem_data_req;
    wire [15:0] mem_addr;
    wire [23:0] mem_wdata;
    wire        mem_we;
    wire [23:0] mem_rdata;
    wire        mem_ready;

    wire        mmio_req;
    wire [7:0]  mmio_addr;
    wire [23:0] mmio_wdata;
    wire        mmio_we;
    wire [23:0] mmio_rdata;
    wire        mmio_ready;

    cpu u_cpu(
        .clk(clk), .rst(rst),
        .mem_data_req(mem_data_req), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_we(mem_we),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    memory_subsystem #(.RAM_ADDR_WIDTH(14)) u_memsub(
        .clk(clk), .rst(rst),
        .mem_data_req(mem_data_req), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_we(mem_we),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .mmio_req(mmio_req), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_we(mmio_we),
        .mmio_rdata(mmio_rdata), .mmio_ready(mmio_ready)
    );

    // Minimal MMIO stub: LED only
    reg [15:0] led_reg;
    reg [23:0] mmio_rdata_reg;
    assign mmio_rdata = mmio_rdata_reg;
    assign mmio_ready = 1'b1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            led_reg <= 16'b0;
            mmio_rdata_reg <= 24'b0;
        end else begin
            if (mmio_req && mmio_we) begin
                case (mmio_addr)
                    8'h10: led_reg <= mmio_wdata[15:0];
                endcase
            end
            if (mmio_req && !mmio_we) begin
                case (mmio_addr)
                    8'h10: mmio_rdata_reg <= {8'b0, led_reg};
                    default: mmio_rdata_reg <= 24'b0;
                endcase
            end
        end
    end

    always #5 clk = ~clk;

    integer errors = 0;
    integer toggle_count = 0;
    reg [15:0] prev_led;

    initial begin
        $dumpfile("tb_blink.vcd");
        $dumpvars(0, tb_blink);

        clk = 0;
        rst = 1;

        // firmware.hex is auto-loaded by ram.v via $readmemh
        #20;
        rst = 0;

        prev_led = 16'b0;

        // Run for enough cycles to see LED toggles
        // Real program has 256*65536 = 16M iterations, too long for sim
        // So we just check that LED changes at least once in 10000 cycles
        #(10000 * 10);

        $display("=== LED Blink Test ===");
        $display("LED final value: 0x%04h", led_reg);
        $display("LED toggled %0d times (estimated)", toggle_count);

        if (toggle_count > 0) begin
            $display("[PASS] LED is toggling");
        end else begin
            $display("[FAIL] LED never toggled");
            errors = errors + 1;
        end

        $display("Errors: %0d", errors);
        $finish;
    end

    // Count LED toggles
    always @(posedge clk) begin
        if (!rst) begin
            if (led_reg != prev_led) begin
                toggle_count = toggle_count + 1;
                $display("[%0t] LED changed: 0x%04h → 0x%04h", $time, prev_led, led_reg);
                prev_led <= led_reg;
            end
        end
    end

endmodule
