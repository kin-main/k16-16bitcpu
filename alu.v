module alu (
    input  wire        clk,
    input  wire        rst,
    input  wire        flag_en, // フラグ更新許可

    input  wire [15:0] A,
    input  wire [15:0] B,
    input  wire [2:0]  funct,

    output reg  [15:0] result,

    // フラグ
    // Z : Zero
    // C : Carry / Borrowなし / SHRの押し出しbit
    // N : Negative
    output reg         Z,
    output reg         C,
    output reg         N
);

    // 17bit目でCarryを取得するための一時レジスタ
    reg [16:0] temp;

    //==========================================================
    // ALU 演算部（組み合わせ回路）
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
            // temp[16] = Carry (Borrowなし)
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
                       + {16'b0, C};

                result = temp[15:0];
            end

            // SHR (論理右シフト 1bit)
            // A[0] を Carry に反映
            3'b111: begin
                result = {1'b0, A[15:1]};
                temp   = {15'b0, A[0], 1'b0}; // temp[1] に A[0] を保持
            end

            default: begin
                temp   = 17'b0;
                result = 16'b0;
            end

        endcase
    end

    //==========================================================
    // フラグレジスタ更新部
    //==========================================================

    always @(posedge clk or posedge rst) begin

        // 正論理・非同期リセット
        if (rst) begin
            Z <= 1'b0;
            C <= 1'b0;
            N <= 1'b0;
        end

        else if (flag_en) begin

            // Zero Flag: 演算結果が0なら1
            Z <= (result == 16'b0);

            // Negative Flag: 2の補数表現における符号bit
            N <= result[15];

            // Carry Flag
            case (funct)

                // ADD, SUB, ADC: temp[16] を反映
                3'b100,
                3'b101,
                3'b110: begin
                    C <= temp[16];
                end

                // SHR: A[0] を反映
                3'b111: begin
                    C <= A[0];
                end

                // 論理演算（NAND, OR, AND, XOR）ではCを保持
                default: begin
                    C <= C;
                end

            endcase
        end
    end

endmodule
