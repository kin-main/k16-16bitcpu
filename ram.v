module ram #(
    parameter INIT_FILE = "firmware.hex"
)(
    input  wire        clk,
    input  wire [13:0] addr,   // ★ 14bit幅 (16Kワード)
    input  wire [23:0] wdata,
    output reg  [23:0] rdata,  // ★ 同期読み出しのため reg
    input  wire        we
);

    reg [23:0] memory [0:16383]; // ★ 16384ワード (BSRAM内に収まるサイズ)

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, memory);
        end
    end

    // クロック同期読み出し・書き込み
    always @(posedge clk) begin
        if (we) begin
            memory[addr] <= wdata;
        end
        rdata <= memory[addr];
    end

endmodule
