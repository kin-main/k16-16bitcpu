module ram #(
    parameter INIT_FILE = "firmware.hex"
)(
    input  wire        clk,
    input  wire [13:0] addr,
    input  wire [23:0] wdata,
    output reg  [23:0] rdata,
    input  wire        we
);
    reg [23:0] memory [0:16383];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, memory);
        end
    end

    always @(posedge clk) begin
        if (we) begin
            memory[addr] <= wdata;
        end
        rdata <= memory[addr];
    end
endmodule
