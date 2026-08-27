module regfile(
    // クロック・リセット
    input         clk,        // クロック
    input         rst,        // High有効リセット

    // ALUフラグ
    input         zf,         // Zero Flag
    input         cf,         // Carry Flag
    input         nf,         // Negative Flag

    // 16bitレジスタ書き込み
    input  [15:0] wtdata,     // 書き込みデータ
    input         wtenable,   // 書き込み許可
    input   [3:0] wtaddr,     // 書き込み先

    // 24bitメモリ用上位8bit
    input   [7:0] topin,      // メモリ[23:16]
    input         topenable,  // r13[7:0]書き込み許可
    output  [7:0] topout,     // r13[7:0]

    // レジスタ読み出し
    input   [3:0] rdaddr_a,   // 読み出しA
    input   [3:0] rdaddr_b,   // 読み出しB
    output [15:0] rddata_a,   // データA
    output [15:0] rddata_b,   // データB

    // 命令フェッチ用PC出力
    output [15:0] pc,

    // ノイマン型 単一メモリバス調停用
    // 今サイクルのメモリバスがデータアクセスに使われ、命令フェッチが
    // 行えなかった場合に1を入力する。PCの+1を止め、次サイクルに
    // 同じアドレスで再フェッチできるようにする。
    input         pc_hold
);

    // 16bit × 16本
    // r0      = ゼロレジスタ
    // r1～r12 = 汎用レジスタ
    // r13     = 24bitメモリ上位8bit
    // r14     = フラグ
    // r15     = PC
    reg [15:0] regs [0:15];

    integer i;

    // 命令フェッチ用PC
    assign pc = regs[15];

    //==============================================================
    // レジスタ読み出し
    //==============================================================

    // r0は常に0
    // r14はALUフラグを直接返す
    assign rddata_a =
        (rdaddr_a == 4'd0)  ? 16'h0000 :
        (rdaddr_a == 4'd14) ? {13'b0, nf, cf, zf} :
                              regs[rdaddr_a];

    assign rddata_b =
        (rdaddr_b == 4'd0)  ? 16'h0000 :
        (rdaddr_b == 4'd14) ? {13'b0, nf, cf, zf} :
                              regs[rdaddr_b];

    // 24bitメモリの上位8bit
    assign topout = regs[13][7:0];

    //==============================================================
    // 書き込み・PC更新
    //==============================================================

    always @(posedge clk or posedge rst) begin

        if (rst) begin

            // リセット時は全レジスタを0にする
            for (i = 0; i < 16; i = i + 1)
                regs[i] <= 16'h0000;

        end else begin

            //======================================================
            // 通常の16bitレジスタ書き込み
            // r0・r14は禁止
            // 24bit LOAD時のr13も禁止
            //======================================================

            if (wtenable &&
                (wtaddr != 4'd0) &&
                (wtaddr != 4'd14) &&
                !(topenable && (wtaddr == 4'd13))) begin

                regs[wtaddr] <= wtdata;

            end

            //======================================================
            // 24bitメモリ上位8bit
            // memory[23:16] → r13[7:0]
            //======================================================

            if (topenable)
                regs[13][7:0] <= topin;

            //======================================================
            // PC
            // 明示的なPC書き込み(分岐)があればそのアドレスへ、
            // なければ通常は+1。
            // ただしpc_hold時(=このサイクルは単一バスをデータ
            // アクセスに使用しフェッチできなかった)はPCを保持し、
            // 次サイクルで同じアドレスを再フェッチさせる。
            //======================================================

            if (wtenable && (wtaddr == 4'd15)) begin
                // 分岐は既にregs[wtaddr]<=wtdataで書き込み済み (何もしない)
            end else if (!pc_hold) begin
                regs[15] <= regs[15] + 16'd1;
            end

        end
    end

endmodule
