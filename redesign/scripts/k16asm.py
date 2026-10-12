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
    register = parse_reg(token, item)
    if register in {0, 14}:
        fail(item, f"r{register} cannot be written")
    return register


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
            encode_i(condition, 12, 15, 2, FUNCT["ADD"]),
            encode_i(condition, 15, 0, target, FUNCT["ADD"]),
        ]
    if op == "RET":
        return [encode_r(condition, 15, 12, 0, FUNCT["ADD"])]

    if op in ALU_R:
        expected = 2 if op == "SHR" else 3
        if len(args) != expected:
            fail(item, f"{op} requires {'rd, rs' if op == 'SHR' else 'rd, rs1, rs2'}")
        rd = parse_dest(args[0], item)
        rs1 = parse_reg(args[1], item)
        rs2 = 0 if op == "SHR" else parse_reg(args[2], item)
        return [encode_r(condition, rd, rs1, rs2, FUNCT[op])]
    if op in ALU_I:
        base_op = op[:-1]
        if len(args) != 3:
            fail(item, f"{op} requires rd, rs, immediate")
        rd, rs = parse_dest(args[0], item), parse_reg(args[1], item)
        imm = checked(parse_int(args[2], labels, item), 8, "immediate", item)
        return [encode_i(condition, rd, rs, imm, FUNCT[base_op])]
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


def interactive() -> int:
    print("k16 簡易アセンブラ")
    print("命令を1行入力すると、24-bit HEXを表示します。")
    print("例: ADD r1, r2, r3 / LI r1, 10 / LD r1, [r2 + 4]")
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("-o", "--output", type=Path, default=Path("firmware.hex"))
    parser.add_argument("--depth", type=int, help="pad output to this many words")
    parser.add_argument("--listing", type=Path, help="write address, word, and source listing")
    args = parser.parse_args()
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
