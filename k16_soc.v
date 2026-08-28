/*==============================================================================
 * モジュール名 : k16_soc
 * 概要         : k16 CPU, 統合RAM, MMIO(UART IO) を統合したノイマン型SoCトップ
 * 
 * 【アーキテクチャ】
 * - ノイマン型: 命令フェッチとデータアクセスで単一の共有メモリバスを使用
 * - メモリマップ:
 *     0x0000 〜 0xFEFF : メインRAM (命令・データ共用)
 *     0xFF00 〜 0xFFFF : MMIO (0xFF00: UART_DATA, 0xFF01: UART_STATUS)
 * - 起動時 firmware.hex を $readmemh でロード (FPGA/シミュレーション両用)
 *============================================================================*/

module k16_soc #(
    parameter CLKS_PER_BIT = 868,             // 1ビットあたりのクロックサイクル数
    parameter INIT_FILE    = "firmware.hex"   // 起動時ロードするファームウェアHEX
)(
    input  wire clk,
    input  wire rst,

    // シリアル通信ピン
    input  wire uart_rx,
    output wire uart_tx
);

    //==========================================================================
    // 統合メモリバス (ノイマン型単一バス)
    //==========================================================================
    wire [15:0] mem_addr;
    wire [23:0] mem_wdata;
    wire [23:0] mem_rdata;
    wire        mem_we;

    // RAM / MMIO 読み出しデータ
    wire [23:0] ram_rdata;
    wire [23:0] mmio_rdata;

    // アドレスデコード: 0xFF00以上はMMIO領域
    wire is_mmio = (mem_addr >= 16'hFF00);

    // 書き込みイネーブルの振り分け
    wire ram_we  = mem_we && (!is_mmio);
    wire mmio_we = mem_we && is_mmio;

    // 読み出しデータのマルチプレクス (ノイマン型単一バスへ返却)
    assign mem_rdata = is_mmio ? mmio_rdata : ram_rdata;

    //==========================================================================
    // 1. k16 CPU コア
    //==========================================================================
    cpu u_cpu (
        .clk       (clk),
        .rst       (rst),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_rdata (mem_rdata),
        .mem_we    (mem_we)
    );

    //==========================================================================
    // 2. メインRAM (24bit幅, 64Kワード空間)
    //==========================================================================
    ram #(
        .INIT_FILE (INIT_FILE)
    ) u_ram (
        .clk   (clk),
        .addr  (mem_addr),
        .wdata (mem_wdata),
        .rdata (ram_rdata),
        .we    (ram_we)
    );

    //==========================================================================
    // 3. MMIO コントローラ (UART I/O 含む)
    //==========================================================================
    mmio #(
        .CLKS_PER_BIT (CLKS_PER_BIT)
    ) u_mmio (
        .clk      (clk),
        .rst      (rst),
        .addr     (mem_addr),
        .wdata    (mem_wdata),
        .rdata    (mmio_rdata),
        .we       (mmio_we),
        .uart_rx  (uart_rx),
        .uart_tx  (uart_tx)
    );

endmodule
