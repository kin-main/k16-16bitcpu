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
    output wire        uart_tx    // UART 送信ピン
);

    // MMIO レジスタアドレス定数
    localparam ADDR_UART_DATA   = 16'hFF00;
    localparam ADDR_UART_STATUS = 16'hFF01;

    // UART 内部配線
    // tx_hold: 書き込みサイクルにラッチした送信データ。
    // tx_startは1サイクル遅延パルスのため、tx_dataをバスの組み合わせ値のまま
    // 渡すと、uartがラッチするタイミングでバスは次命令の内容に変わってしまう。
    // ここでデータも一緒にレジスタ保存して渡す。
    reg [7:0]  tx_hold;
    reg        tx_start;
    wire       tx_busy;
    wire       tx_done;

    wire [7:0] rx_data;
    wire       rx_ready;
    reg        rx_clear;

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
    // MMIO レジスタ書き込み制御
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_start <= 1'b0;
            tx_hold  <= 8'd0;
        end else begin
            tx_start <= 1'b0;

            // 0xFF00への書き込みで送信トリガーを生成 (データも同時にラッチ)
            if (we && (addr == ADDR_UART_DATA) && !tx_busy) begin
                tx_start <= 1'b1;
                tx_hold  <= wdata[7:0];
            end
        end
    end

    //==========================================================================
    // MMIO レジスタ読み出し制御 (同期読み出し: BRAMと同等の1サイクル遅延)
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rdata    <= 24'd0;
            rx_clear <= 1'b0;
        end else begin
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

                default: begin
                    rdata <= 24'd0;
                end
            endcase
        end
    end

endmodule
