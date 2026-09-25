//==============================================================================
// k16 Memory Subsystem — RAM + MMIO ルーティング (同期RAM対応修正版)
//
// 修正点:
//   - 前サイクルの要求タイプ (prev_is_data, prev_is_mmio) を記憶
//   - mem_rdata と mem_ready は「前サイクルの要求」に対する応答として出力
//   - これにより CPU の S_MEM_RESP で正しいデータが取り込める
//==============================================================================

module memory_subsystem #(
    parameter RAM_ADDR_WIDTH = 14
)(
    input  wire        clk,
    input  wire        rst,

    // CPU interface
    input  wire        mem_data_req,
    input  wire [15:0] mem_addr,
    input  wire [23:0] mem_wdata,
    input  wire        mem_we,
    output wire [23:0] mem_rdata,
    output wire        mem_ready,

    // MMIO interface (to external MMIO module)
    output wire        mmio_req,
    output wire [7:0]  mmio_addr,
    output wire [23:0] mmio_wdata,
    output wire        mmio_we,
    input  wire [23:0] mmio_rdata,
    input  wire        mmio_ready
);
    wire is_mmio_addr = (mem_addr >= 16'hFF00);
    wire is_mmio_access = is_mmio_addr && mem_data_req;

    //==========================================================
    // RAM instance
    //==========================================================
    wire [23:0] ram_rdata;

    ram #(
        .RAM_ADDR_WIDTH (RAM_ADDR_WIDTH)
    ) u_ram (
        .clk   (clk),
        .addr  (mem_addr[RAM_ADDR_WIDTH-1:0]),
        .wdata (mem_wdata),
        .rdata (ram_rdata),
        .we    (mem_we && !is_mmio_access)
    );

    //==========================================================
    // MMIO interface (combinational request)
    //==========================================================
    assign mmio_req   = is_mmio_access;
    assign mmio_addr  = mem_addr[7:0];
    assign mmio_wdata = mem_wdata;
    assign mmio_we    = mem_we;

    //==========================================================
    // Track previous request type for response routing
    //==========================================================
    // 同期RAM/MMIOの応答は「1サイクル前の要求」に対するもの。
    // 現在の mem_rdata/mem_ready は前サイクルの要求に基づく。
    reg prev_is_data;
    reg prev_is_mmio;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            prev_is_data <= 1'b0;
            prev_is_mmio <= 1'b0;
        end else begin
            prev_is_data <= mem_data_req;
            prev_is_mmio <= is_mmio_addr && mem_data_req;
        end
    end

    //==========================================================
    // Response mux (based on PREVIOUS cycle's request)
    //==========================================================
    // prev_is_data=1, prev_is_mmio=1: data LOAD from MMIO → mmio_rdata
    // prev_is_data=1, prev_is_mmio=0: data LOAD from RAM → ram_rdata
    // prev_is_data=0, prev_is_mmio=1: fetch from MMIO → NOP
    // prev_is_data=0, prev_is_mmio=0: fetch from RAM → ram_rdata
    assign mem_rdata = (prev_is_data && prev_is_mmio) ? mmio_rdata :
                       (!prev_is_data && prev_is_mmio) ? 24'h800000 :  // NOP
                       ram_rdata;

    //==========================================================
    // Ready signal (based on PREVIOUS cycle's request)
    //==========================================================
    assign mem_ready = (!prev_is_data) ? 1'b1 :        // Fetch (always ready)
                       (!prev_is_mmio) ? 1'b1 :        // RAM data (always ready)
                       mmio_ready;                     // MMIO data (variable)

endmodule
