module alu (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] A,
    input  wire [15:0] B,
    input  wire [2:0]  funct,

    output reg  [15:0] result,

    // フラグ
    // Z : Zero
    // C : Carry / Borrowなし
    // N : Negative
    output reg         Z,
    output reg         C,
    output reg         N
);

    // 17bit目でCarryを取得するための一時レジスタ
    reg [16:0] temp;


    //==========================================================
    // ALU
    //==========================================================

    always @(*) begin

        // デフォルト値
        temp   = 17'b0;
        result = 16'b0;

        case (funct)

            // NAND
            3'b000: begin
                result = ~(A & B);
            end

            // OR
            3'b001: begin
                result = A | B;
            end

            // AND
            3'b010: begin
                result = A & B;
            end

            // XOR
            3'b011: begin
                result = A ^ B;
            end

            // ADD
            3'b100: begin
                temp   = {1'b0, A} + {1'b0, B};
                result = temp[15:0];
            end

            // SUB
            // A - B = A + ~B + 1
            // temp[16] = Borrowなし
            3'b101: begin
                temp   = {1'b0, A}
                       + {1'b0, ~B}
                       + 17'b1;

                result = temp[15:0];
            end

            // ADC
            // A + B + C
            3'b110: begin
                temp   = {1'b0, A}
                       + {1'b0, B}
                       + C;

                result = temp[15:0];
            end

            // 未定義命令
            // 3'b111、および不正な状態
            default: begin
                temp   = 17'b0;
                result = 16'b0;
            end

        endcase
    end


    //==========================================================
    // フラグレジスタ
    //==========================================================

    always @(posedge clk or posedge rst) begin

        // 正論理・非同期リセット
        if (rst) begin
            Z <= 1'b0;
            C <= 1'b0;
            N <= 1'b0;
        end

        else begin

            // Zero Flag
            // 演算結果が0なら1
            Z <= (result == 16'b0);

            // Negative Flag
            // 2の補数表現における符号bit
            N <= result[15];

            // Carry Flag
            case (funct)

                // ADD
                // SUB
                // ADC
                3'b100,
                3'b101,
                3'b110: begin
                    C <= temp[16];
                end

                // 論理演算ではCを保持
                default: begin
                    C <= C;
                end

            endcase
        end
    end

endmodule
