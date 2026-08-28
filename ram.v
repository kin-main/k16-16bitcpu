module ram #(
    // FPGAおよびシミュレーション用初期化ファイル
    // $readmemh で firmware.hex をロードする
    // 合成ツール (Quartus/Vivado) では BRAM の初期値として使用される
    parameter INIT_FILE = "firmware.hex"
)(
    input  wire        clk,

    // 統合メモリポート (命令フェッチ / データアクセス共用, ノイマン型)
    // 同一サイクルに使えるのは1系統のみ。cpu側でアドレスを
    // 命令フェッチ用(PC) / データアクセス用(ALU結果) に多重化してから接続する。
    input  wire [15:0] addr,
    input  wire [23:0] wdata,
    output wire [23:0] rdata,
    input  wire        we
);

    // 24bit x 65536 ワードのメモリ空間 (命令・データ共用の単一アドレス空間)
    reg [23:0] memory [0:65535];

    // 初期化: firmware.hex をロード
    // シミュレーション: $readmemh で即時ロード
    // FPGA合成: Quartus/Vivado が BRAM init として解釈
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, memory);
        end
    end

    // 非同期読み出し (組み合わせ回路)
    assign rdata = memory[addr];

    // クロック同期書き込み
    always @(posedge clk) begin
        if (we) begin
            memory[addr] <= wdata;
        end
    end

endmodule
