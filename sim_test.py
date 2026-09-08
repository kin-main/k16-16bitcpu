#!/usr/bin/env python3
"""
k16 16bit RISC CPU サイクル精度シミュレータ & テスト検証スクリプト (ノイマン型 + MMIO UART IO)
Verilog (cpu.v, alu.v, regfile.v, decoder.v, cond_check.v, ram.v, mmio.v, uart.v, k16_soc.v) の
RTLをレジスタ転送レベルで1対1に模倣したサイクル精度モデルにより、CPU動作、特殊レジスタ、
およびMMIO(UART IO)動作を自動検証します。

【モデル化方針】
- cpu.v が持つレジスタ一式 (if_id_ir / id_ex_* / load_active_q / data_access_q /
  pend_inst / branch_flush_q / prev_wt* / regfile / ALUフラグ) をそのまま保持し、
  1ステップ = 「組み合わせ評価 → 全レジスタ同時更新」でRTLのクロックエッジを再現する。
- ram.v / mmio.v の同期 (1サイクル遅延) 読み出し、mmio の tx_start/tx_hold/rx_clear
  登録パルス、uart.v の TX FSM と tx_busy=(state!=IDLE)|tx_start も模倣する。
"""

import sys

NOP_INST = 0x800000  # cond=Never(100), op=00, 残り0


# ================================================================
# ALU / レジスタファイル / デコード (alu.v / regfile.v / decoder.v 対応)
# ================================================================

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


# ================================================================
# UART / MMIO モデル (uart.v / mmio.v 対応)
# ================================================================

class UARTModel:
    """uart.v の TX FSM を模倣。RXのシリアル入力は inject_rx() で代替する。"""
    TX_IDLE, TX_START, TX_DATA, TX_STOP = 0, 1, 2, 3

    def __init__(self, clks_per_bit=10):
        self.clks_per_bit = clks_per_bit
        self.tx_state = self.TX_IDLE
        self.tx_clk_cnt = 0
        self.tx_bit_idx = 0
        self.tx_shift = 0
        self.tx_history = []
        self.rx_data = 0
        self.rx_ready = 0

    def state_busy(self):
        return self.tx_state != self.TX_IDLE

    def step_edge(self, tx_start, tx_data, rx_clear):
        """1クロックエッジ分の動作。tx_start/tx_data/rx_clear は mmio レジスタ出力。"""
        if self.tx_state == self.TX_IDLE:
            if tx_start:
                self.tx_shift = tx_data & 0xFF
                self.tx_history.append(tx_data & 0xFF)
                self.tx_state = self.TX_START
                self.tx_clk_cnt = 0
                self.tx_bit_idx = 0
        elif self.tx_state == self.TX_START:
            if self.tx_clk_cnt < self.clks_per_bit - 1:
                self.tx_clk_cnt += 1
            else:
                self.tx_clk_cnt = 0
                self.tx_state = self.TX_DATA
        elif self.tx_state == self.TX_DATA:
            if self.tx_clk_cnt < self.clks_per_bit - 1:
                self.tx_clk_cnt += 1
            else:
                self.tx_clk_cnt = 0
                if self.tx_bit_idx < 7:
                    self.tx_bit_idx += 1
                else:
                    self.tx_bit_idx = 0
                    self.tx_state = self.TX_STOP
        elif self.tx_state == self.TX_STOP:
            if self.tx_clk_cnt < self.clks_per_bit - 1:
                self.tx_clk_cnt += 1
            else:
                self.tx_clk_cnt = 0
                self.tx_state = self.TX_IDLE

        # rx_clear: mmio からの登録済みクリアパルス
        # (Verilog と同様、同サイクルの RX FSM による rx_ready セットが優先)
        if rx_clear:
            self.rx_ready = 0

    def inject_rx(self, byte_val):
        self.rx_data = byte_val & 0xFF
        self.rx_ready = 1

class MMIOModel:
    """mmio.v を模倣。tx_start/tx_hold/rx_clear はレジスタ、rdata は同期読み出し。"""
    def __init__(self, uart):
        self.uart = uart
        self.rdata_q = 0
        self.tx_start_q = False
        self.tx_hold_q = 0
        self.rx_clear_q = False

    def tx_busy(self):
        # uart.v 修正版: assign tx_busy = (tx_state != TX_IDLE) | tx_start;
        return 1 if (self.uart.state_busy() or self.tx_start_q) else 0

    def step_edge(self, addr, mmio_we, mem_wdata):
        """1クロックエッジ分のMMIO動作。addr は今サイクルのバスアドレス全体。"""
        # ---- 現サイクルの組み合わせ評価 ----
        if addr == 0xFF00:      # UART_DATA
            rdata_next = self.uart.rx_data & 0xFF
            rx_clear_next = not mmio_we
        elif addr == 0xFF01:    # UART_STATUS
            rdata_next = ((self.uart.rx_ready & 1) << 1) | self.tx_busy()
            rx_clear_next = False
        else:
            rdata_next = 0
            rx_clear_next = False

        tx_start_next = bool(mmio_we) and (addr == 0xFF00) and (not self.tx_busy())
        tx_hold_next = (mem_wdata & 0xFF) if tx_start_next else self.tx_hold_q

        # ---- エッジ適用 (レジスタ更新) ----
        self.rdata_q = rdata_next
        self.tx_start_q = tx_start_next
        self.tx_hold_q = tx_hold_next
        self.rx_clear_q = rx_clear_next


# ================================================================
# SoC モデル (k16_soc.v + cpu.v の RTL構造を1対1に模倣)
# ================================================================

class SystemSoC:
    def __init__(self, mem, clks_per_bit=10):
        # RAM: 16K word (アドレス下位14bit)。未初期化 = NOP (tb_cpu.v と同じ環境)
        self.mem = mem
        self.uart = UARTModel(clks_per_bit=clks_per_bit)
        self.mmio = MMIOModel(self.uart)
        self.alu = ALU()
        self.rf = RegFile()

        # ---- cpu.v のレジスタ一式 ----
        self.if_id_ir = NOP_INST                 # IF/ID 命令レジスタ
        ex = decode(NOP_INST)
        ex['rddata_a'] = 0
        ex['rddata_b'] = 0
        self.id_ex = ex                          # ID/EX パイプラインレジスタ
        self.ram_rdata_q = NOP_INST              # RAM 同期読み出し出力レジスタ
        self.is_mmio_q = False                   # バス先 (RAM/MMIO) 1サイクル遅延
        self.data_access_q = False               # 前サイクルがデータアクセス
        self.load_active_q = False               # Loadデータ書き戻しサイクル
        self.load_rd_q = 0
        self.pend_valid = False                  # Loadストール時の後続命令退避
        self.pend_inst = NOP_INST
        self.branch_flush_q = False              # 分岐フラッシュ2サイクル目
        self.prev_wtaddr = 0
        self.prev_wtdata = 0
        self.prev_wtenable = False

        # ---- 計測用 (動作に影響しない): 命令アドレスをパイプラインに同行させる ----
        self.bus_addr_q = None                   # 前サイクルのフェッチアドレス (データアクセス時はNone)
        self.if_id_addr = None                   # if_id_ir の命令アドレス
        self.id_ex_addr = None                   # id_ex の命令アドレス
        self.pend_addr = None                    # pend_inst の命令アドレス

    def step(self):
        # ==========================================================
        # 組み合わせ論理 (現在のレジスタ値から評価)
        # ==========================================================
        # ---- IDステージ: if_id_ir をデコード & レジスタ読み出し ----
        d = decode(self.if_id_ir)
        rddata_a = self.rf.read_a(d['rs1'], self.alu.Z, self.alu.C, self.alu.N)
        rddata_b = self.rf.read_b(d['rs2'], self.alu.Z, self.alu.C, self.alu.N)

        # ---- EXステージ: id_ex を実行 ----
        ex = self.id_ex
        cond_match = check_cond(ex['cond'], self.alu.Z, self.alu.C, self.alu.N)
        ex_is_mem_access = cond_match and (ex['is_load'] or ex['is_store'])
        load_stall = cond_match and ex['is_load']

        # BRAM/MMIO 同期読み出しの1サイクル遅延データ
        mem_rdata = self.mmio.rdata_q if self.is_mmio_q else self.ram_rdata_q

        # r14(フラグ)はEXステージでライブ読み出し (cpu.v の ex_rddata_a/b と同一)
        live_flags = (self.alu.N << 2) | (self.alu.C << 1) | self.alu.Z
        ex_rddata_a = live_flags if ex['rs1'] == 14 else ex['rddata_a']
        ex_rddata_b = live_flags if ex['rs2'] == 14 else ex['rddata_b']

        # フォワーディング (cpu.v と同一の優先順)
        wtdata_now = mem_rdata & 0xFFFF
        fwd_r13_a = ((ex_rddata_a & 0xFF00) | ((mem_rdata >> 16) & 0xFF)) if self.load_active_q else ex_rddata_a
        fwd_r13_b = ((ex_rddata_b & 0xFF00) | ((mem_rdata >> 16) & 0xFF)) if self.load_active_q else ex_rddata_b

        if self.load_active_q and (self.load_rd_q == ex['rs1']) and (ex['rs1'] not in (0, 14)):
            fwd_a = wtdata_now
        elif self.load_active_q and (ex['rs1'] == 13):
            fwd_a = fwd_r13_a
        elif self.prev_wtenable and (self.prev_wtaddr == ex['rs1']):
            fwd_a = self.prev_wtdata
        else:
            fwd_a = ex_rddata_a

        if self.load_active_q and (self.load_rd_q == ex['rs2']) and (ex['rs2'] not in (0, 14)):
            fwd_b = wtdata_now
        elif self.load_active_q and (ex['rs2'] == 13):
            fwd_b = fwd_r13_b
        elif self.prev_wtenable and (self.prev_wtaddr == ex['rs2']):
            fwd_b = self.prev_wtdata
        else:
            fwd_b = ex_rddata_b

        alu_in_a = fwd_a
        alu_in_b = ex['imm'] if ex['alu_src_imm'] else fwd_b
        alu_res, temp = self.alu.compute(alu_in_a, alu_in_b, ex['alu_funct'])

        # レジスタ書き込み (通常ALU結果 or 1サイクル遅延Loadデータ)
        wtenable = (cond_match and ex['reg_write'] and not ex['is_load']) or self.load_active_q
        wtaddr = self.load_rd_q if self.load_active_q else ex['rd']
        wtdata = wtdata_now if self.load_active_q else alu_res
        topenable = self.load_active_q
        topin = (mem_rdata >> 16) & 0xFF
        pc_write_now = wtenable and (wtaddr == 15)

        # 統合バス (単一ポート)
        pc = self.rf.regs[15]
        shared_addr = (alu_res & 0xFFFF) if ex_is_mem_access else pc
        topout = self.rf.regs[13] & 0xFF
        mem_wdata = ((topout << 16) | (fwd_b & 0xFFFF)) & 0xFFFFFF
        mem_we = cond_match and ex['is_store']
        is_mmio_addr = (shared_addr >= 0xFF00)

        # RAM (16K word, 下位14bit) — 書き込みはエッジで、読み出しは旧値をラッチ
        ram_addr = shared_addr & 0x3FFF
        next_ram_rdata = self.mem.get(ram_addr, NOP_INST)

        # 今サイクルのフェッチアドレス (データアクセス時はフェッチなし)
        fetch_addr_now = None if ex_is_mem_access else pc

        # ==========================================================
        # クロックエッジ: 全レジスタ同時更新
        # ==========================================================
        # 1) レジスタファイル (r0/r14書き込み禁止, r13[7:0], PC更新含む)
        self.rf.write(wtenable, wtaddr, wtdata, topenable, topin, pc_hold=ex_is_mem_access)

        # 2) ALUフラグ
        if cond_match and ex['flag_write']:
            self.alu.update_flags(ex['alu_funct'], alu_res, temp, alu_in_a)

        # 3) RAM書き込み (MMIO領域以外)
        if mem_we and not is_mmio_addr:
            self.mem[ram_addr] = mem_wdata

        # 4) MMIO / UART エッジ
        #    UARTはmmioの「エッジ前」のレジスタ出力を入力とする (Verilogと同一)
        tx_start_now = self.mmio.tx_start_q
        tx_data_now = self.mmio.tx_hold_q
        rx_clear_now = self.mmio.rx_clear_q
        mmio_we = mem_we and is_mmio_addr
        self.mmio.step_edge(shared_addr, mmio_we, mem_wdata)
        self.uart.step_edge(tx_start_now, tx_data_now, rx_clear_now)

        # 5) エッジ前のパイプライン制御レジスタを退避 (更新順序の依存を避ける)
        data_access_q_prev = self.data_access_q
        branch_flush_q_prev = self.branch_flush_q
        pend_valid_prev = self.pend_valid
        pend_inst_prev = self.pend_inst
        bus_addr_prev = self.bus_addr_q        # mem_rdataのsource (bus(N-1))
        pend_addr_prev = self.pend_addr
        if_id_addr_prev = self.if_id_addr

        # 6) RAM読み出し出力レジスタ / バス先遅延
        self.ram_rdata_q = next_ram_rdata
        self.is_mmio_q = is_mmio_addr

        # 7) バス調停バブル
        self.data_access_q = ex_is_mem_access

        # 8) Load 1サイクル遅延書き戻し
        self.load_active_q = load_stall
        if load_stall:
            self.load_rd_q = ex['rd']

        # 9) Loadストール時の後続命令退避
        #    前サイクルがバス占有(ストア等)だった場合はフェッチが発生していない
        #    ため退避しない (pc_holdにより L+2 以降が再フェッチされる)
        if load_stall and not data_access_q_prev:
            self.pend_valid = True
            self.pend_inst = mem_rdata
            self.pend_addr = bus_addr_prev
        else:
            self.pend_valid = False
            self.pend_addr = None

        # 10) IF/ID 命令レジスタ (優先順は cpu.v と同一)
        if pc_write_now:
            self.if_id_ir = NOP_INST          # 分岐フラッシュ1/2 (J+2 廃棄)
            self.if_id_addr = None
        elif load_stall:
            self.if_id_ir = self.if_id_ir     # Loadストール中は保持
        elif branch_flush_q_prev:
            self.if_id_ir = NOP_INST          # 分岐フラッシュ2/2 (J+3 廃棄)
            self.if_id_addr = None
        elif data_access_q_prev:
            self.if_id_ir = pend_inst_prev if pend_valid_prev else NOP_INST
            self.if_id_addr = pend_addr_prev if pend_valid_prev else None
        else:
            self.if_id_ir = mem_rdata
            self.if_id_addr = bus_addr_prev

        # 11) ID/EX パイプラインレジスタ
        if load_stall or pc_write_now:
            nd = decode(NOP_INST)
            self.id_ex_addr = None
        else:
            nd = d
            self.id_ex_addr = if_id_addr_prev
        nd = dict(nd)
        nd['rddata_a'] = rddata_a
        nd['rddata_b'] = rddata_b
        self.id_ex = nd

        # 12) 分岐フラッシュ2サイクル目
        self.branch_flush_q = pc_write_now

        # 13) フォワーディング用書き込み履歴
        self.prev_wtaddr = wtaddr
        self.prev_wtdata = wtdata
        self.prev_wtenable = wtenable and (wtaddr != 0) and (wtaddr != 14)

        # 14) フェッチアドレス履歴 (計測用)
        self.bus_addr_q = fetch_addr_now


# ================================================================
# 命令エンコード (テストプログラム用)
# ================================================================

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
