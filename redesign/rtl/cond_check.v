module cond_check (
    input  wire [2:0] cond,  // 実行条件フィールド
    input  wire       zf,    // Zero フラグ
    input  wire       cf,    // Carry フラグ
    input  wire       nf,    // Negative フラグ
    output reg        match  // 条件成立フラグ (1: 実行, 0: NOP化)
);

    always @(*) begin
        case (cond)
            3'b000: match = 1'b1;       // 常に実行 (Always)
            3'b001: match = ~zf;        // Z == 0 (Not Zero / NE)
            3'b010: match = ~cf;        // C == 0 (Not Carry / NC)
            3'b011: match = ~nf;        // N == 0 (Positive)
            3'b100: match = 1'b0;       // 実行しない (Never / NOP)
            3'b101: match = zf;         // Z == 1 (Zero / EQ)
            3'b110: match = cf;         // C == 1 (Carry / CS)
            3'b111: match = nf;         // N == 1 (Negative / MI)
            default: match = 1'b0;
        endcase
    end

endmodule
