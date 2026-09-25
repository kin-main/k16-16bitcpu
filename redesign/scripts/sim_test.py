#!/usr/bin/env python3
"""
k16 CPU Cycle-Accurate Simulator — 同期RAM再設計版検証

このスクリプトは rtl/cpu.v の状態機械・パイプラインロジックを
サイクル精度で模倣し、設計が意図通り動くか検証する。
"""

import sys

# Instruction encoding helpers
def encode_r(cond, rd, rs1, rs2, funct):
    return (cond << 21) | (0b00 << 19) | (rd << 15) | (rs1 << 11) | (rs2 << 7) | (0b0000 << 3) | funct

def encode_i(cond, rd, rs, im, funct):
    return (cond << 21) | (0b01 << 19) | (rd << 15) | (rs << 11) | (im << 3) | funct

def encode_ls(cond, rd, base, im, funct):
    return (cond << 21) | (0b11 << 19) | (rd << 15) | (base << 11) | (im << 2) | funct

NOP = 0x800000

def decode(inst):
    cond = (inst >> 21) & 0b111
    op = (inst >> 19) & 0b11
    rd = (inst >> 15) & 0b1111
    rs1 = (inst >> 11) & 0b1111
    is_alu_reg = (op == 0b00)
    is_alu_imm = (op == 0b01)
    is_load = (op == 0b11) and ((inst >> 1) & 1) == 0
    is_store = (op == 0b11) and ((inst >> 1) & 1) == 1
    rs2 = rd if is_store else ((inst >> 7) & 0b1111)
    alu_src_imm = is_alu_imm or (op == 0b11)
    reg_write = is_alu_reg or is_alu_imm or is_load
    flag_write = (is_alu_reg or is_alu_imm) and (rd != 15)
    if op == 0b01:
        imm = (inst >> 3) & 0xFF
    elif op == 0b11:
        imm = (inst >> 2) & 0x1FF
    else:
        imm = 0
    if op in (0b00, 0b01):
        alu_funct = inst & 0b111
    elif op == 0b11:
        alu_funct = 0b100 if (inst & 1) == 0 else 0b101
    else:
        alu_funct = 0
    return {
        'cond': cond, 'op': op, 'rd': rd, 'rs1': rs1, 'rs2': rs2,
        'imm': imm, 'alu_funct': alu_funct,
        'is_alu_reg': is_alu_reg, 'is_alu_imm': is_alu_imm,
        'is_load': is_load, 'is_store': is_store,
        'alu_src_imm': alu_src_imm,
        'reg_write': reg_write, 'flag_write': flag_write,
    }

def cond_match(cond, zf, cf, nf):
    return {
        0b000: True, 0b001: not zf, 0b010: not cf, 0b011: not nf,
        0b100: False, 0b101: zf, 0b110: cf, 0b111: nf,
    }[cond]

def alu(funct, A, B, C):
    if funct == 0b000: return (~(A & B)) & 0xFFFF, None
    if funct == 0b001: return (A | B) & 0xFFFF, None
    if funct == 0b010: return (A & B) & 0xFFFF, None
    if funct == 0b011: return (A ^ B) & 0xFFFF, None
    if funct == 0b100:
        t = (A & 0xFFFF) + (B & 0xFFFF); return t & 0xFFFF, (t >> 16) & 1
    if funct == 0b101:
        t = (A & 0xFFFF) + ((~B) & 0xFFFF) + 1; return t & 0xFFFF, (t >> 16) & 1
    if funct == 0b110:
        t = (A & 0xFFFF) + (B & 0xFFFF) + C; return t & 0xFFFF, (t >> 16) & 1
    if funct == 0b111: return (A >> 1) & 0xFFFF, A & 1
    return 0, None


class MemorySubsystem:
    def __init__(self, ram_size=1 << 14, init_data=None):
        self.ram = [NOP] * ram_size
        if init_data:
            for addr, val in init_data.items():
                if addr < ram_size:
                    self.ram[addr] = val & 0xFFFFFF
        self.ram_size = ram_size
        self.rdata_reg = NOP
        self.mmio_regs = {}

    def is_mmio(self, addr):
        return addr >= 0xFF00


class CPU:
    S_IDLE = 0
    S_MEM_RESP = 1
    S_FLUSH1 = 2

    def __init__(self, mem):
        self.mem = mem
        self.state = self.S_IDLE
        self.ir = NOP
        self.ir_addr = 0
        self.fetch_pc = 0
        self.mem_addr_q = 0
        self.prefetch_buf = NOP
        self.prefetch_addr = 0
        self.prefetch_valid = False
        self.saved = {'is_load': False, 'is_store': False, 'rd': 0,
                      'cond_match': False, 'data_addr': 0}
        self.prev_wtaddr = 0
        self.prev_wtdata = 0
        self.prev_wtenable = False
        self.regs = [0] * 16
        self.zf = False
        self.cf = False
        self.nf = False
        self.cycle = 0

    def read_regfile(self, addr):
        if addr == 0: return 0
        if addr == 14:
            return (int(self.nf) << 2) | (int(self.cf) << 1) | int(self.zf)
        if addr == 15: return self.ir_addr
        return self.regs[addr]

    def run(self, max_cycles=2000):
        for _ in range(max_cycles):
            self.cycle += 1
            d = decode(self.ir)
            cm = cond_match(d['cond'], self.zf, self.cf, self.nf)
            is_mem_access = cm and (d['is_load'] or d['is_store'])
            is_alu_r15 = (cm and d['reg_write'] and (d['rd'] == 15)
                          and self.state == self.S_IDLE)

            rddata_a_raw = self.read_regfile(d['rs1'])
            rddata_b_raw = self.read_regfile(d['rs2'])

            if self.prev_wtenable and (self.prev_wtaddr == d['rs1']):
                fwd_a = self.prev_wtdata
            else:
                fwd_a = rddata_a_raw
            if self.prev_wtenable and (self.prev_wtaddr == d['rs2']):
                fwd_b = self.prev_wtdata
            else:
                fwd_b = rddata_b_raw

            alu_in_a = fwd_a
            alu_in_b = d['imm'] if d['alu_src_imm'] else fwd_b
            alu_result, carry_out = alu(d['alu_funct'], alu_in_a, alu_in_b, int(self.cf))
            data_addr = alu_result

            # ===== mem_addr / mem_data_req / mem_we =====
            if self.state == self.S_IDLE:
                if is_mem_access:
                    mem_addr = data_addr
                    mem_data_req = True
                    mem_we = cm and d['is_store']
                elif is_alu_r15:
                    mem_addr = alu_result
                    mem_data_req = False
                    mem_we = False
                else:
                    mem_addr = self.fetch_pc
                    mem_data_req = False
                    mem_we = False
            elif self.state == self.S_MEM_RESP:
                resp = self.saved
                is_load_r15_branch = (resp['cond_match'] and resp['is_load']
                                      and (resp['rd'] == 15))
                mem_ready = True
                if is_load_r15_branch and mem_ready:
                    mem_addr = self.mem.rdata_reg & 0xFFFF
                    mem_data_req = False
                    mem_we = False
                elif not mem_ready:
                    mem_addr = resp['data_addr']
                    mem_data_req = True
                    mem_we = False
                else:
                    mem_addr = self.fetch_pc
                    mem_data_req = False
                    mem_we = False
            else:  # S_FLUSH1
                mem_addr = self.fetch_pc
                mem_data_req = False
                mem_we = False

            mem_wdata = ((self.regs[13] & 0xFF) << 16) | (fwd_b & 0xFFFF)

            # ===== Writeback =====
            if self.state == self.S_IDLE:
                if cm and d['reg_write'] and not is_mem_access and not is_alu_r15:
                    wtenable = True
                    wtaddr = d['rd']
                    wtdata = alu_result
                else:
                    wtenable = False
                    wtaddr = d['rd']
                    wtdata = alu_result
                topenable = False
            elif self.state == self.S_MEM_RESP:
                resp = self.saved
                mem_ready = True
                # Per cpu.v: topenable = (mem_ready && resp_cond_match && resp_is_load)
                # Note: does NOT depend on resp_rd != 15, so LOAD r15 also updates r13
                if mem_ready and resp['cond_match'] and resp['is_load']:
                    topenable = True
                else:
                    topenable = False
                if mem_ready and resp['cond_match'] and resp['is_load'] and (resp['rd'] != 15):
                    wtenable = True
                    wtaddr = resp['rd']
                    wtdata = self.mem.rdata_reg & 0xFFFF
                else:
                    wtenable = False
                    wtaddr = resp['rd']
                    wtdata = 0
            else:
                wtenable = False
                wtaddr = 0
                wtdata = 0
                topenable = False

            # ===== Synchronous updates =====
            # 1. Memory write
            if mem_we:
                if self.mem.is_mmio(mem_addr):
                    self.mem.mmio_regs[mem_addr & 0xFF] = mem_wdata
                elif mem_addr < self.mem.ram_size:
                    self.mem.ram[mem_addr] = mem_wdata & 0xFFFFFF

            # 2. Memory read (rdata_reg for next cycle)
            if self.mem.is_mmio(mem_addr) and mem_data_req:
                next_rdata_reg = self.mem.mmio_regs.get(mem_addr & 0xFF, 0)
            elif self.mem.is_mmio(mem_addr) and not mem_data_req:
                next_rdata_reg = NOP
            elif mem_addr < self.mem.ram_size:
                next_rdata_reg = self.mem.ram[mem_addr]
            else:
                next_rdata_reg = NOP

            # 3. Register write
            new_regs = list(self.regs)
            if wtenable and wtaddr not in (0, 14, 15):
                new_regs[wtaddr] = wtdata & 0xFFFF
            if topenable:
                new_regs[13] = (new_regs[13] & 0xFF00) | ((self.mem.rdata_reg >> 16) & 0xFF)

            # 4. ALU flags
            new_zf = self.zf
            new_cf = self.cf
            new_nf = self.nf
            flag_en = (cm and d['flag_write'] and
                       self.state == self.S_IDLE and not is_mem_access)
            if flag_en:
                new_zf = (alu_result == 0)
                new_nf = bool((alu_result >> 15) & 1)
                if d['alu_funct'] in (0b100, 0b101, 0b110):
                    new_cf = bool(carry_out)
                elif d['alu_funct'] == 0b111:
                    new_cf = bool(alu_in_a & 1)

            # 5. State machine
            new_state = self.state
            new_ir = self.ir
            new_ir_addr = self.ir_addr
            new_fetch_pc = self.fetch_pc
            new_prefetch_buf = self.prefetch_buf
            new_prefetch_addr = self.prefetch_addr
            new_prefetch_valid = self.prefetch_valid
            new_prev_wtaddr = 0
            new_prev_wtdata = 0
            new_prev_wtenable = False
            new_saved = dict(self.saved)

            if self.state == self.S_IDLE:
                if is_mem_access:
                    new_prefetch_buf = self.mem.rdata_reg
                    new_prefetch_addr = self.mem_addr_q
                    new_prefetch_valid = True
                    new_saved = {
                        'is_load': d['is_load'], 'is_store': d['is_store'],
                        'rd': d['rd'], 'cond_match': cm, 'data_addr': data_addr,
                    }
                    new_ir = NOP
                    new_ir_addr = 0
                    new_fetch_pc = self.fetch_pc
                    new_state = self.S_MEM_RESP
                elif is_alu_r15:
                    new_ir = NOP
                    new_ir_addr = 0
                    new_fetch_pc = (alu_result + 1) & 0xFFFF
                    new_state = self.S_FLUSH1
                else:
                    new_ir = self.mem.rdata_reg
                    new_ir_addr = self.mem_addr_q
                    new_fetch_pc = (self.fetch_pc + 1) & 0xFFFF
                    new_state = self.S_IDLE
                    new_prev_wtaddr = wtaddr
                    new_prev_wtdata = wtdata
                    new_prev_wtenable = (wtenable and wtaddr not in (0, 14, 15))
            elif self.state == self.S_MEM_RESP:
                mem_ready = True
                if not mem_ready:
                    new_state = self.S_MEM_RESP
                else:
                    is_load_r15_branch = (self.saved['cond_match'] and self.saved['is_load']
                                          and (self.saved['rd'] == 15))
                    if is_load_r15_branch:
                        new_ir = NOP
                        new_ir_addr = 0
                        new_fetch_pc = ((self.mem.rdata_reg & 0xFFFF) + 1) & 0xFFFF
                        new_state = self.S_FLUSH1
                        new_prefetch_valid = False
                    else:
                        new_ir = self.prefetch_buf
                        new_ir_addr = self.prefetch_addr
                        new_prefetch_valid = False
                        new_fetch_pc = (self.fetch_pc + 1) & 0xFFFF
                        new_state = self.S_IDLE
                        new_prev_wtaddr = wtaddr
                        new_prev_wtdata = wtdata
                        new_prev_wtenable = (wtenable and wtaddr not in (0, 14, 15))
            else:  # S_FLUSH1
                new_ir = self.mem.rdata_reg
                new_ir_addr = self.mem_addr_q
                new_fetch_pc = (self.fetch_pc + 1) & 0xFFFF
                new_state = self.S_IDLE

            # Apply
            self.mem.rdata_reg = next_rdata_reg
            self.mem_addr_q = mem_addr
            self.regs = new_regs
            self.zf = new_zf
            self.cf = new_cf
            self.nf = new_nf
            self.state = new_state
            self.ir = new_ir
            self.ir_addr = new_ir_addr
            self.fetch_pc = new_fetch_pc
            self.prefetch_buf = new_prefetch_buf
            self.prefetch_addr = new_prefetch_addr
            self.prefetch_valid = new_prefetch_valid
            self.prev_wtaddr = new_prev_wtaddr
            self.prev_wtdata = new_prev_wtdata
            self.prev_wtenable = new_prev_wtenable
            self.saved = new_saved


def test_alu_alu():
    print("\n=== Test: ALU → ALU ===")
    program = {
        0: encode_i(0b000, 1, 0, 10, 0b100),
        1: encode_i(0b000, 2, 0, 5, 0b100),
        2: encode_r(0b000, 3, 1, 2, 0b100),
        3: encode_r(0b000, 4, 3, 1, 0b100),
        4: encode_r(0b000, 5, 4, 2, 0b100),
    }
    mem = MemorySubsystem(init_data=program)
    cpu = CPU(mem)
    cpu.run(20)
    assert cpu.regs[1] == 10, f"r1={cpu.regs[1]}"
    assert cpu.regs[2] == 5, f"r2={cpu.regs[2]}"
    assert cpu.regs[3] == 15, f"r3={cpu.regs[3]}"
    assert cpu.regs[4] == 25, f"r4={cpu.regs[4]}"
    assert cpu.regs[5] == 30, f"r5={cpu.regs[5]}"
    print(f"  r1={cpu.regs[1]}, r2={cpu.regs[2]}, r3={cpu.regs[3]}, r4={cpu.regs[4]}, r5={cpu.regs[5]}")
    print("  PASS")


def test_load_alu():
    print("\n=== Test: LOAD → ALU ===")
    program = {
        0: encode_i(0b000, 2, 0, 100, 0b100),
        1: encode_ls(0b000, 1, 2, 0, 0b00),
        2: encode_r(0b000, 3, 1, 0, 0b100),
    }
    mem = MemorySubsystem(init_data=program)
    mem.ram[100] = 0xAB1234
    cpu = CPU(mem)
    cpu.run(30)
    assert cpu.regs[1] == 0x1234, f"r1={cpu.regs[1]:#x}"
    assert (cpu.regs[13] & 0xFF) == 0xAB, f"r13={cpu.regs[13]:#x}"
    assert cpu.regs[3] == 0x1234, f"r3={cpu.regs[3]:#x}"
    print(f"  r1={cpu.regs[1]:#x}, r13[7:0]={cpu.regs[13] & 0xFF:#x}, r3={cpu.regs[3]:#x}")
    print("  PASS")


def test_load_store():
    print("\n=== Test: LOAD → STORE ===")
    program = {
        0: encode_i(0b000, 2, 0, 50, 0b100),
        1: encode_i(0b000, 3, 0, 60, 0b100),
        2: encode_ls(0b000, 1, 2, 0, 0b00),
        3: encode_ls(0b000, 1, 3, 0, 0b10),
    }
    mem = MemorySubsystem(init_data=program)
    mem.ram[50] = 0xDE5678  # 24-bit: high=0xDE, low=0x5678
    cpu = CPU(mem)
    cpu.run(30)
    assert cpu.regs[1] == 0x5678, f"r1={cpu.regs[1]:#x}"
    assert (cpu.regs[13] & 0xFF) == 0xDE, f"r13={cpu.regs[13] & 0xFF:#x}"
    assert mem.ram[60] == 0xDE5678, f"mem[60]={mem.ram[60]:#x}"
    print(f"  r1={cpu.regs[1]:#x}, r13[7:0]={cpu.regs[13] & 0xFF:#x}, mem[60]={mem.ram[60]:#x}")
    print("  PASS")


def test_store_load():
    print("\n=== Test: STORE → LOAD ===")
    program = {
        0: encode_i(0b000, 1, 0, 0x42, 0b100),
        1: encode_i(0b000, 13, 0, 0x99, 0b100),
        2: encode_i(0b000, 2, 0, 70, 0b100),
        3: encode_ls(0b000, 1, 2, 0, 0b10),
        4: encode_ls(0b000, 3, 2, 0, 0b00),
    }
    mem = MemorySubsystem(init_data=program)
    cpu = CPU(mem)
    cpu.run(30)
    assert mem.ram[70] == 0x990042, f"mem[70]={mem.ram[70]:#x}"
    assert cpu.regs[3] == 0x42, f"r3={cpu.regs[3]:#x}"
    assert (cpu.regs[13] & 0xFF) == 0x99, f"r13={cpu.regs[13] & 0xFF:#x}"
    print(f"  mem[70]={mem.ram[70]:#x}, r3={cpu.regs[3]:#x}, r13[7:0]={cpu.regs[13] & 0xFF:#x}")
    print("  PASS")


def test_branch():
    print("\n=== Test: ALU → r15 (Branch) ===")
    program = {
        0: encode_i(0b000, 1, 0, 10, 0b100),
        1: encode_i(0b000, 15, 1, 0, 0b100),
        2: encode_i(0b000, 2, 0, 99, 0b100),
        3: encode_i(0b000, 2, 0, 88, 0b100),
        10: encode_i(0b000, 3, 0, 77, 0b100),
        11: encode_i(0b000, 4, 0, 55, 0b100),
    }
    mem = MemorySubsystem(init_data=program)
    cpu = CPU(mem)
    cpu.run(30)
    assert cpu.regs[1] == 10, f"r1={cpu.regs[1]}"
    assert cpu.regs[2] == 0, f"r2={cpu.regs[2]} (should be 0)"
    assert cpu.regs[3] == 77, f"r3={cpu.regs[3]}"
    assert cpu.regs[4] == 55, f"r4={cpu.regs[4]}"
    print(f"  r1={cpu.regs[1]}, r2={cpu.regs[2]}, r3={cpu.regs[3]}, r4={cpu.regs[4]}")
    print("  PASS")


def test_load_r15():
    print("\n=== Test: LOAD → r15 ===")
    program = {
        0: encode_i(0b000, 1, 0, 50, 0b100),
        1: encode_ls(0b000, 15, 1, 0, 0b00),
        2: encode_i(0b000, 2, 0, 99, 0b100),
        3: encode_i(0b000, 2, 0, 88, 0b100),
        32: encode_i(0b000, 3, 0, 42, 0b100),   # TARGET=0x20=32
        33: encode_i(0b000, 4, 0, 33, 0b100),
    }
    mem = MemorySubsystem(init_data=program)
    mem.ram[50] = 0xAA0020  # TARGET = 0x20 = 32
    cpu = CPU(mem)
    cpu.run(30)
    assert cpu.regs[2] == 0, f"r2={cpu.regs[2]} (should be 0)"
    assert cpu.regs[3] == 42, f"r3={cpu.regs[3]}"
    assert cpu.regs[4] == 33, f"r4={cpu.regs[4]}"
    assert (cpu.regs[13] & 0xFF) == 0xAA, f"r13={cpu.regs[13] & 0xFF:#x}"
    print(f"  r2={cpu.regs[2]}, r3={cpu.regs[3]}, r4={cpu.regs[4]}, r13[7:0]={cpu.regs[13] & 0xFF:#x}")
    print("  PASS")


def test_conditional_skip():
    print("\n=== Test: Conditional LOAD skip ===")
    program = {
        0: encode_r(0b000, 1, 0, 0, 0b101),     # r1 = 0-0 = 0, Z=1
        1: encode_ls(0b001, 2, 0, 50, 0b00),    # LOAD.ne r2, [r0+50] -- Z=1, NE false, SKIP
        2: encode_r(0b000, 3, 0, 0, 0b101),     # r3 = 0-0 = 0, Z=1 (re-set Z)
        3: encode_ls(0b101, 4, 0, 60, 0b00),    # LOAD.eq r4, [r0+60] -- Z=1, EQ true, EXECUTE
    }
    mem = MemorySubsystem(init_data=program)
    mem.ram[50] = 0xAA1111
    mem.ram[60] = 0xBB2222
    cpu = CPU(mem)
    cpu.run(30)
    assert cpu.regs[2] == 0, f"r2={cpu.regs[2]} (LOAD.ne skipped)"
    assert cpu.regs[3] == 0, f"r3={cpu.regs[3]}"
    assert cpu.regs[4] == 0x2222, f"r4={cpu.regs[4]:#x} (LOAD.eq executed)"
    assert (cpu.regs[13] & 0xFF) == 0xBB, f"r13={cpu.regs[13] & 0xFF:#x}"
    print(f"  r2={cpu.regs[2]}, r3={cpu.regs[3]}, r4={cpu.regs[4]:#x}, r13[7:0]={cpu.regs[13] & 0xFF:#x}")
    print("  PASS")


def test_back_to_back_load():
    print("\n=== Test: Back-to-back LOAD → ADD ===")
    program = {
        0: encode_i(0b000, 2, 0, 50, 0b100),
        1: encode_i(0b000, 4, 0, 60, 0b100),
        2: encode_ls(0b000, 1, 2, 0, 0b00),
        3: encode_ls(0b000, 3, 4, 0, 0b00),
        4: encode_r(0b000, 5, 1, 3, 0b100),
    }
    mem = MemorySubsystem(init_data=program)
    mem.ram[50] = 0x00100
    mem.ram[60] = 0x00200
    cpu = CPU(mem)
    cpu.run(40)
    assert cpu.regs[1] == 0x100, f"r1={cpu.regs[1]:#x}"
    assert cpu.regs[3] == 0x200, f"r3={cpu.regs[3]:#x}"
    assert cpu.regs[5] == 0x300, f"r5={cpu.regs[5]:#x}"
    print(f"  r1={cpu.regs[1]:#x}, r3={cpu.regs[3]:#x}, r5={cpu.regs[5]:#x}")
    print("  PASS")


def test_mmio():
    """MMIO LOAD/STORE (uses direct register set to bypass 8-bit imm limit)"""
    print("\n=== Test: MMIO LOAD/STORE ===")
    program = {
        0: encode_i(0b000, 1, 0, 0xAB, 0b100),  # r1 = 0xAB
        1: encode_ls(0b000, 1, 2, 0, 0b10),     # STORE [r2+0], r1 (r2 pre-set to 0xFF10)
        2: encode_ls(0b000, 3, 2, 0, 0b00),     # r3 = MMIO[0xFF10][15:0]
    }
    mem = MemorySubsystem(init_data=program)
    cpu = CPU(mem)
    # Pre-set r2 to 0xFF10 (LED MMIO address) — bypassing ISA 8-bit imm limit
    cpu.regs[2] = 0xFF10
    cpu.run(20)
    led_val = mem.mmio_regs.get(0x10, 0)
    assert (led_val & 0xFFFF) == 0xAB, f"LED={led_val:#x}"
    assert cpu.regs[3] == 0xAB, f"r3={cpu.regs[3]:#x}"
    print(f"  LED={led_val:#x}, r3={cpu.regs[3]:#x}")
    print("  PASS")


def test_pc_relative():
    print("\n=== Test: r15 read (PC-relative) ===")
    program = {
        0: encode_r(0b000, 1, 15, 0, 0b100),
        1: encode_r(0b000, 2, 15, 0, 0b100),
        2: NOP,
    }
    mem = MemorySubsystem(init_data=program)
    cpu = CPU(mem)
    cpu.run(15)
    assert cpu.regs[1] == 0, f"r1={cpu.regs[1]} (should be 0)"
    assert cpu.regs[2] == 1, f"r2={cpu.regs[2]} (should be 1)"
    print(f"  r1={cpu.regs[1]} (PC=0), r2={cpu.regs[2]} (PC=1)")
    print("  PASS")


def main():
    print("=== k16 CPU Cycle-Accurate Simulator (Sync RAM redesign) ===")
    tests = [
        test_alu_alu, test_load_alu, test_load_store, test_store_load,
        test_branch, test_load_r15, test_conditional_skip,
        test_back_to_back_load, test_mmio, test_pc_relative,
    ]
    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            passed += 1
        except AssertionError as e:
            print(f"  FAIL: {e}")
            failed += 1
        except Exception as e:
            import traceback
            traceback.print_exc()
            failed += 1

    print(f"\n=== Summary: {passed} passed, {failed} failed ===")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
