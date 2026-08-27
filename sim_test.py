#!/usr/bin/env python3
"""
k16 16bit RISC CPU サイクル精度シミュレータ & テスト検証スクリプト (ノイマン型)
Verilog (cpu.v, alu.v, regfile.v, decoder.v, cond_check.v, ram.v) のロジックと
1対1で対応するサイクル精度モデルによりCPU動作を自動検証します。

このCPUは命令メモリとデータメモリを分離しない単一アドレス空間・単一ポートの
共有メモリ(mem_addr/mem_wdata/mem_rdata/mem_we)を採用したノイマン型です。
そのため、条件成立したLoad/Store命令の実行サイクルでは、そのサイクルの
メモリバスがデータアクセスに占有され、次命令のフェッチが行えません。
このシミュレータは、その際に発生する1サイクルのバブル(構造的ハザード
ストール)と、PCが進まず次サイクルに正しく再フェッチされる挙動を
Verilog実装と完全に一致するかたちで再現します。
"""

import sys

class ALU:
    def __init__(self):
        self.Z = 0
        self.C = 0
        self.N = 0

    def compute(self, A, B, funct):
        A = A & 0xFFFF
        B = B & 0xFFFF
        temp = 0
        result = 0

        if funct == 0b000: # NAND
            result = (~(A & B)) & 0xFFFF
        elif funct == 0b001: # OR
            result = (A | B) & 0xFFFF
        elif funct == 0b010: # AND
            result = (A & B) & 0xFFFF
        elif funct == 0b011: # XOR
            result = (A ^ B) & 0xFFFF
        elif funct == 0b100: # ADD
            temp = A + B
            result = temp & 0xFFFF
        elif funct == 0b101: # SUB
            # A + ~B + 1
            temp = A + ((~B) & 0xFFFF) + 1
            result = temp & 0xFFFF
        elif funct == 0b110: # ADC
            temp = A + B + self.C
            result = temp & 0xFFFF
        elif funct == 0b111: # SHR (1bit右シフト)
            result = (A >> 1) & 0xFFFF
            temp = A & 1 # 押し出されたbit
        else:
            result = 0

        return result, temp

    def update_flags(self, funct, result, temp, A):
        self.Z = 1 if (result == 0) else 0
        self.N = 1 if (result & 0x8000) else 0
        if funct in (0b100, 0b101, 0b110):
            self.C = 1 if (temp > 0xFFFF) else 0
        elif funct == 0b111:
            self.C = A & 1
        # 論理演算ではC保持

class RegFile:
    def __init__(self):
        self.regs = [0] * 16

    def read_a(self, addr, zf, cf, nf):
        if addr == 0:
            return 0
        elif addr == 14:
            return (nf << 2) | (cf << 1) | zf
        return self.regs[addr]

    def read_b(self, addr, zf, cf, nf):
        if addr == 0:
            return 0
        elif addr == 14:
            return (nf << 2) | (cf << 1) | zf
        return self.regs[addr]

    def write(self, wtenable, wtaddr, wtdata, topenable, topin, pc_hold):
        if wtenable and wtaddr != 0 and wtaddr != 14:
            if not (topenable and wtaddr == 13):
                self.regs[wtaddr] = wtdata & 0xFFFF
        if topenable:
            self.regs[13] = (self.regs[13] & 0xFF00) | (topin & 0xFF)
        if not (wtenable and wtaddr == 15):
            # ノイマン型: 単一バスがデータアクセスに使われフェッチできなかった
            # サイクル(pc_hold)はPCを保持し、次サイクルに再フェッチさせる
            if not pc_hold:
                self.regs[15] = (self.regs[15] + 1) & 0xFFFF

def check_cond(cond, zf, cf, nf):
    if cond == 0b000: return True
    if cond == 0b001: return (zf == 0)
    if cond == 0b010: return (cf == 0)
    if cond == 0b011: return (nf == 0)
    if cond == 0b100: return False
    if cond == 0b101: return (zf == 1)
    if cond == 0b110: return (cf == 1)
    if cond == 0b111: return (nf == 1)
    return False

def decode(inst):
    cond = (inst >> 21) & 0x7
    op   = (inst >> 19) & 0x3
    rd   = (inst >> 15) & 0xF
    rs1  = (inst >> 11) & 0xF
    
    is_alu_reg = (op == 0b00)
    is_alu_imm = (op == 0b01)
    is_load    = (op == 0b11) and (((inst >> 1) & 1) == 0)
    is_store   = (op == 0b11) and (((inst >> 1) & 1) == 1)
    
    rs2 = rd if is_store else ((inst >> 7) & 0xF)
    alu_src_imm = is_alu_imm or (op == 0b11)
    reg_write = is_alu_reg or is_alu_imm or is_load
    flag_write = is_alu_reg or is_alu_imm

    imm = 0
    if op == 0b01:
        imm = (inst >> 3) & 0xFF
    elif op == 0b11:
        imm = (inst >> 2) & 0x1FF

    alu_funct = 0
    if op in (0b00, 0b01):
        alu_funct = inst & 0x7
    elif op == 0b11:
        alu_funct = 0b100 if ((inst & 1) == 0) else 0b101

    return {
        'cond': cond, 'op': op, 'rd': rd, 'rs1': rs1, 'rs2': rs2,
        'imm': imm, 'alu_funct': alu_funct,
        'is_alu_reg': is_alu_reg, 'is_alu_imm': is_alu_imm,
        'is_load': is_load, 'is_store': is_store,
        'alu_src_imm': alu_src_imm,
        'reg_write': reg_write, 'flag_write': flag_write
    }

NOP_INST = 0x800000  # cond=Never(100), op=00, 残り0

class CPU:
    def __init__(self, mem):
        self.mem = mem
        self.alu = ALU()
        self.rf = RegFile()
        self.ir = NOP_INST
        self.prev_wtaddr = 0
        self.prev_wtdata = 0
        self.prev_wtenable = False

    def step(self):
        # Stage 2: Decode & Execute current IR
        d = decode(self.ir)
        cond_match = check_cond(d['cond'], self.alu.Z, self.alu.C, self.alu.N)

        rddata_a = self.rf.read_a(d['rs1'], self.alu.Z, self.alu.C, self.alu.N)
        rddata_b = self.rf.read_b(d['rs2'], self.alu.Z, self.alu.C, self.alu.N)

        # フォワーディング
        fwd_a = self.prev_wtdata if (self.prev_wtenable and self.prev_wtaddr == d['rs1']) else rddata_a
        fwd_b = self.prev_wtdata if (self.prev_wtenable and self.prev_wtaddr == d['rs2']) else rddata_b

        alu_in_a = fwd_a
        alu_in_b = d['imm'] if d['alu_src_imm'] else fwd_b

        alu_res, temp = self.alu.compute(alu_in_a, alu_in_b, d['alu_funct'])

        #==================================================
        # ノイマン型: 単一メモリバスの調停
        # 条件成立したLoad/Store命令のサイクルはデータアクセスを
        # 優先し、そのサイクルの命令フェッチはスキップされる。
        #==================================================
        is_mem_access = cond_match and (d['is_load'] or d['is_store'])

        pc = self.rf.regs[15]
        shared_addr = alu_res if is_mem_access else pc  # 共有アドレスバス

        topout = self.rf.regs[13] & 0xFF
        mem_wdata = (topout << 16) | (fwd_b & 0xFFFF)
        mem_we = cond_match and d['is_store']

        if mem_we:
            self.mem[shared_addr] = mem_wdata

        # フェッチ時、未初期化領域はNOP扱い。データアクセス時は0扱い。
        default_val = 0 if is_mem_access else NOP_INST
        shared_rdata = self.mem.get(shared_addr, default_val)

        topin = (shared_rdata >> 16) & 0xFF

        wtaddr = d['rd']
        wtdata = (shared_rdata & 0xFFFF) if d['is_load'] else alu_res
        wtenable = cond_match and d['reg_write']
        topenable = cond_match and d['is_load']
        flag_en = cond_match and d['flag_write']

        # クロック立ち上がり更新: フラグ更新
        if flag_en:
            self.alu.update_flags(d['alu_funct'], alu_res, temp, alu_in_a)

        # レジスタファイル更新 (PC hold込み)
        self.rf.write(wtenable, wtaddr, wtdata, topenable, topin, pc_hold=is_mem_access)

        # パイプラインレジスタ (IR) 更新
        if is_mem_access:
            # 単一バスをデータアクセスに使用したためフェッチ不可 -> バブル挿入
            self.ir = NOP_INST
        elif wtenable and wtaddr == 15:
            # 分岐成立: パイプラインフラッシュ
            self.ir = NOP_INST
        else:
            # 通常フェッチ (shared_addr == pc)
            self.ir = shared_rdata

        # フォワーディング用レジスタ更新
        self.prev_wtaddr = wtaddr
        self.prev_wtdata = wtdata
        self.prev_wtenable = wtenable and (wtaddr != 0) and (wtaddr != 14)


def encode_r(cond, rd, rs1, rs2, funkt):
    return (cond << 21) | (0b00 << 19) | (rd << 15) | (rs1 << 11) | (rs2 << 7) | (0 << 3) | funkt

def encode_i(cond, rd, rs, im, funkt):
    return (cond << 21) | (0b01 << 19) | (rd << 15) | (rs << 11) | ((im & 0xFF) << 3) | funkt

def encode_ls(cond, rd, base, im, funkt):
    return (cond << 21) | (0b11 << 19) | (rd << 15) | (base << 11) | ((im & 0x1FF) << 2) | funkt

def run_tests():
    mem = {}
    
    # 0: r1 = r0 + 10 (ADDI r1, r0, 10)
    mem[0]  = encode_i(0b000, 1, 0, 10, 0b100)
    # 1: r2 = r0 + 5  (ADDI r2, r0, 5)
    mem[1]  = encode_i(0b000, 2, 0, 5, 0b100)
    # 2: r3 = r1 + r2 (ADD r3, r1, r2) -> 15
    mem[2]  = encode_r(0b000, 3, 1, 2, 0b100)
    # 3: r4 = r1 - r2 (SUB r4, r1, r2) -> 5
    mem[3]  = encode_r(0b000, 4, 1, 2, 0b101)
    # 4: r5 = r1 & r2 (AND r5, r1, r2) -> 0
    mem[4]  = encode_r(0b000, 5, 1, 2, 0b010)
    # 5: r6 = r1 | r2 (OR  r6, r1, r2) -> 15
    mem[5]  = encode_r(0b000, 6, 1, 2, 0b001)
    # 6: r7 = r1 ^ r2 (XOR r7, r1, r2) -> 15
    mem[6]  = encode_r(0b000, 7, 1, 2, 0b011)
    # 7: r8 = r1 >> 1 (SHR r8, r1)     -> 5
    mem[7]  = encode_r(0b000, 8, 1, 0, 0b111)
    # 8: r9 = r1 - r1 (SUB r9, r1, r1) -> 0, Z=1
    mem[8]  = encode_r(0b000, 9, 1, 1, 0b101)
    # 9: 条件付き実行: if (Z==0) r11 = r0 + 88 (不成立 -> スキップ)
    mem[9]  = encode_i(0b001, 11, 0, 88, 0b100)
    # 10: 条件付き実行: if (Z==1) r10 = r0 + 77 (成立 -> 実行)
    mem[10] = encode_i(0b101, 10, 0, 77, 0b100)
    # 11: r13の上位バイト設定: r13 = r0 + 0x5A
    mem[11] = encode_i(0b000, 13, 0, 0x5A, 0b100)
    # 12: Store: mem[r1 + 2] <= {r13[7:0], r3} = {8'h5A, 16'd15}
    mem[12] = encode_ls(0b000, 3, 1, 2, 0b10)
    # 13: Load: r12 <= mem[r1 + 2]
    mem[13] = encode_ls(0b000, 12, 1, 2, 0b00)
    # 14: ジャンプ: r15 = r0 + 20 (アドレス20へ分岐)
    mem[14] = encode_i(0b000, 15, 0, 20, 0b100)
    # 15: スキップされる命令: r12 = r0 + 99
    mem[15] = encode_i(0b000, 12, 0, 99, 0b100)

    # 20: 分岐先: r1 = r1 + 1 (10 + 1 = 11)
    mem[20] = encode_i(0b000, 1, 1, 1, 0b100)
    # 21: NANDテスト: r2 = ~(r1 & r1) -> ~11
    mem[21] = encode_r(0b000, 2, 1, 1, 0b000)
    # 22: 負数・Nフラグテスト: r4 = 0 - 50 (SUB r4, r0, 50) -> -50, N=1
    mem[22] = encode_i(0b000, 4, 0, 50, 0b101)
    # 23: N==0条件テスト (不成立 -> スキップ): if (N==0) r6 = r0 + 200
    mem[23] = encode_i(0b011, 6, 0, 200, 0b100)
    # 24: N==1条件テスト (成立 -> 実行): if (N==1) r5 = r0 + 123
    mem[24] = encode_i(0b111, 5, 0, 123, 0b100)
    # 25: 減算オフセットStoreテスト: mem[r1 - 1] (アドレス10) <= {8'h77, 16'd99}
    mem[25] = encode_i(0b000, 13, 0, 0x77, 0b100)
    mem[26] = encode_i(0b000, 7, 0, 99, 0b100)
    # Store: mem[r1 - 1] = {r13, r7}
    mem[27] = encode_ls(0b000, 7, 1, 1, 0b11)
    # 28: 減算オフセットLoadテスト: r8 <= mem[r1 - 1]
    mem[28] = encode_ls(0b000, 8, 1, 1, 0b01)

    cpu = CPU(mem)

    # ノイマン型化により、条件成立したLoad/Store命令1つにつき
    # 単一バス調停で1サイクルのストールが追加されるため、
    # ハーバード型時代(45サイクル)より多めに実行して確実に完了させる。
    for cycle in range(60):
        cpu.step()

    print("=== k16 CPU シミュレーション検証結果 (ノイマン型) ===")
    errors = 0

    checks = [
        ("r1 (分岐先実行 ADD 10+1)", cpu.rf.regs[1], 11),
        ("r2 (NAND ~11)", cpu.rf.regs[2], (~11) & 0xFFFF),
        ("r3 (ADD 10+5)", cpu.rf.regs[3], 15),
        ("r4 (SUB 0-50 -> -50, N=1)", cpu.rf.regs[4], (-50) & 0xFFFF),
        ("r5 (N==1条件成立実行 -> 123)", cpu.rf.regs[5], 123),
        ("r6 (N==0条件不成立スキップ 200にならず15を維持)", cpu.rf.regs[6], 15),
        ("r8 (減算Load & SHR検証 -> 99)", cpu.rf.regs[8], 99),
        ("r10 (条件成立実行 Z==1 -> 77)", cpu.rf.regs[10], 77),
        ("r11 (条件不成立スキップ Z==0 -> 0)", cpu.rf.regs[11], 0),
        ("r12 (Load & 分岐フラッシュ成功 -> 15)", cpu.rf.regs[12], 15),
        ("mem[12] (Store {0x5A, 15} -> 0x5A000F)", mem.get(12, 0), 0x5A000F),
        ("mem[10] (減算Store {0x77, 99} -> 0x770063)", mem.get(10, 0), (0x77 << 16) | 99),
        ("r13[7:0] (減算Load時上位8bit -> 0x77)", cpu.rf.regs[13] & 0xFF, 0x77)
    ]

    for name, actual, expected in checks:
        if actual == expected:
            print(f"[PASS] {name}: {actual} (期待値: {expected})")
        else:
            print(f"[FAIL] {name}: {actual} (期待値: {expected})")
            errors += 1

    if errors == 0:
        print("\n>>> 全てのテストに合格しました！ (ALL TESTS PASSED) <<<")
    else:
        print(f"\n>>> {errors} 件のエラーが発生しました。 <<<")
        sys.exit(1)

if __name__ == "__main__":
    run_tests()
