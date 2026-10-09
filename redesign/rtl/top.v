//==============================================================================
// k16 Top Module for Tang Nano 9K
//
// 構成:
//   clk_27mhz → PLL (optional) → cpu_clk
//   cpu ↔ memory_subsystem ↔ ram + mmio
//   mmio → LED / BTN / UART
//
// ピンアサインは Tang Nano 9K を想定。
//==============================================================================

module top (
    input  wire        clk_27mhz,    // 27MHz オンボードクロック
    input  wire        rst_btn,      // リセットボタン (active low)
    output wire [5:0]  led,          // オンボードLED (6個)
    input  wire [1:0]  btn,          // ユーザボタン
    inout  wire [15:0] gpio,         // GPIO ヘッダ
    input  wire        uart_rx,      // UART RX
    output wire        uart_tx       // UART TX
);

    //==========================================================================
    // Clock (use 27MHz directly for now, PLL can be added later)
    //==========================================================================
    wire clk = clk_27mhz;
    wire rst = ~rst_btn;  // active high

    //==========================================================================
    // CPU ↔ Memory Subsystem
    //==========================================================================
    wire        mem_data_req;
    wire [15:0] mem_addr;
    wire [23:0] mem_wdata;
    wire        mem_we;
    wire [23:0] mem_rdata;
    wire        mem_ready;

    //==========================================================================
    // Memory Subsystem ↔ MMIO
    //==========================================================================
    wire        mmio_req;
    wire [7:0]  mmio_addr;
    wire [23:0] mmio_wdata;
    wire        mmio_we;
    wire [23:0] mmio_rdata;
    wire        mmio_ready;

    //==========================================================================
    // CPU instance
    //==========================================================================
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

    //==========================================================================
    // Memory Subsystem
    //==========================================================================
    memory_subsystem #(
        .RAM_ADDR_WIDTH (14)   // 16K word = 384Kbit (Tang Nano 9K has 468Kbit BRAM)
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

    //==========================================================================
    // MMIO instance
    //==========================================================================
    wire [15:0] led_full;
    wire        timer_irq;

    mmio u_mmio (
        .clk        (clk),
        .rst        (rst),
        .mmio_req   (mmio_req),
        .mmio_addr  (mmio_addr),
        .mmio_wdata (mmio_wdata),
        .mmio_we    (mmio_we),
        .mmio_rdata (mmio_rdata),
        .mmio_ready (mmio_ready),
        .led        (led_full),
        .btn        ({1'b0, btn}),
        .gpio       (gpio),
        .timer_irq  (timer_irq),
        .uart_rx    (uart_rx),
        .uart_tx    (uart_tx)
    );

    // Tang Nano 9K has 6 LEDs (active low on some boards, active high on others)
    // Use lower 6 bits of LED register
    assign led = ~led_full[5:0];  // active low (adjust for your board)

endmodule
