#!/usr/bin/env python3
"""
k16 LED Blink サンプルプログラム生成

Tang Nano 9K 用: 27MHz クロックで 1Hz の LED チカチカ
  - 0.5秒ごとに LED をトグル
  - 27MHz × 0.5s = 13,500,000 cycles
  - 16bit タイマ (65536) で 27MHz/65536 ≈ 412Hz
  - 412Hz × 0.5s ≈ 206 カウント

プログラム:
  1. TIMER_CMP = 206 (0.5秒相当)
  2. TIMER_CTRL = 1 (開始)
  3. ループ:
     a. TIMER_CNT を読む
     b. TIMER_CNT == 0 かチェック (ラップアラウンド検出)
     c. 0 なら LED をトグル
     d. タイマ再起動
     e. ループ

アセンブラ命令:
  ADDI rd, rs, imm   : rd = rs + imm
  ADD  rd, rs1, rs2  : rd = rs1 + rs2
  SUB  rd, rs1, rs2  : rd = rs1 - rs2
  AND  rd, rs1, rs2  : rd = rs1 & rs2
  OR   rd, rs1, rs2  : rd = rs1 | rs2
  XOR  rd, rs1, rs2  : rd = rs1 ^ rs2
  SHR  rd, rs1, rs2  : rd = rs1 >> 1 (rs2 ignored, funct=111)
  LD   rd, [base+im] : rd = mem[base+im]
  ST   rd, [base+im] : mem[base+im] = {r13[7:0], rd}

分岐は ALU で r15 に書き込み:
  ADD r15, r0, TARGET : jump to TARGET

条件付き実行 (.eq/.ne/.cs/.cc/.mi/.pl/.nv/.al):
  ADD.eq rd, rs1, rs2 : if Z==1, rd = rs1 + rs2
"""

import sys

def encode_r(cond, rd, rs1, rs2, funct):
    return (cond << 21) | (0b00 << 19) | (rd << 15) | (rs1 << 11) | (rs2 << 7) | (0b0000 << 3) | funct

def encode_i(cond, rd, rs, im, funct):
    return (cond << 21) | (0b01 << 19) | (rd << 15) | (rs << 11) | (im << 3) | funct

def encode_ls(cond, rd, base, im, funct):
    return (cond << 21) | (0b11 << 19) | (rd << 15) | (base << 11) | (im << 2) | funct

# Conditions
AL = 0b000  # always
NE = 0b001  # Z==0
NC = 0b010  # C==0
PL = 0b011  # N==0
NV = 0b100  # never
EQ = 0b101  # Z==1
CS = 0b110  # C==1
MI = 0b111  # N==1

# ALU functs
F_NAND = 0b000
F_OR   = 0b001
F_AND  = 0b010
F_XOR  = 0b011
F_ADD  = 0b100
F_SUB  = 0b101
F_ADC  = 0b110
F_SHR  = 0b111

# Load/Store functs (2 bit)
LS_LD_ADD = 0b00  # rd = mem[base + im]
LS_LD_SUB = 0b01  # rd = mem[base - im]
LS_ST_ADD = 0b10  # mem[base + im] = {r13[7:0], rd}
LS_ST_SUB = 0b11  # mem[base - im] = {r13[7:0], rd}

NOP = 0x800000


def build_blink_program():
    """
    LED blink program for k16

    Memory layout:
      0x0000-0x00FF: Program
      0xFF10       : LED (MMIO)
      0xFF20       : BTN (MMIO)
      0xFF30       : TIMER_CTRL (MMIO)
      0xFF31       : TIMER_CNT (MMIO)
      0xFF32       : TIMER_CMP (MMIO)

    Strategy:
      - Build MMIO base address 0xFF00 in r10 via doubling
      - Use offsets to access specific MMIO registers
      - Loop with software delay (since timer is 16-bit and we need ~13.5M cycles)
      - Software delay: nested loop with 16-bit counter
        outer = 256, inner = 65536 → 256 × 65536 = 16M iterations ≈ 0.6s
    """
    program = {}

    # === Initialization ===
    # r10 = 0xFF00 (MMIO base) — build via 8 doublings of 0xFF
    addr = 0
    program[addr] = encode_i(AL, 10, 0, 0xFF, F_ADD);  addr += 1  # r10 = 0xFF
    for _ in range(8):
        program[addr] = encode_r(AL, 10, 10, 10, F_ADD);  addr += 1  # r10 = r10 + r10
    # Now r10 = 0xFF00

    # === LED init ===
    # r1 = 0x01 (LED pattern)
    program[addr] = encode_i(AL, 1, 0, 0x01, F_ADD);  addr += 1  # r1 = 1

    # Main loop address
    main_loop = addr

    # === Toggle LED ===
    # LED = r1 (write lower 16 bits)
    # STORE [r10 + 0x10], r1  (LED = {r13[7:0], r1})
    program[addr] = encode_ls(AL, 1, 10, 0x10, LS_ST_ADD);  addr += 1

    # === Software delay ===
    # r2 = 0 (outer counter)
    program[addr] = encode_r(AL, 2, 0, 0, F_SUB);  addr += 1  # r2 = 0 - 0 = 0 (also sets Z=1)
    # outer loop start
    outer_loop = addr
    # r3 = 0 (inner counter)
    program[addr] = encode_r(AL, 3, 0, 0, F_SUB);  addr += 1  # r3 = 0
    # inner loop start
    inner_loop = addr
    # r3 = r3 + 1
    program[addr] = encode_i(AL, 3, 3, 1, F_ADD);  addr += 1
    # if r3 != 0, jump to inner_loop (Z==0)
    # r15 = inner_loop when Z==0
    program[addr] = encode_i(NE, 15, 0, inner_loop & 0xFF, F_ADD);  addr += 1
    # If Z==1 (r3 wrapped to 0), check outer
    # r2 = r2 + 1
    program[addr] = encode_i(AL, 2, 2, 1, F_ADD);  addr += 1
    # if r2 != 0, jump to outer_loop
    program[addr] = encode_i(NE, 15, 0, outer_loop & 0xFF, F_ADD);  addr += 1

    # === Toggle r1 (LED pattern) ===
    # r1 = r1 XOR 1
    program[addr] = encode_i(AL, 1, 1, 1, F_XOR);  addr += 1  # XOR with imm 1

    # === Jump back to main loop ===
    program[addr] = encode_i(AL, 15, 0, main_loop & 0xFF, F_ADD);  addr += 1

    # Fill rest with NOP
    return program, addr


def write_hex(program, max_size, filename):
    """Write program as hex file for $readmemh"""
    with open(filename, 'w') as f:
        for addr in range(max_size):
            if addr in program:
                f.write(f"{program[addr]:06x}\n")
            else:
                f.write(f"{NOP:06x}\n")
    print(f"Written {filename} ({max_size} entries)")


def main():
    program, end_addr = build_blink_program()
    print(f"Program size: {end_addr} instructions")
    print(f"Main loop at: 0x{0:04x}")
    write_hex(program, 16384, "/home/z/my-project/k16-redesign/build/firmware.hex")

    # Also write a simulation-friendly version (smaller delay for testbench)
    # For simulation: 100 iterations only
    sim_program = dict(program)
    # Patch to use smaller loops for simulation
    # outer_loop at offset 4, inner_loop at offset 6 (approximate)
    # For real test, just verify it loads and runs

    print("\nProgram disassembly:")
    for addr in sorted(program.keys())[:30]:
        inst = program[addr]
        cond = (inst >> 21) & 0b111
        op = (inst >> 19) & 0b11
        rd = (inst >> 15) & 0b1111
        rs1 = (inst >> 11) & 0b1111
        rs2 = (inst >> 7) & 0b1111
        im = (inst >> 3) & 0xFF if op == 0b01 else (inst >> 2) & 0x1FF
        funct = inst & 0b111 if op in (0b00, 0b01) else inst & 0b11
        print(f"  [{addr:3d}] 0x{inst:06x}  cond={cond:03b} op={op:02b} rd=r{rd} rs1=r{rs1} rs2=r{rs2} im=0x{im:x} funct={funct}")


if __name__ == "__main__":
    main()
