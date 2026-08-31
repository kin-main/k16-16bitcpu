module ram #(
    parameter INIT_FILE = "firmware.hex"
)(
    input  wire        clk,
    input  wire [13:0] addr,
    input  wire [23:0] wdata,
    output wire [23:0] rdata,   // ★ reg → wire
    input  wire        we
);
    reg [23:0] memory [0:16383];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, memory);
        end
    end

    // 書き込みは従来通り同期
    always @(posedge clk) begin
        if (we) begin
            memory[addr] <= wdata;
        end
    end

    // 読み出しは組み合わせ（同サイクルで反映）
    assign rdata = memory[addr];
endmodule
