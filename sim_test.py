#!/usr/bin/env python3
"""
k16 16bit RISC CPU サイクル精度シミュレータ & テスト検証スクリプト (ノイマン型 + MMIO UART IO)
Verilog (cpu.v, alu.v, regfile.v, decoder.v, cond_check.v, ram.v, mmio.v, uart.v, k16_soc.v) の
論理と1対1で対応するサイクル精度モデルによりCPU動作、特殊レジスタ、およびMMIO(UART IO)動作を自動検証します。
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

class UARTModel:
    def __init__(self, clks_per_bit=10):
        self.clks_per_bit = clks_per_bit
        self.tx_busy = 0
        self.tx_counter = 0
        self.tx_history = []
        self.rx_data = 0
        self.rx_ready = 0

    def start_tx(self, byte_val):
        if not self.tx_busy:
            self.tx_busy = 1
            self.tx_counter = 10 * self.clks_per_bit
            self.tx_history.append(byte_val & 0xFF)

    def inject_rx(self, byte_val):
        self.rx_data = byte_val & 0xFF
        self.rx_ready = 1

    def step(self):
        if self.tx_busy:
            self.tx_counter -= 1
            if self.tx_counter <= 0:
                self.tx_busy = 0

class MMIOModel:
    def __init__(self, uart: UARTModel):
        self.uart = uart
        self.rdata_q = 0

    def step_read(self, addr, we):
        addr = addr & 0xFFFF
        if addr == 0xFF00: # UART_DATA
            self.rdata_q = self.uart.rx_data
            if not we:
                self.uart.rx_ready = 0
        elif addr == 0xFF01: # UART_STATUS
            self.rdata_q = (self.uart.rx_ready << 1) | self.uart.tx_busy
        else:
            self.rdata_q = 0

    def write(self, addr, wdata):
        addr = addr & 0xFFFF
        if addr == 0xFF00: # UART_DATA
            self.uart.start_tx(wdata & 0xFF)

class SystemSoC:
    def __init__(self, mem, clks_per_bit=10):
        self.mem = mem
        self.uart = UARTModel(clks_per_bit=clks_per_bit)
        self.mmio = MMIOModel(self.uart)
        self.alu = ALU()
        self.rf = RegFile()
        self.ir = NOP_INST
        self.prev_wtaddr = 0
        self.prev_wtdata = 0
        self.prev_wtenable = False

        # 同期BRAM / 同期MMIO 1サイクル遅延用レジスタ
        self.load_active_q = False
        self.load_rd_q = 0
        self.is_mmio_q = False
        self.ram_rdata_q = NOP_INST

    def step(self):
        d = decode(self.ir)
        cond_match = check_cond(d['cond'], self.alu.Z, self.alu.C, self.alu.N)

        rddata_a = self.rf.read_a(d['rs1'], self.alu.Z, self.alu.C, self.alu.N)
        rddata_b = self.rf.read_b(d['rs2'], self.alu.Z, self.alu.C, self.alu.N)

        # BRAM 1サイクル遅延メモリ読み出しデータ判定
        mem_rdata = self.mmio.rdata_q if self.is_mmio_q else self.ram_rdata_q

        wtdata_now = (mem_rdata & 0xFFFF) if self.load_active_q else 0

        # フォワーディング (r0, r14はバイパス対象外)
        fwd_r13_a = (self.rf.regs[13] & 0xFF00) | ((mem_rdata >> 16) & 0xFF) if self.load_active_q else rddata_a
        fwd_r13_b = (self.rf.regs[13] & 0xFF00) | ((mem_rdata >> 16) & 0xFF) if self.load_active_q else rddata_b

        if self.load_active_q and (self.load_rd_q == d['rs1']) and (d['rs1'] not in (0, 14)):
            fwd_a = wtdata_now
        elif self.load_active_q and (d['rs1'] == 13):
            fwd_a = fwd_r13_a
        elif self.prev_wtenable and (self.prev_wtaddr == d['rs1']):
            fwd_a = self.prev_wtdata
        else:
            fwd_a = rddata_a

        if self.load_active_q and (self.load_rd_q == d['rs2']) and (d['rs2'] not in (0, 14)):
            fwd_b = wtdata_now
        elif self.load_active_q and (d['rs2'] == 13):
            fwd_b = fwd_r13_b
        elif self.prev_wtenable and (self.prev_wtaddr == d['rs2']):
            fwd_b = self.prev_wtdata
        else:
            fwd_b = rddata_b

        alu_in_a = fwd_a
        alu_in_b = d['imm'] if d['alu_src_imm'] else fwd_b

        alu_res, temp = self.alu.compute(alu_in_a, alu_in_b, d['alu_funct'])

        is_mem_access = cond_match and (d['is_load'] or d['is_store'])

        pc = self.rf.regs[15]
        shared_addr = (alu_res & 0xFFFF) if is_mem_access else pc

        topout = self.rf.regs[13] & 0xFF
        mem_wdata = (topout << 16) | (fwd_b & 0xFFFF)
        mem_we = cond_match and d['is_store']

        is_mmio_addr = (shared_addr >= 0xFF00)

        # メモリ / MMIO 書き込み & 次サイクル用同期読み出し更新
        if mem_we:
            if is_mmio_addr:
                self.mmio.write(shared_addr, mem_wdata)
            else:
                self.mem[shared_addr] = mem_wdata

        self.mmio.step_read(shared_addr, mem_we)
        default_val = 0 if is_mem_access else NOP_INST
        next_ram_rdata = self.mem.get(shared_addr, default_val)

        # 今サイクルでのレジスタ書き込み決定 (Load遅延書き戻し vs 通常演算)
        if self.load_active_q:
            wtaddr = self.load_rd_q
            wtdata = mem_rdata & 0xFFFF
            wtenable = True
            topenable = True
            topin = (mem_rdata >> 16) & 0xFF
        else:
            wtaddr = d['rd']
            wtdata = alu_res
            wtenable = cond_match and (d['is_alu_reg'] or d['is_alu_imm'])
            topenable = False
            topin = 0

        flag_en = cond_match and d['flag_write']
        if flag_en:
            self.alu.update_flags(d['alu_funct'], alu_res, temp, alu_in_a)

        self.rf.write(wtenable, wtaddr, wtdata, topenable, topin, pc_hold=is_mem_access)

        # フェッチ命令更新
        if is_mem_access:
            self.ir = NOP_INST
        elif wtenable and wtaddr == 15:
            self.ir = NOP_INST
        else:
            self.ir = mem_rdata

        # 履歴・同期遅延状態の更新
        self.prev_wtaddr = wtaddr
        self.prev_wtdata = wtdata
        self.prev_wtenable = wtenable and (wtaddr != 0) and (wtaddr != 14)

        self.load_active_q = cond_match and d['is_load']
        self.load_rd_q = d['rd']
        self.is_mmio_q = is_mmio_addr
        self.ram_rdata_q = next_ram_rdata

        self.uart.step()


def encode_r(cond, rd, rs1, rs2, funkt):
    return (cond << 21) | (0b00 << 19) | (rd << 15) | (rs1 << 11) | (rs2 << 7) | (0 << 3) | funkt

def encode_i(cond, rd, rs, im, funkt):
    return (cond << 21) | (0b01 << 19) | (rd << 15) | (rs << 11) | ((im & 0xFF) << 3) | funkt

def encode_ls(cond, rd, base, im, funkt):
    return (cond << 21) | (0b11 << 19) | (rd << 15) | (base << 11) | ((im & 0x1FF) << 2) | funkt


def run_tests():
    mem = {}

    # テストプログラムの配置
    mem[0]  = encode_i(0b000, 1, 0, 10, 0b100)
    mem[1]  = encode_i(0b000, 2, 0, 5, 0b100)
    mem[2]  = encode_r(0b000, 3, 1, 2, 0b100)
    mem[3]  = encode_r(0b000, 4, 1, 2, 0b101)
    mem[4]  = encode_r(0b000, 5, 1, 2, 0b010)
    mem[5]  = encode_r(0b000, 6, 1, 2, 0b001)
    mem[6]  = encode_r(0b000, 7, 1, 2, 0b011)
    mem[7]  = encode_r(0b000, 8, 1, 0, 0b111)
    mem[8]  = encode_r(0b000, 9, 1, 1, 0b101)
    mem[9]  = encode_i(0b001, 11, 0, 88, 0b100)
    mem[10] = encode_i(0b101, 10, 0, 77, 0b100)
    mem[11] = encode_i(0b000, 13, 0, 0x5A, 0b100)
    mem[12] = encode_ls(0b000, 3, 1, 2, 0b10)
    mem[13] = encode_ls(0b000, 12, 1, 2, 0b00)
    mem[14] = encode_i(0b000, 15, 0, 20, 0b100)
    mem[15] = encode_i(0b000, 12, 0, 99, 0b100)

    mem[20] = encode_i(0b000, 1, 1, 1, 0b100)
    mem[21] = encode_r(0b000, 2, 1, 1, 0b000)
    mem[22] = encode_i(0b000, 4, 0, 50, 0b101)
    mem[23] = encode_i(0b011, 6, 0, 200, 0b100)
    mem[24] = encode_i(0b111, 5, 0, 123, 0b100)
    mem[25] = encode_i(0b000, 13, 0, 0x77, 0b100)
    mem[26] = encode_i(0b000, 7, 0, 99, 0b100)
    mem[27] = encode_ls(0b000, 7, 1, 1, 0b11)
    mem[28] = encode_ls(0b000, 8, 1, 1, 0b01)
    mem[29] = encode_r(0b000, 3, 13, 0, 0b100)

    mem[30] = encode_r(0b000, 9, 0, 0, 0b000)
    mem[31] = encode_i(0b000, 9, 9, 255, 0b101)

    mem[32] = encode_ls(0b000, 11, 9, 1, 0b00)
    mem[33] = encode_i(0b000, 7, 0, 0x4B, 0b100)
    mem[34] = encode_ls(0b000, 7, 9, 0, 0b10)
    mem[35] = encode_ls(0b000, 10, 9, 1, 0b00)

    mem[36] = encode_ls(0b000, 12, 9, 1, 0b00)
    mem[37] = encode_i(0b000, 12, 12, 2, 0b010)
    mem[38] = encode_i(0b101, 15, 0, 36, 0b100)
    mem[39] = encode_ls(0b000, 6, 9, 0, 0b00)

    mem[40] = encode_i(0b000, 0, 0, 55, 0b100)
    mem[41] = encode_r(0b000, 2, 0, 0, 0b100)
    mem[42] = encode_r(0b000, 11, 14, 0, 0b100)
    mem[43] = encode_i(0b000, 14, 0, 255, 0b100)
    mem[44] = encode_r(0b000, 5, 14, 0, 0b100)
    mem[45] = encode_r(0b000, 8, 15, 0, 0b100)

    soc = SystemSoC(mem, clks_per_bit=10)

    for cycle in range(120):
        soc.step()
        if cycle == 50:
            soc.uart.inject_rx(0x5A)

    print("=== k16 CPU シミュレーション検証結果 (同期BRAM/MMIOモデル) ===")
    errors = 0

    checks = [
        ("r1 (分岐先実行 ADD 10+1)", soc.rf.regs[1], 11),
        ("r4 (SUB 0-50 -> -50, N=1)", soc.rf.regs[4], (-50) & 0xFFFF),
        ("mem[12] (Store {0x5A, 15} -> 0x5A000F)", mem.get(12, 0), 0x5A000F),
        ("mem[10] (減算Store {0x77, 99} -> 0x770063)", mem.get(10, 0), (0x77 << 16) | 99),
        ("r3 (減算Load時上位8bit r13退避値 -> 0x77)", soc.rf.regs[3] & 0xFF, 0x77),
        ("UART送信中ステータス (r10 == 1, tx_busy=1)", soc.rf.regs[10] & 1, 1),
        ("UART送信バッファ (TXに 'K'=0x4B が送信されたか)", soc.uart.tx_history, [0x4B]),
        ("UART受信データ (r6 == 0x5A 'Z')", soc.rf.regs[6], 0x5A),
        ("特殊レジスタ r0 (書き込み無視 & 常に0)", soc.rf.regs[0], 0),
        ("特殊レジスタ r14 (フラグ直読み)", soc.rf.regs[11], 1),
        ("特殊レジスタ r14 (書き込み無視 255不格納)", soc.rf.regs[5], 0),
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
