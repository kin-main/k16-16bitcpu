/*==============================================================================
 * モジュール名 : tangnano9k_top
 * 概要          : Gowin Tang Nano 9K 用の k16_soc トップレベル wrapper
 *
 * ピンアサイン仕様 (Tang Nano 9K):
 *   - clk_27mhz : Pin 52  (27MHz オンボードクロック)
 *   - rst_n     : Pin 4   (S1 Push Button / Active Low)
 *   - led       : Pin 10, 11, 13, 14, 15, 16 (Active Low LED1〜LED6)
 *   - uart_tx   : Pin 17
 *   - uart_rx   : Pin 18
 *============================================================================*/

module tangnano9k_top (
    input  wire       clk_27mhz, // 27MHz クロックピン
    input  wire       rst_n,     // S1 ボタン (Active Low リセット)
    input  wire       uart_rx,   // UART RX
    output wire       uart_tx,   // UART TX
    output wire [5:0] led        // LED1〜LED6
);

    // Active Low の押しボタン (押した時0) を Active High リセットに変換
    wire rst = ~rst_n;

    // k16 SoC インスタンス
    // 27MHz で 115200bps -> CLKS_PER_BIT = 234
    wire [7:0] soc_led;

    k16_soc #(
        .CLKS_PER_BIT (234),
        .INIT_FILE    ("firmware_led.hex")
    ) u_soc (
        .clk     (clk_27mhz),
        .rst     (rst),
        .uart_rx (uart_rx),
        .uart_tx (uart_tx),
        .led     (soc_led)
    );

    // 下位6ビットをオンボードLEDに出力
    assign led = soc_led[5:0];

endmodule
