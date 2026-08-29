/*==============================================================================
 * モジュール名 : uart
 * 概要         : 8-N-1 UART 送受信モジュール (自己完結型・KISS原則)
 * 
 * 【仕様】
 * - フォーマット : 8データビット、パリティなし、1ストップビット (8-N-1)
 * - ボーレート   : パラメータ CLKS_PER_BIT で指定 (デフォルト 868: 100MHz時 115200bps)
 * - リセット     : Highアクティブ同期/非同期リセット (rst)
 *============================================================================*/

module uart #(
    parameter CLKS_PER_BIT = 868  // 1ビットあたりのクロックサイクル数
)(
    input  wire       clk,        // システムクロック
    input  wire       rst,        // Highアクティブリセット

    // 送信インターフェース (TX)
    input  wire [7:0] tx_data,    // 送信データ
    input  wire       tx_start,   // 送信開始パルス (1クロック幅)
    output wire       uart_tx,    // UART TX ピン出力
    output wire       tx_busy,    // 送信中フラグ (1: 送信中, 0: アイドル)
    output reg        tx_done,    // 送信完了パルス (1クロック幅)

    // 受信インターフェース (RX)
    input  wire       uart_rx,    // UART RX ピン入力
    output reg  [7:0] rx_data,    // 受信データ
    output reg        rx_ready,   // 受信完了フラグ (データ保持中: 1)
    input  wire       rx_clear    // 受信フラグクリア入力
);

    //==========================================================================
    // UART 送信 (TX) 制御ステートマシン
    //==========================================================================
    localparam TX_IDLE  = 2'd0;
    localparam TX_START = 2'd1;
    localparam TX_DATA  = 2'd2;
    localparam TX_STOP  = 2'd3;

    reg [1:0]  tx_state;
    reg [15:0] tx_clk_cnt;
    reg [2:0]  tx_bit_idx;
    reg [7:0]  tx_shift_reg;
    reg        tx_out;

    assign uart_tx = tx_out;
    assign tx_busy = (tx_state != TX_IDLE);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_state     <= TX_IDLE;
            tx_clk_cnt   <= 16'd0;
            tx_bit_idx   <= 3'd0;
            tx_shift_reg <= 8'd0;
            tx_out       <= 1'b1; // アイドル時はHigh
            tx_done      <= 1'b0;
        end else begin
            tx_done <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    tx_out     <= 1'b1;
                    tx_clk_cnt <= 16'd0;
                    tx_bit_idx <= 3'd0;
                    if (tx_start) begin
                        tx_shift_reg <= tx_data;
                        tx_state     <= TX_START;
                        tx_out       <= 1'b0; // スタートビット (Low)
                    end
                end

                TX_START: begin
                    tx_out <= 1'b0;
                    if (tx_clk_cnt < CLKS_PER_BIT - 1) begin
                        tx_clk_cnt <= tx_clk_cnt + 16'd1;
                    end else begin
                        tx_clk_cnt <= 16'd0;
                        tx_state   <= TX_DATA;
                    end
                end

                TX_DATA: begin
                    tx_out <= tx_shift_reg[tx_bit_idx];
                    if (tx_clk_cnt < CLKS_PER_BIT - 1) begin
                        tx_clk_cnt <= tx_clk_cnt + 16'd1;
                    end else begin
                        tx_clk_cnt <= 16'd0;
                        if (tx_bit_idx < 3'd7) begin
                            tx_bit_idx <= tx_bit_idx + 3'd1;
                        end else begin
                            tx_bit_idx <= 3'd0;
                            tx_state   <= TX_STOP;
                        end
                    end
                end

                TX_STOP: begin
                    tx_out <= 1'b1; // ストップビット (High)
                    if (tx_clk_cnt < CLKS_PER_BIT - 1) begin
                        tx_clk_cnt <= tx_clk_cnt + 16'd1;
                    end else begin
                        tx_clk_cnt <= 16'd0;
                        tx_state   <= TX_IDLE;
                        tx_done    <= 1'b1;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    //==========================================================================
    // UART 受信 (RX) 制御ステートマシン
    //==========================================================================
    localparam RX_IDLE  = 2'd0;
    localparam RX_START = 2'd1;
    localparam RX_DATA  = 2'd2;
    localparam RX_STOP  = 2'd3;

    reg [1:0]  rx_state;
    reg [15:0] rx_clk_cnt;
    reg [2:0]  rx_bit_idx;
    reg [7:0]  rx_shift_reg;

    // メタスタビリティ対策 (2段同期化)
    reg rx_sync1, rx_sync2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= uart_rx;
            rx_sync2 <= rx_sync1;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_state     <= RX_IDLE;
            rx_clk_cnt   <= 16'd0;
            rx_bit_idx   <= 3'd0;
            rx_shift_reg <= 8'd0;
            rx_data      <= 8'd0;
            rx_ready     <= 1'b0;
        end else begin
            if (rx_clear) begin
                rx_ready <= 1'b0;
            end

            case (rx_state)
                RX_IDLE: begin
                    rx_clk_cnt <= 16'd0;
                    rx_bit_idx <= 3'd0;
                    // スタートビット (立ち下がり) 検知
                    if (rx_sync2 == 1'b0) begin
                        rx_state <= RX_START;
                    end
                end

                // スタートビットの中央まで待機
                RX_START: begin
                    if (rx_clk_cnt < (CLKS_PER_BIT / 2)) begin
                        rx_clk_cnt <= rx_clk_cnt + 16'd1;
                    end else begin
                        rx_clk_cnt <= 16'd0;
                        if (rx_sync2 == 1'b0) begin
                            rx_state <= RX_DATA; // 正常なスタートビット確認
                        end else begin
                            rx_state <= RX_IDLE; // ノイズ等による誤検知
                        end
                    end
                end

                // データビット受信 (各ビットの中央でサンプリング)
                RX_DATA: begin
                    if (rx_clk_cnt < CLKS_PER_BIT - 1) begin
                        rx_clk_cnt <= rx_clk_cnt + 16'd1;
                    end else begin
                        rx_clk_cnt               <= 16'd0;
                        rx_shift_reg[rx_bit_idx] <= rx_sync2;
                        if (rx_bit_idx < 3'd7) begin
                            rx_bit_idx <= rx_bit_idx + 3'd1;
                        end else begin
                            rx_bit_idx <= 3'd0;
                            rx_state   <= RX_STOP;
                        end
                    end
                end

                // ストップビット受信
                RX_STOP: begin
                    if (rx_clk_cnt < CLKS_PER_BIT - 1) begin
                        rx_clk_cnt <= rx_clk_cnt + 16'd1;
                    end else begin
                        rx_clk_cnt <= 16'd0;
                        rx_state   <= RX_IDLE;
                        rx_data    <= rx_shift_reg;
                        rx_ready   <= 1'b1; // 受信完了フラグをセット
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

endmodule
