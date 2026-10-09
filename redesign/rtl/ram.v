//==============================================================================
// k16 Synchronous RAM — 同期Read版
//
// 仕様:
//   - 同期Read: addrをclkに入力 → 次サイクルでrdataが出力
//   - 同期Write: we=1でposedgeに書き込み
//   - read-during-write: 同一アドレスへの書き込み中の読み出しは
//     古い値を返す (Gowin BRAM標準挙動 old-data mode)
//   - 初期化: $readmemh で hex ファイルからロード
//   - rdata を NOP で初期化 (リセット直後のX伝播防止)
//
// 合成時の注意 (Gowin FPGA):
//   - この記述で BRAM (SDP/pROM) に推論される
//   - 64K×24bit = 1.5Mbit は Tang Nano 9K (468Kbit BRAM) に収まらない
//     → RAM_ADDR_WIDTH=14 (16K word, 384Kbit) をデフォルトとする
//   - 実装時にパラメータでサイズを調整すること
//==============================================================================

module ram #(
    parameter RAM_ADDR_WIDTH = 14,              // 14bit = 16K word (default)
    parameter INIT_FILE      = "firmware.hex"   // 初期化ファイル
)(
    input  wire                    clk,
    input  wire [RAM_ADDR_WIDTH-1:0] addr,
    input  wire [23:0]             wdata,
    output reg  [23:0]             rdata,
    input  wire                    we
);
    reg [23:0] memory [0:(1<<RAM_ADDR_WIDTH)-1];

    // 初期化
    initial begin
        rdata = 24'h800000;  // NOP (X伝播防止)
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, memory);
        end
    end

    // 同期Read + 同期Write
    always @(posedge clk) begin
        if (we) begin
            memory[addr] <= wdata;
        end
        // 常にrdataを更新 (old-data mode: 書き込みと同アドレスの読出しは旧値)
        rdata <= memory[addr];
    end

endmodule
