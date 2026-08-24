module ram (
    input  wire        clk,

    // 命令ポート (読み出し専用)
    input  wire [15:0] inst_addr,
    output wire [23:0] inst_data,

    // データポート (読み出し/書き込み)
    input  wire [15:0] mem_addr,
    input  wire [23:0] mem_wdata,
    output wire [23:0] mem_rdata,
    input  wire        mem_we
);

    // 24bit × 65536 ワードのメモリ空間
    reg [23:0] memory [0:65535];

    // 非同期読み出し (組み合わせ回路)
    assign inst_data = memory[inst_addr];
    assign mem_rdata = memory[mem_addr];

    // クロック同期書き込み
    always @(posedge clk) begin
        if (mem_we) begin
            memory[mem_addr] <= mem_wdata;
        end
    end

endmodule
