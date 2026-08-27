module decoder (
    input  wire [23:0] inst,          // 24bit命令

    output wire [2:0]  cond,          // 実行条件フィールド [23:21]
    output wire [1:0]  op,            // オペコード [20:19]
    output wire [3:0]  rd,            // 宛先レジスタ / Storeデータ元 [18:15]
    output wire [3:0]  rs1,           // ソースレジスタ1 / Baseレジスタ [14:11]
    output wire [3:0]  rs2,           // ソースレジスタ2 [10:7] または Store時rd
    output reg  [15:0] imm,           // 拡張された即値 (16bit)
    output reg  [2:0]  alu_funct,     // ALU機能選択 (3bit)

    // 制御フラグ
    output wire        is_alu_reg,    // レジスタ間演算命令 (op=00)
    output wire        is_alu_imm,    // レジスタ即値演算命令 (op=01)
    output wire        is_load,       // ロード命令 (op=11, funkt[1]=0)
    output wire        is_store,      // ストア命令 (op=11, funkt[1]=1)
    output wire        alu_src_imm,   // ALU第2入力に即値を選択 (1: 即値, 0: レジスタB)
    output wire        reg_write,     // レジスタ書き込み要求 (条件判定前)
    output wire        flag_write     // フラグ更新要求 (条件判定前)
);

    // 基本フィールドの抽出
    assign cond = inst[23:21];
    assign op   = inst[20:19];
    assign rd   = inst[18:15];
    assign rs1  = inst[14:11];

    // 命令種別のデコード
    assign is_alu_reg = (op == 2'b00);
    assign is_alu_imm = (op == 2'b01);
    assign is_load    = (op == 2'b11) && (inst[1] == 1'b0);
    assign is_store   = (op == 2'b11) && (inst[1] == 1'b1);

    // rs2の選択: Store命令のときは書き込むデータ(rd)をレジスタBポートから読む
    assign rs2 = is_store ? rd : inst[10:7];

    // ALU第2オペランドの選択 (即値を使う場合: 1)
    assign alu_src_imm = is_alu_imm || (op == 2'b11);

    // レジスタ書き込み・フラグ更新要求（条件成立時に有効化される）
    assign reg_write  = is_alu_reg || is_alu_imm || is_load;
    assign flag_write = is_alu_reg || is_alu_imm;

    // 即値生成 (16bit)
    always @(*) begin
        case (op)
            // 即値演算: 8bitゼロ拡張
            2'b01:   imm = {8'b0, inst[10:3]};
            // ロード/ストア: 9bitゼロ拡張
            2'b11:   imm = {7'b0, inst[10:2]};
            default: imm = 16'b0;
        endcase
    end

    // ALU functの生成
    always @(*) begin
        case (op)
            // レジスタ間・即値演算: 命令のfunkt[2:0]をそのまま使用
            2'b00,
            2'b01: begin
                alu_funct = inst[2:0];
            end

            // ロード/ストアのアドレス計算:
            // funkt[0] == 0 -> 加算 (base + im)
            // funkt[0] == 1 -> 減算 (base - im)
            2'b11: begin
                alu_funct = (inst[0] == 1'b0) ? 3'b100 : 3'b101; // ADD or SUB
            end

            default: begin
                alu_funct = 3'b000;
            end
        endcase
    end

endmodule
