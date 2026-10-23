#!/usr/bin/env python3
"""k16 CPU 逆アセンブラモジュール.

24-bit 命令ワードを人間が読みやすい k16 アセンブリ表記にデコードします。
"""

from __future__ import annotations

# 条件コード逆引き (0~7)
COND_INV = {
    0: "AL",  # Always (通常省略される)
    1: "NE",
    2: "NC",
    3: "PL",
    4: "NV",  # Never (NOP 等)
    5: "EQ",
    6: "CS",
    7: "MI",
}

# ALU R形式ファンクション (0~7)
FUNCT_R_INV = {
    0: "NAND",
    1: "OR",
    2: "AND",
    3: "XOR",
    4: "ADD",
    5: "SUB",
    6: "ADC",
    7: "SHR",
}

# ALU I形式ファンクション (0~6)
FUNCT_I_INV = {
    0: "NANDI",
    1: "ORI",
    2: "ANDI",
    3: "XORI",
    4: "ADDI",
    5: "SUBI",
    6: "ADCI",
}

# ロード・ストア形式ファンクション (0~3)
LS_INV = {
    0: ("LD", "+"),
    1: ("LD", "-"),
    2: ("ST", "+"),
    3: ("ST", "-"),
}


def reg_name(num: int) -> str:
    """レジスタ番号をレジスタ名に変換します。"""
    if num == 0:
        return "r0"
    if num == 14:
        return "flags"
    if num == 15:
        return "pc"
    return f"r{num}"


def disassemble_word(word: int) -> str:
    """24-bit 命令ワードを逆アセンブルした文字列を返します。"""
    word = word & 0xFFFFFF

    cond = (word >> 21) & 0x7
    fmt = (word >> 19) & 0x3
    rd = (word >> 15) & 0xF
    rs1 = (word >> 11) & 0xF
    rs2 = (word >> 7) & 0xF
    imm8 = (word >> 3) & 0xFF
    funct = word & 0x7
    imm9 = (word >> 2) & 0x1FF
    ls_funct = word & 0x3

    cond_suffix = ""
    if cond != 0 and cond != 4:  # AL(0)は通常省略、NV(4)はNOPの基底
        cond_suffix = f".{COND_INV.get(cond, str(cond)).lower()}"

    # NOPチェック: NV cond, NAND, rd=0, rs1=0, rs2=0 (0x800000)
    if word == 0x800000:
        return "NOP"

    # fmt 00: R形式
    if fmt == 0b00:
        # RET 特殊ケース: cond, rd=15, rs1=12, rs2=0, ADD
        if rd == 15 and rs1 == 12 and rs2 == 0 and funct == 4:
            return f"RET{cond_suffix}"

        # MOV 疑似命令ケース: cond, rd, rs1, rs2=0, ADD
        if rs2 == 0 and funct == 4 and rd != 15 and rd != 0:
            return f"MOV{cond_suffix} {reg_name(rd)}, {reg_name(rs1)}"

        # CMP 疑似命令ケース: rd=0, SUB (比較)
        if rd == 0 and funct == 5:
            return f"CMP{cond_suffix} {reg_name(rs1)}, {reg_name(rs2)}"

        # TEST 疑似命令ケース: rd=0, AND (ビットテスト)
        if rd == 0 and funct == 2:
            return f"TEST{cond_suffix} {reg_name(rs1)}, {reg_name(rs2)}"

        op_name = FUNCT_R_INV.get(funct, f"ALU_R_{funct}")
        if op_name == "SHR":
            return f"{op_name}{cond_suffix} {reg_name(rd)}, {reg_name(rs1)}"
        return f"{op_name}{cond_suffix} {reg_name(rd)}, {reg_name(rs1)}, {reg_name(rs2)}"

    # fmt 01: I形式
    elif fmt == 0b01:
        # JMP / BRA 特殊ケース: cond, rd=15, rs=0, imm8, ADD
        if rd == 15 and rs1 == 0 and funct == 4:
            return f"JMP{cond_suffix} 0x{imm8:02X}"

        # LI 特殊ケース: cond, rd!=0, rs=0, imm8, ADD
        if rs1 == 0 and funct == 4 and rd != 0:
            return f"LI{cond_suffix} {reg_name(rd)}, 0x{imm8:02X}"

        # CMPI 疑似命令ケース: rd=0, SUBI
        if rd == 0 and funct == 5:
            return f"CMPI{cond_suffix} {reg_name(rs1)}, 0x{imm8:02X}"

        # TESTI 疑似命令ケース: rd=0, ANDI
        if rd == 0 and funct == 2:
            return f"TESTI{cond_suffix} {reg_name(rs1)}, 0x{imm8:02X}"


        op_name = FUNCT_I_INV.get(funct, f"ALU_I_{funct}")
        return f"{op_name}{cond_suffix} {reg_name(rd)}, {reg_name(rs1)}, 0x{imm8:02X}"

    # fmt 11: LS形式
    elif fmt == 0b11:
        base_op, sign = LS_INV.get(ls_funct, ("LD", "+"))
        offset_str = f" {sign} {imm9}" if (imm9 != 0 or sign == "-") else ""
        return f"{base_op}{cond_suffix} {reg_name(rd)}, [{reg_name(rs1)}{offset_str}]"

    # 未定義フォーマット
    return f".word 0x{word:06X}"
