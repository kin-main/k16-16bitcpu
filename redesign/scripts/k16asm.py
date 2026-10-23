#!/usr/bin/env python3
"""Assembler for the memo-faithful k16 ISA.

Examples:
    LI   r1, 10
    ADD  r2, r1, r1
    LD.eq r3, [r4 + 2]
    JMP  done

The optional listing output includes the original source beside each word.
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

COND = {"AL": 0, "NE": 1, "NC": 2, "PL": 3, "NV": 4, "EQ": 5, "CS": 6, "MI": 7}
FUNCT = {"NAND": 0, "OR": 1, "AND": 2, "XOR": 3, "ADD": 4, "SUB": 5, "ADC": 6, "SHR": 7}
LS_FUNCT = {"LD+": 0, "LD-": 1, "ST+": 2, "ST-": 3}
REG_NAMES = {f"r{i}": i for i in range(16)}
REG_NAMES.update({"zero": 0, "flags": 14, "pc": 15})

ALU_R = {"NAND", "OR", "AND", "XOR", "ADD", "SUB", "ADC", "SHR"}
ALU_I = {"NANDI", "ORI", "ANDI", "XORI", "ADDI", "SUBI", "ADCI"}
MNEMONICS = (
<<<<<<< HEAD
    ("NOP", "no operation"),
    ("LI", "load an 8-bit immediate"),
    ("MOV", "copy a register"),
    ("CMP", "compare two registers (SUB to r0)"),
    ("CMPI", "compare register with 8-bit immediate"),
    ("TEST", "test two registers (AND to r0)"),
    ("TESTI", "test register with 8-bit immediate"),
    ("JMP / BRA", "jump to an 8-bit address"),

    ("CALL", "call an 8-bit address"),
    ("RET", "return through r12"),
    ("NAND", "register NAND"),
    ("OR", "register OR"),
    ("AND", "register AND"),
    ("XOR", "register XOR"),
    ("ADD", "register addition"),
    ("SUB", "register subtraction"),
    ("ADC", "register addition with carry"),
    ("SHR", "logical shift right by one"),
    ("NANDI", "NAND with an 8-bit immediate"),
    ("ORI", "OR with an 8-bit immediate"),
    ("ANDI", "AND with an 8-bit immediate"),
    ("XORI", "XOR with an 8-bit immediate"),
    ("ADDI", "addition with an 8-bit immediate"),
    ("SUBI", "subtraction with an 8-bit immediate"),
    ("ADCI", "addition with carry and an 8-bit immediate"),
    ("LD", "load from [base +/- offset]"),
    ("ST", "store to [base +/- offset]"),
=======
    ("NOP", "No operation"),
    ("LI", "Load immediate into register"),
    ("MOV", "Copy register value"),
    ("JMP", "Jump to target address"),
    ("BRA", "Branch alias of JMP"),
    ("CALL", "Call target and save return address"),
    ("RET", "Return from subroutine"),
    ("NAND", "Bitwise NAND"),
    ("OR", "Bitwise OR"),
    ("AND", "Bitwise AND"),
    ("XOR", "Bitwise XOR"),
    ("ADD", "Add registers"),
    ("SUB", "Subtract registers"),
    ("ADC", "Add with carry"),
    ("SHR", "Logical shift right"),
    ("NANDI", "Bitwise NAND with immediate"),
    ("ORI", "Bitwise OR with immediate"),
    ("ANDI", "Bitwise AND with immediate"),
    ("XORI", "Bitwise XOR with immediate"),
    ("ADDI", "Add immediate"),
    ("SUBI", "Subtract immediate"),
    ("ADCI", "Add immediate with carry"),
    ("LD", "Load from memory [base +/- offset]"),
    ("ST", "Store to memory [base +/- offset]"),
>>>>>>> bf3719485c4b0f76c70152074a8499d4f52adacb
)
CONDITION_SUFFIXES = tuple(COND)


@dataclass
class Item:
    address: int
    source: str
    line: int
    kind: str
    args: tuple[str, ...]


class AssemblerError(ValueError):
    pass


def encode_r(cond: int, rd: int, rs1: int, rs2: int, funct: int) -> int:
    return (cond << 21) | (rd << 15) | (rs1 << 11) | (rs2 << 7) | funct


def encode_i(cond: int, rd: int, rs: int, imm: int, funct: int) -> int:
    return (cond << 21) | (1 << 19) | (rd << 15) | (rs << 11) | ((imm & 0xFF) << 3) | funct


def encode_ls(cond: int, rd: int, base: int, imm: int, funct: int) -> int:
    return (cond << 21) | (3 << 19) | (rd << 15) | (base << 11) | ((imm & 0x1FF) << 2) | funct


def fail(item: Item, message: str) -> NoReturn:
    raise AssemblerError(f"{item.line}: {message}: {item.source}")


def parse_int(token: str, labels: dict[str, int], item: Item) -> int:
    token = token.strip()
    if token in labels:
        return labels[token]
    try:
        return int(token, 0)
    except ValueError:
        fail(item, f"unknown value '{token}'")


def parse_reg(token: str, item: Item) -> int:
    key = token.strip().lower()
    if key not in REG_NAMES:
        fail(item, f"invalid register '{token}'")
    return REG_NAMES[key]


def checked(value: int, bits: int, what: str, item: Item) -> int:
    if not 0 <= value < (1 << bits):
        fail(item, f"{what} must fit in {bits} bits (got {value})")
    return value


def parse_dest(token: str, item: Item) -> int:
    # r0 (zero) や r14 (flags) はハードウェア仕様上書き込みが無視（破棄）されるため、
    # 比較専用（CMP/TEST相当）や結果を保持しない演算の宛先として指定可能
    return parse_reg(token, item)



def split_operands(text: str) -> list[str]:
    result, current, depth = [], [], 0
    for char in text:
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
        if char == "," and depth == 0:
            result.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    if current:
        result.append("".join(current).strip())
    return result


def parse_source(path: Path) -> tuple[list[Item], dict[str, int]]:
    items: list[Item] = []
    labels: dict[str, int] = {}
    address = 0

    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        source = raw.split(";", 1)[0].split("#", 1)[0].strip()
        if not source:
            continue
        while ":" in source:
            label, rest = source.split(":", 1)
            label = label.strip()
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", label):
                raise AssemblerError(f"{line_no}: invalid label '{label}'")
            if label in labels:
                raise AssemblerError(f"{line_no}: duplicate label '{label}'")
            labels[label] = address
            source = rest.strip()
            if not source:
                break
        if not source:
            continue

        parts = source.split(None, 1)
        op = parts[0].upper()
        operands = tuple(split_operands(parts[1]) if len(parts) == 2 else ())
        if op == ".ORG":
            if len(operands) != 1:
                raise AssemblerError(f"{line_no}: .org requires one address")
            address = int(operands[0], 0)
            if address < 0:
                raise AssemblerError(f"{line_no}: .org cannot be negative")
            continue
        count = 2 if op == "CALL" else 1
        if op in {".WORD", ".FILL", ".STRING", ".ASCII"}:
            if op in {".STRING", ".ASCII"}:
                count = len(bytes(operands[0].strip("\"'"), "utf-8"))
                if op == ".STRING":
                    count += 1
            elif op == ".FILL":
                count = int(operands[0], 0)
            else:
                count = 1
        items.append(Item(address, source, line_no, op, operands))
        address += count
    return items, labels


def parse_memory_operand(token: str, labels: dict[str, int], item: Item) -> tuple[int, int, str]:
    match = re.fullmatch(r"\[\s*([^+\-\]]+)\s*([+\-])?\s*([^\]]+)?\s*\]", token)
    if not match:
        fail(item, "memory operand must look like [rN + imm]")
    base = parse_reg(match.group(1), item)
    sign = match.group(2) or "+"
    offset = parse_int(match.group(3) or "0", labels, item)
    return base, offset, sign


def assemble_item(item: Item, labels: dict[str, int]) -> list[int]:
    op = item.kind
    args = item.args
    if op in {".WORD", ".FILL", ".STRING", ".ASCII", ".ORG"}:
        if op == ".WORD":
            return [parse_int(args[0], labels, item) & 0xFFFFFF]
        if op == ".FILL":
            count = parse_int(args[0], labels, item)
            value = parse_int(args[1], labels, item) if len(args) > 1 else 0x800000
            return [value & 0xFFFFFF] * count
        text = args[0].strip("\"'")
        values = list(text.encode("utf-8"))
        return values + ([0] if op == ".STRING" else [])

    condition = 0
    if "." in op:
        op, suffix = op.split(".", 1)
        if suffix not in COND:
            fail(item, f"unknown condition '.{suffix.lower()}'")
        condition = COND[suffix]

    if op == "NOP":
        return [encode_r(COND["NV"], 0, 0, 0, FUNCT["NAND"])]
    if op == "LI":
        rd, value = parse_dest(args[0], item), parse_int(args[1], labels, item)
        checked(value, 8, "immediate", item)
        return [encode_i(condition, rd, 0, value, FUNCT["ADD"])]
    if op == "MOV":
        return [encode_r(condition, parse_dest(args[0], item), parse_reg(args[1], item), 0, FUNCT["ADD"])]
    if op in {"JMP", "BRA"}:
        target = parse_int(args[0], labels, item)
        checked(target, 8, "jump target", item)
        return [encode_i(condition, 15, 0, target, FUNCT["ADD"])]
    if op == "CALL":
        target = parse_int(args[0], labels, item)
        checked(target, 8, "call target", item)
        return [
            encode_i(condition, 12, 15, 1, FUNCT["ADD"]),
            encode_i(condition, 15, 0, target, FUNCT["ADD"]),
        ]
    if op == "RET":
        return [encode_r(condition, 15, 12, 0, FUNCT["ADD"])]

    if op == "CMP":
        # 比較疑似命令: SUB r0, rs1, rs2 (フラグのみ更新、結果はr0で破棄)
        if len(args) != 2:
            fail(item, "CMP requires rs1, rs2")
        rs1 = parse_reg(args[0], item)
        rs2 = parse_reg(args[1], item)
        return [encode_r(condition, 0, rs1, rs2, FUNCT["SUB"])]

    if op == "CMPI":
        # 即値比較疑似命令: SUBI r0, rs, imm8 (フラグのみ更新、結果はr0で破棄)
        if len(args) != 2:
            fail(item, "CMPI requires rs, immediate")
        rs = parse_reg(args[0], item)
        imm = checked(parse_int(args[1], labels, item), 8, "immediate", item)
        return [encode_i(condition, 0, rs, imm, FUNCT["SUB"])]

    if op == "TEST":
        # テスト疑似命令: AND r0, rs1, rs2 (フラグのみ更新、結果はr0で破棄)
        if len(args) != 2:
            fail(item, "TEST requires rs1, rs2")
        rs1 = parse_reg(args[0], item)
        rs2 = parse_reg(args[1], item)
        return [encode_r(condition, 0, rs1, rs2, FUNCT["AND"])]

    if op == "TESTI":
        # 即値テスト疑似命令: ANDI r0, rs, imm8 (フラグのみ更新、結果はr0で破棄)
        if len(args) != 2:
            fail(item, "TESTI requires rs, immediate")
        rs = parse_reg(args[0], item)
        imm = checked(parse_int(args[1], labels, item), 8, "immediate", item)
        return [encode_i(condition, 0, rs, imm, FUNCT["AND"])]

    if op in ALU_R:
        # SHR: 2オペランド (SHR rd, rs) または 1オペランド (SHR rd -> rd = rd >> 1)
        if op == "SHR":
            if len(args) == 1:
                rd = parse_dest(args[0], item)
                return [encode_r(condition, rd, rd, 0, FUNCT["SHR"])]
            elif len(args) == 2:
                rd = parse_dest(args[0], item)
                rs = parse_reg(args[1], item)
                return [encode_r(condition, rd, rs, 0, FUNCT["SHR"])]
            else:
                fail(item, f"{op} requires 'rd' or 'rd, rs'")

        # その他のALU_R (ADD, SUB, AND, OR, etc.)
        # 3オペランド形式: op rd, rs1, rs2
        # 2オペランド形式: op rd, rs2 (rd = rd op rs2)
        if len(args) == 3:
            rd = parse_dest(args[0], item)
            rs1 = parse_reg(args[1], item)
            rs2 = parse_reg(args[2], item)
            return [encode_r(condition, rd, rs1, rs2, FUNCT[op])]
        elif len(args) == 2:
            rd = parse_dest(args[0], item)
            rs2 = parse_reg(args[1], item)
            return [encode_r(condition, rd, rd, rs2, FUNCT[op])]
        else:
            fail(item, f"{op} requires 'rd, rs1, rs2' or 'rd, rs2'")

    if op in ALU_I:
        base_op = op[:-1]
        # 3オペランド形式: op rd, rs, imm8
        # 2オペランド形式: op rd, imm8 (rd = rd op imm8)
        if len(args) == 3:
            rd, rs = parse_dest(args[0], item), parse_reg(args[1], item)
            imm = checked(parse_int(args[2], labels, item), 8, "immediate", item)
            return [encode_i(condition, rd, rs, imm, FUNCT[base_op])]
        elif len(args) == 2:
            rd = parse_dest(args[0], item)
            imm = checked(parse_int(args[1], labels, item), 8, "immediate", item)
            return [encode_i(condition, rd, rd, imm, FUNCT[base_op])]
        else:
            fail(item, f"{op} requires 'rd, rs, immediate' or 'rd, immediate'")

    if op in {"LD", "ST"}:
        if len(args) != 2:
            fail(item, f"{op} requires register and memory operand")
        data_reg = parse_dest(args[0], item) if op == "LD" else parse_reg(args[0], item)
        base, offset, sign = parse_memory_operand(args[1], labels, item)
        offset = checked(offset, 9, "memory offset", item)
        mode = op + sign
        return [encode_ls(condition, data_reg, base, offset, LS_FUNCT[mode])]
    fail(item, f"unknown mnemonic '{item.kind}'")


def assemble(path: Path) -> tuple[dict[int, int], list[tuple[int, int, str]]]:
    items, labels = parse_source(path)
    words: dict[int, int] = {}
    listing: list[tuple[int, int, str]] = []
    for item in items:
        encoded = assemble_item(item, labels)
        for index, word in enumerate(encoded):
            address = item.address + index
            if address in words:
                fail(item, f"address overlap at 0x{address:04X}")
            words[address] = word
            listing.append((address, word, item.source))
    return words, listing


def assemble_line(source: str) -> list[int]:
    """Assemble one instruction entered at the interactive prompt."""
    source = source.split(";", 1)[0].split("#", 1)[0].strip()
    if not source:
        raise AssemblerError("instruction is empty")
    if ":" in source:
        raise AssemblerError("labels are not supported in interactive mode")
    parts = source.split(None, 1)
    op = parts[0].upper()
    operands = tuple(split_operands(parts[1]) if len(parts) == 2 else ())
    item = Item(0, source, 1, op, operands)
    return assemble_item(item, {})


def write_hex(words: dict[int, int], output: Path, depth: int | None) -> None:
    if not words:
        raise AssemblerError("source contains no output words")
    last = max(words) + 1
    size = depth or last
    if size < last:
        raise AssemblerError(f"output depth {size} is smaller than program end {last}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="ascii", newline="\n") as stream:
        for address in range(size):
            stream.write(f"{words.get(address, 0x800000):06X}\n")


def print_mnemonics() -> None:
    print("k16 ニーモニック一覧")
    print("条件サフィックス:", ", ".join(f".{suffix.lower()}" for suffix in CONDITION_SUFFIXES))
    for name, description in MNEMONICS:
        print(f"  {name:<6} {description}")


def interactive() -> int:
    print("k16 簡易アセンブラ")
    print("命令を1行入力すると、24-bit HEXを表示します。")
    print("例: ADD r1, r2, r3 / LI r1, 10 / LD r1, [r2 + 4]")
    print("命令一覧: python k16asm.py --list-mnemonics")
    print("終了するには空行を入力してください。")
    print()
    while True:
        try:
            source = input("k16> ")
        except EOFError:
            print()
            return 0
        if not source.strip():
            return 0
        try:
            for word in assemble_line(source):
                print(f"{word:06X}")
        except AssemblerError as exc:
            print(f"エラー: {exc}")


def print_mnemonics() -> None:
    print("k16 ニーモニック一覧")
    print("条件サフィックス: " + ", ".join(f".{suffix.lower()}" for suffix in CONDITION_SUFFIXES))
    print()
    for mnemonic, description in MNEMONICS:
        print(f"{mnemonic:<12} {description}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("-o", "--output", type=Path, default=Path("firmware.hex"))
    parser.add_argument("--depth", type=int, help="pad output to this many words")
    parser.add_argument("--listing", type=Path, help="write address, word, and source listing")
<<<<<<< HEAD
    parser.add_argument(
        "--list-mnemonics",
        action="store_true",
        help="print supported mnemonics and condition suffixes",
    )
    parser.add_argument(
        "--gui",
        action="store_true",
        help="launch interactive Tkinter GUI assembler",
    )
    args = parser.parse_args()
    if args.gui:
        try:
            import k16_studio
            k16_studio.main()
            return 0
        except ImportError:
            try:
                import sys
                script_root = Path(__file__).resolve().parent.parent.parent
                sys.path.insert(0, str(script_root))
                import k16_studio
                k16_studio.main()
                return 0
            except Exception as e:
                parser.error(f"failed to start GUI: {e}")

    if args.list_mnemonics:
        print_mnemonics()
        return 0

=======
    parser.add_argument("--list-mnemonics", action="store_true", help="show supported mnemonics")
    args = parser.parse_args()
    if args.list_mnemonics:
        print_mnemonics()
        return 0
>>>>>>> bf3719485c4b0f76c70152074a8499d4f52adacb
    if args.source is None:
        return interactive()
    try:
        words, listing = assemble(args.source)
        write_hex(words, args.output, args.depth)
        if args.listing:
            with args.listing.open("w", encoding="utf-8", newline="\n") as stream:
                for address, word, source in listing:
                    stream.write(f"{address:04X}  {word:06X}  {source}\n")
        print(f"assembled {len(words)} words -> {args.output}")
    except (AssemblerError, OSError, ValueError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
