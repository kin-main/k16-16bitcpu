#!/usr/bin/env python3
"""
k16 CPU 27MHz用 Lチカ (LED Blink) ファームウェア生成スクリプト

クロック周波数: 27MHz (27,000,000 Hz)
- 0.5秒 ON / 0.5秒 OFF (1Hz 周期点滅)
- MMIO 0xFF02 (LED) への出力および UART への 'H' / 'L' メッセージ出力
- UARTボーレート: 115200 bps (CLKS_PER_BIT = 234)
"""

def enc_r(cond, rd, rs1, rs2, fk):
    """R形式: cond(3)|00|rd(4)|rs1(4)|rs2(4)|0000|fk(3)"""
    return (cond << 21) | (0b00 << 19) | (rd << 15) | (rs1 << 11) | (rs2 << 7) | fk

def enc_i(cond, rd, rs, imm, fk):
    """I形式: cond(3)|01|rd(4)|rs(4)|imm(8)|fk(3)"""
    return (cond << 21) | (0b01 << 19) | (rd << 15) | (rs << 11) | ((imm & 0xFF) << 3) | fk

def enc_ls(cond, rd, base, imm, fk):
    """LS形式: cond(3)|11|rd(4)|base(4)|imm(9)|fk(2)"""
    return (cond << 21) | (0b11 << 19) | (rd << 15) | (base << 11) | ((imm & 0x1FF) << 2) | fk

NOP  = enc_r(0b100, 0, 0, 0, 0)   # cond=Never
COND = {'AL':0,'NE':1,'NC':2,'PL':3,'NV':4,'EQ':5,'CS':6,'MI':7}

class Asm:
    def __init__(self):
        self.labels = {}
        self._items  = []
        self.pc = 0

    def _add(self, code, src=''):
        self._items.append(('INST', code, src))
        self.pc += 1

    def _add_data(self, val, src=''):
        self._items.append(('DATA', val & 0xFFFFFF, src))
        self.pc += 1

    def label(self, name):
        self.labels[name] = self.pc

    def nop(self):          self._add(NOP)
    def li(self, rd, imm, src=''): self._add(enc_i(0,rd,0,imm,4), src)
    def mov(self, rd, rs):  self._add(enc_r(0,rd,rs,0,4))
    def jump(self, cond, addr_placeholder, src=''):
        self._items.append(('JUMP', cond, addr_placeholder, self.pc, src))
        self.pc += 1
    def ret(self, cond=0):  self._add(enc_r(cond,15,12,0,4))

    def add(self,c,rd,rs1,rs2): self._add(enc_r(c,rd,rs1,rs2,4))
    def sub(self,c,rd,rs1,rs2): self._add(enc_r(c,rd,rs1,rs2,5))
    def subi(self,c,rd,rs,imm): self._add(enc_i(c,rd,rs,imm,5))
    def addi(self,c,rd,rs,imm): self._add(enc_i(c,rd,rs,imm,4))
    def andii(self,c,rd,rs,imm):self._add(enc_i(c,rd,rs,imm,2))
    def nand(self,c,rd,rs1,rs2):self._add(enc_r(c,rd,rs1,rs2,0))

    def ld(self,c,rd,base,imm,sub=0): self._add(enc_ls(c,rd,base,imm,(0<<1)|sub))
    def st(self,c,rd,base,imm,sub=0): self._add(enc_ls(c,rd,base,imm,(1<<1)|sub))

    def string(self, s):
        for ch in s:
            self._add_data(ord(ch), repr(ch))
        self._add_data(0, 'NULL')

    def resolve(self):
        out = []
        for item in self._items:
            kind = item[0]
            if kind in ('INST', 'DATA'):
                out.append(item[1])
            elif kind == 'JUMP':
                _, cond, lbl, pc, src = item
                target = self.labels[lbl] if isinstance(lbl, str) else lbl
                out.append(enc_i(cond, 15, 0, target, 4))
        return out


def build_led_blink():
    a = Asm()

    # =========================================================
    # アドレス初期化
    # r9  = 0xFF00 (UART_DATA MMIO アドレス)
    # r10 = 0xFF02 (LED MMIO アドレス)
    # =========================================================
    a.label('_start')
    a.nand(0, 9, 0, 0)          # r9 = 0xFFFF
    a.subi(0, 9, 9, 255)        # r9 = 0xFF00 (UART_DATA)
    a.addi(0, 10, 9, 2)         # r10 = 0xFF02 (LED_DATA)

    # ---------------------------------------------------------
    # メイン Lチカ ループ (0.5秒 ON / 0.5秒 OFF)
    # ---------------------------------------------------------
    a.label('blink_loop')

    # --- [1] LED ON & UART 'H' 送信 ---
    a.li(1, 0xFF)               # LED点灯パターン
    a.st(0, 1, 10, 0)           # mem[0xFF02] = 0x00FF (LED ON)
    a.li(1, ord('H'))
    a.st(0, 1, 9, 0)            # mem[0xFF00] = 'H' (UART送信)

    # 0.5秒ウェイト
    a.jump(COND['AL'], 'do_delay_on')
    a.label('after_delay_on')

    # --- [2] LED OFF & UART 'L' 送信 ---
    a.li(1, 0x00)               # LED消灯パターン
    a.st(0, 1, 10, 0)           # mem[0xFF02] = 0x0000 (LED OFF)
    a.li(1, ord('L'))
    a.st(0, 1, 9, 0)            # mem[0xFF00] = 'L' (UART送信)

    # 0.5秒ウェイト
    a.jump(COND['AL'], 'do_delay_off')
    a.label('after_delay_off')

    # ループ継続
    a.jump(COND['AL'], 'blink_loop')


    # ---------------------------------------------------------
    # 0.5秒 遅延サブルーチン / ループ
    # 27MHz計算:
    # 1秒 = 27,000,000 サイクル
    # 0.5秒 = 13,500,000 サイクル
    # インナーループ (SUBI + JUMP.NE) ≒ 3 サイクル/回
    # INNER_COUNT = 45,000  (45,000 * 3 = 135,000 サイクル)
    # OUTER_COUNT = 100     (135,000 * 100 = 13,500,000 サイクル ＝ 正確に0.5秒)
    # ---------------------------------------------------------
    a.label('do_delay_on')
    a.ld(0, 2, 0, a.pc + 20)    # メモリから OUTER_COUNT (100) をロード (後でアドレスパッチ)
    a.label('_patch_outer_on')

    a.label('outer_loop_on')
    a.ld(0, 3, 0, a.pc + 20)    # メモリから INNER_COUNT (45000) をロード
    a.label('_patch_inner_on')

    a.label('inner_loop_on')
    a.subi(0, 3, 3, 1)          # r3-- (1 cycle)
    a.jump(COND['NE'], 'inner_loop_on')  # r3 != 0 なら再行 (2 cycles)

    a.subi(0, 2, 2, 1)          # r2--
    a.jump(COND['NE'], 'outer_loop_on')
    a.jump(COND['AL'], 'after_delay_on')


    a.label('do_delay_off')
    a.ld(0, 2, 0, a.pc + 20)    # OUTER_COUNT (100)
    a.label('_patch_outer_off')

    a.label('outer_loop_off')
    a.ld(0, 3, 0, a.pc + 20)    # INNER_COUNT (45000)
    a.label('_patch_inner_off')

    a.label('inner_loop_off')
    a.subi(0, 3, 3, 1)
    a.jump(COND['NE'], 'inner_loop_off')

    a.subi(0, 2, 2, 1)
    a.jump(COND['NE'], 'outer_loop_off')
    a.jump(COND['AL'], 'after_delay_off')


    # ---------------------------------------------------------
    # 遅延用定数データ
    # ---------------------------------------------------------
    a.label('val_outer_count')
    a._add_data(100, 'OUTER_COUNT = 100')

    a.label('val_inner_count')
    a._add_data(45000, 'INNER_COUNT = 45000')


    # ---------------------------------------------------------
    # パッチ処理: 定数アドレスを LD 命令に反映
    # ---------------------------------------------------------
    outer_addr = a.labels['val_outer_count']
    inner_addr = a.labels['val_inner_count']

    # enc_ls(cond=0, rd=2/3, base=0, imm=addr, fk=0)
    def patch_ld(patch_lbl, rd, target_addr):
        pc = a.labels[patch_lbl] - 1
        cur = 0
        for idx, item in enumerate(a._items):
            if cur == pc:
                a._items[idx] = ('INST', enc_ls(0, rd, 0, target_addr, 0), f'LD r{rd}, r0, {target_addr}')
                break
            if item[0] in ('INST', 'DATA', 'JUMP'):
                cur += 1

    patch_ld('_patch_outer_on', 2, outer_addr)
    patch_ld('_patch_inner_on', 3, inner_addr)
    patch_ld('_patch_outer_off', 2, outer_addr)
    patch_ld('_patch_inner_off', 3, inner_addr)

    return a

if __name__ == '__main__':
    a = build_led_blink()
    codes = a.resolve()

    print(f'[INFO] Lチカ ファームウェアサイズ: {len(codes)} words')
    for name, addr in sorted(a.labels.items(), key=lambda x: x[1]):
        if not name.startswith('_'):
            print(f'  {addr:4d}  {name}')

    with open('firmware_led.hex', 'w') as f:
        for code in codes:
            f.write(f'{code:06X}\n')
    print(f'[SUCCESS] firmware_led.hex 生成完了 ({len(codes)} words)')
