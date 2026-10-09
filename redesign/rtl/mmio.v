//==============================================================================
// k16 MMIO Module — LED / Button / GPIO / Timer / UART
//
// 概要:
//   memory_subsystem.v から渡される mmio_req/mmio_addr/mmio_wdata/mmio_we に
//   応答する。各ペリフェラルはアドレス下位8bitで識別。
//
// アドレスマップ (mmio_addr = mem_addr[7:0]):
//   0x00: UART_TX  (W) 8bit
//   0x01: UART_RX  (R) 8bit
//   0x02: UART_STATUS (R) {22'b0, TX_READY, RX_READY}
//   0x03: UART_BAUD (R/W) 16bit
//   0x10: LED (R/W) 16bit
//   0x20: BTN (R) {28'b0, BTN2, BTN1, BTN0}
//   0x30: TIMER_CTRL (W) 1bit
//   0x31: TIMER_CNT (R) 16bit
//   0x32: TIMER_CMP (R/W) 16bit
//   0x40: GPIO_OUT (R/W) 16bit
//   0x41: GPIO_IN (R) 16bit
//   0x42: GPIO_DIR (R/W) 16bit
//
// すべてのレジスタは同期Read (1サイクル遅延)。
// メモリサブシステム経由でCPUに接続される。
//==============================================================================

module mmio (
    input  wire        clk,
    input  wire        rst,

    // Memory subsystem interface
    input  wire        mmio_req,
    input  wire [7:0]  mmio_addr,
    input  wire [23:0] mmio_wdata,
    input  wire        mmio_we,
    output reg  [23:0] mmio_rdata,
    output wire        mmio_ready,

    // ===== External I/O =====
    // LED
    output wire [15:0] led,
    // Buttons (debounced)
    input  wire [2:0]  btn,
    // GPIO
    inout  wire [15:0] gpio,
    // Timer
    output wire        timer_irq,
    // UART
    input  wire        uart_rx,
    output wire        uart_tx
);

    //==========================================================================
    // Register declarations
    //==========================================================================
    reg [15:0] led_reg;
    reg [15:0] gpio_out_reg;
    reg [15:0] gpio_dir_reg;
    reg [15:0] timer_cmp_reg;
    reg [15:0] timer_cnt_reg;
    reg        timer_en_reg;
    reg [15:0] uart_baud_reg;

    // UART internal
    reg        uart_tx_busy;
    reg [7:0]  uart_tx_shift;
    reg [3:0]  uart_tx_bit_cnt;
    reg [15:0] uart_tx_div_cnt;

    reg [7:0]  uart_rx_buf;
    reg        uart_rx_valid;
    reg [7:0]  uart_rx_shift;
    reg [3:0]  uart_rx_bit_cnt;
    reg [15:0] uart_rx_div_cnt;
    reg        uart_rx_prev;

    // Button synchronizer + debounce
    reg [2:0]  btn_sync1;
    reg [2:0]  btn_sync2;
    reg [2:0]  btn_prev;
    reg [19:0] btn_deb_cnt;

    //==========================================================================
    // LED output
    //==========================================================================
    assign led = led_reg;

    //==========================================================================
    // GPIO (bidirectional)
    //==========================================================================
    // gpio_dir: 0=input, 1=output
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gpio_gen
            assign gpio[i] = gpio_dir_reg[i] ? gpio_out_reg[i] : 1'bz;
        end
    endgenerate

    wire [15:0] gpio_in = gpio;

    //==========================================================================
    // Button synchronizer + debounce (10ms @ 27MHz ≈ 270000 cycles)
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            btn_sync1 <= 3'b0;
            btn_sync2 <= 3'b0;
            btn_prev  <= 3'b0;
            btn_deb_cnt <= 20'b0;
        end else begin
            btn_sync1 <= btn;
            btn_sync2 <= btn_sync1;
            // Simple debounce: counter resets on change, stable for 270k cycles
            if (btn_sync2 != btn_prev) begin
                btn_deb_cnt <= 20'b0;
                btn_prev <= btn_sync2;
            end else if (btn_deb_cnt < 20'd270000) begin
                btn_deb_cnt <= btn_deb_cnt + 20'd1;
            end
        end
    end

    wire [2:0] btn_debounced = (btn_deb_cnt >= 20'd270000) ? btn_prev : 3'b0;

    //==========================================================================
    // Timer
    //==========================================================================
    wire timer_match = (timer_cnt_reg == timer_cmp_reg);
    assign timer_irq = timer_en_reg && timer_match;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            timer_cnt_reg <= 16'b0;
            timer_cmp_reg <= 16'hFFFF;
            timer_en_reg  <= 1'b0;
        end else begin
            // Write from CPU
            if (mmio_req && mmio_we) begin
                case (mmio_addr)
                    8'h30: timer_en_reg  <= mmio_wdata[0];
                    8'h32: timer_cmp_reg <= mmio_wdata[15:0];
                endcase
            end

            // Timer count
            if (!timer_en_reg) begin
                timer_cnt_reg <= 16'b0;
            end else if (timer_match) begin
                timer_cnt_reg <= 16'b0;
            end else begin
                timer_cnt_reg <= timer_cnt_reg + 16'd1;
            end
        end
    end

    //==========================================================================
    // UART TX (basic, polling-based)
    //==========================================================================
    // Format: 8N1, LSB first
    // Baud divider = uart_baud_reg (clk_freq / baud_rate - 1)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            uart_tx_busy    <= 1'b0;
            uart_tx_shift   <= 8'b0;
            uart_tx_bit_cnt <= 4'b0;
            uart_tx_div_cnt <= 16'b0;
            uart_baud_reg   <= 16'd233;  // 27MHz/115200 - 1
            uart_tx         <= 1'b1;     // idle high
        end else begin
            // Baud register write
            if (mmio_req && mmio_we && (mmio_addr == 8'h03))
                uart_baud_reg <= mmio_wdata[15:0];

            if (uart_tx_busy) begin
                if (uart_tx_div_cnt == 16'b0) begin
                    uart_tx_div_cnt <= uart_baud_reg;
                    if (uart_tx_bit_cnt == 4'd10) begin
                        // Done
                        uart_tx_busy <= 1'b0;
                        uart_tx      <= 1'b1;  // return to idle
                    end else begin
                        case (uart_tx_bit_cnt)
                            4'd0: uart_tx <= 1'b0;           // start bit
                            4'd1, 4'd2, 4'd3, 4'd4,
                            4'd5, 4'd6, 4'd7, 4'd8: begin
                                uart_tx <= uart_tx_shift[0];
                                uart_tx_shift <= {1'b0, uart_tx_shift[7:1]};
                            end
                            4'd9: uart_tx <= 1'b1;           // stop bit
                        endcase
                        uart_tx_bit_cnt <= uart_tx_bit_cnt + 4'd1;
                    end
                end else begin
                    uart_tx_div_cnt <= uart_tx_div_cnt - 16'd1;
                end
            end else begin
                // Check for new TX request
                if (mmio_req && mmio_we && (mmio_addr == 8'h00)) begin
                    uart_tx_shift   <= mmio_wdata[7:0];
                    uart_tx_bit_cnt <= 4'd0;
                    uart_tx_div_cnt <= 16'b0;
                    uart_tx_busy    <= 1'b1;
                end
            end
        end
    end

    //==========================================================================
    // UART RX (basic)
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            uart_rx_valid  <= 1'b0;
            uart_rx_buf    <= 8'b0;
            uart_rx_shift  <= 8'b0;
            uart_rx_bit_cnt<= 4'b0;
            uart_rx_div_cnt<= 16'b0;
            uart_rx_prev   <= 1'b1;
        end else begin
            // Read clears RX_READY
            if (mmio_req && !mmio_we && (mmio_addr == 8'h01))
                uart_rx_valid <= 1'b0;

            if (uart_rx_bit_cnt == 4'd0) begin
                // Idle: wait for start bit (falling edge)
                if (uart_rx_prev && !uart_rx) begin
                    uart_rx_bit_cnt <= 4'd1;
                    uart_rx_div_cnt <= uart_baud_reg >> 1;  // half bit for center sampling
                end
            end else begin
                if (uart_rx_div_cnt == 16'b0) begin
                    uart_rx_div_cnt <= uart_baud_reg;
                    if (uart_rx_bit_cnt >= 4'd1 && uart_rx_bit_cnt <= 4'd8) begin
                        uart_rx_shift <= {uart_rx, uart_rx_shift[7:1]};
                    end
                    if (uart_rx_bit_cnt == 4'd9) begin
                        // Stop bit
                        uart_rx_buf    <= uart_rx_shift;
                        uart_rx_valid  <= 1'b1;
                        uart_rx_bit_cnt<= 4'd0;
                    end else begin
                        uart_rx_bit_cnt <= uart_rx_bit_cnt + 4'd1;
                    end
                end else begin
                    uart_rx_div_cnt <= uart_rx_div_cnt - 16'd1;
                end
            end
            uart_rx_prev <= uart_rx;
        end
    end

    //==========================================================================
    // LED and GPIO registers
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            led_reg      <= 16'b0;
            gpio_out_reg <= 16'b0;
            gpio_dir_reg <= 16'b0;
        end else if (mmio_req && mmio_we) begin
            case (mmio_addr)
                8'h10: led_reg      <= mmio_wdata[15:0];
                8'h40: gpio_out_reg <= mmio_wdata[15:0];
                8'h42: gpio_dir_reg <= mmio_wdata[15:0];
            endcase
        end
    end

    //==========================================================================
    // Read mux (synchronous, 1-cycle latency)
    //==========================================================================
    always @(posedge clk) begin
        if (mmio_req && !mmio_we) begin
            case (mmio_addr)
                8'h01: mmio_rdata <= {16'b0, uart_rx_buf};
                8'h02: mmio_rdata <= {22'b0, ~uart_tx_busy, uart_rx_valid};
                8'h03: mmio_rdata <= {8'b0, uart_baud_reg};
                8'h10: mmio_rdata <= {8'b0, led_reg};
                8'h20: mmio_rdata <= {29'b0, btn_debounced};
                8'h31: mmio_rdata <= {8'b0, timer_cnt_reg};
                8'h32: mmio_rdata <= {8'b0, timer_cmp_reg};
                8'h40: mmio_rdata <= {8'b0, gpio_out_reg};
                8'h41: mmio_rdata <= {8'b0, gpio_in};
                8'h42: mmio_rdata <= {8'b0, gpio_dir_reg};
                default: mmio_rdata <= 24'b0;
            endcase
        end else begin
            mmio_rdata <= mmio_rdata;  // hold
        end
    end

    assign mmio_ready = 1'b1;  // All MMIO registers respond in 1 cycle

endmodule
