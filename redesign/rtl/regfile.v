//==============================================================================
// k16 Register File — 再設計版
//
// 変更点:
//   - PC (r15) を regfile から分離。CPU側で fetch_pc / ir_addr として管理
//   - Write-first bypass 削除 (組み合わせループ回避)
//   - pc_hold 入力削除 (CPU側で fetch_pc を直接制御)
//   - pc_cur 入力追加 (r15読出し用 = CPU側の ir_addr)
//   - r13[7:0] への topin 書き込みを LOAD r13 の場合も正しく処理
//
// レジスタ構成:
//   r0       : ゼロレジスタ (常に0, 書き込み無視)
//   r1-r12   : 汎用レジスタ
//   r13      : 拡張レジスタ (r13[7:0] = メモリ上位8bit)
//   r14      : フラグレジスタ (読出し専用 = {13'b0, N, C, Z})
//   r15      : PC (読出し = pc_cur入力, 書き込み = CPU側で処理)
//==============================================================================

module regfile (
    input  wire        clk,
    input  wire        rst,

    // ALU flags (for r14 read)
    input  wire        zf,
    input  wire        cf,
    input  wire        nf,

    // 16-bit register write port
    input  wire [15:0] wtdata,
    input  wire        wtenable,
    input  wire [3:0]  wtaddr,

    // 24-bit memory top byte (r13[7:0])
    input  wire [7:0]  topin,
    input  wire        topenable,
    output wire [7:0]  topout,

    // Read ports
    input  wire [3:0]  rdaddr_a,
    input  wire [3:0]  rdaddr_b,
    output wire [15:0] rddata_a,
    output wire [15:0] rddata_b,

    // Current PC (for r15 read) — from CPU's ir_addr
    input  wire [15:0] pc_cur
);

    reg [15:0] regs [0:15];

    integer i;

    //==========================================================================
    // Read ports (combinational, no bypass)
    //==========================================================================
    // r0  = always 0
    // r14 = flags {13'b0, N, C, Z}
    // r15 = pc_cur (from CPU)
    assign rddata_a =
        (rdaddr_a == 4'd0)  ? 16'h0000 :
        (rdaddr_a == 4'd14) ? {13'b0, nf, cf, zf} :
        (rdaddr_a == 4'd15) ? pc_cur :
                              regs[rdaddr_a];

    assign rddata_b =
        (rdaddr_b == 4'd0)  ? 16'h0000 :
        (rdaddr_b == 4'd14) ? {13'b0, nf, cf, zf} :
        (rdaddr_b == 4'd15) ? pc_cur :
                              regs[rdaddr_b];

    // r13[7:0] output
    assign topout = regs[13][7:0];

    //==========================================================================
    // Write logic
    //==========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < 16; i = i + 1)
                regs[i] <= 16'h0000;
        end else begin
            // Normal 16-bit register write
            // r0, r14, r15 are read-only (CPU handles r15 writes as branches)
            // For LOAD r13 (topenable && wtaddr==r13): both writes happen,
            //   r13[15:8] from wtdata, r13[7:0] from topin (last assignment wins for [7:0])
            if (wtenable &&
                (wtaddr != 4'd0) &&
                (wtaddr != 4'd14) &&
                (wtaddr != 4'd15)) begin
                regs[wtaddr] <= wtdata;
            end

            // 24-bit memory top byte → r13[7:0]
            // This overrides the low 8 bits of the normal write when wtaddr==r13
            if (topenable) begin
                regs[13][7:0] <= topin;
            end
        end
    end

endmodule
