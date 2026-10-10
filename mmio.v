/*==============================================================================
 * モジュール名 : mmio
 * 概要         : メモリマップドI/O (MMIO) コントローラ & UART I/O 実装
 * 
 * 【アドレスマップ (0xFF00 〜 0xFFFF)】
 * - 0xFF00 : UART_DATA
 *            [Write] 送信データ (下位8bit) を書き込み、自動でUART送信を開始
 *            [Read]  受信データ (下位8bit) を読み出し、同時に受信フラグ (rx_ready) をクリア
 * - 0xFF01 : UART_STATUS
 *            [Read]  ビット0: tx_busy  (1: 送信中, 0: 送信可能/アイドル)
 *                    ビット1: rx_ready (1: 未読受信データあり, 0: なし)
 * - 0xFF02 : LED_DATA
 *            [Write] LED出力データ (下位8bit) を書き込み、物理LEDを制御
 *            [Read]  現在のLED出力値 (下位8bit) を読み出し
 *============================================================================*/

module mmio #(
    parameter CLKS_PER_BIT = 868  // 1ビットあたりのクロックサイクル数
)(
    input  wire        clk,
    input  wire        rst,

    // CPUバスインターフェース
    input  wire [15:0] addr,      // アクセスアドレス (0xFF00〜0xFFFF)
    input  wire [23:0] wdata,     // 書き込みデータ (Store時)
    output reg  [23:0] rdata,     // 読み出しデータ (Load時)
    input  wire        we,        // 書き込みイネーブル

    // 外部シリアルインターフェース
    input  wire        uart_rx,   // UART 受信ピン
    output wire        uart_tx,   // UART 送信ピン

    // LEDインターフェース (Tang Nano 9K の Active Low LED ピンに合わせ反転出力)
    output wire [7:0]  led        // LED出力ピン (0xFF02)
);

    reg [7:0] led_reg;
    assign led = ~led_reg; // Active Low 反転 (CPUから1書き込みで物理LED点灯)

    // MMIO レジスタアドレス定数
    localparam ADDR_UART_DATA   = 16'hFF00;
    localparam ADDR_UART_STATUS = 16'hFF01;
    localparam ADDR_LED_DATA    = 16'hFF02;

    // UART 内部配線
    wire [7:0] tx_data  = wdata[7:0];
    reg  [7:0] tx_hold;
    wire       tx_busy;
    wire       tx_done;

    wire [7:0] rx_data;
    wire       rx_ready;
    reg        rx_clear;

    // 0xFF00への書き込みで送信トリガーを生成 (組み合わせ回路)
    wire tx_start = we && (addr == ADDR_UART_DATA) && !tx_busy;

    // UART モジュールのインスタンス化
    uart #(
        .CLKS_PER_BIT (CLKS_PER_BIT)
    ) u_uart (
        .clk      (clk),
        .rst      (rst),
        .tx_data  (tx_hold),
        .tx_start (tx_start),
        .uart_tx  (uart_tx),
        .tx_busy  (tx_busy),
        .tx_done  (tx_done),
        .uart_rx  (uart_rx),
        .rx_data  (rx_data),
        .rx_ready (rx_ready),
        .rx_clear (rx_clear)
    );

    //==========================================================================
    // MMIO レジスタ読み出し制御 (同期読み出し: BRAMと同等の1サイクル遅延)
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rdata    <= 24'd0;
            tx_hold  <= 8'd0;
            rx_clear <= 1'b0;
            led_reg  <= 8'd0;
        end else begin
            if (we && (addr == ADDR_UART_DATA) && !tx_busy) begin
                tx_hold <= tx_data;
            end

            if (we && (addr == ADDR_LED_DATA)) begin
                led_reg <= wdata[7:0];
            end

            rx_clear <= 1'b0;
            case (addr)
                ADDR_UART_DATA: begin
                    rdata <= {16'd0, rx_data};
                    if (!we) begin
                        rx_clear <= 1'b1;
                    end
                end

                ADDR_UART_STATUS: begin
                    rdata <= {22'd0, rx_ready, tx_busy};
                end

                ADDR_LED_DATA: begin
                    rdata <= {16'd0, led_reg};
                end

                default: begin
                    rdata <= 24'd0;
                end
            endcase
        end
    end

endmodule
