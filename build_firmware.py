#!/usr/bin/env python3
"""
k16 CPU テストファームウェア生成スクリプト
UART/ISA 完全検証プログラムをアセンブルし firmware.hex を出力します。
FPGA 実機 (115200bps) および Verilog シミュレータ両用。
"""

# ================================================================
# 命令エンコード関数
# ================================================================

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
FUNCT = {'NAND':0,'OR':1,'AND':2,'XOR':3,'ADD':4,'SUB':5,'ADC':6,'SHR':7}

# ================================================================
# 2パスアセンブラ
# ================================================================

class Asm:
    def __init__(self):
        self.labels = {}
        self._items  = []   # (kind, value, raw_src)
        self.pc = 0

    # ---- 命令追加ヘルパー ----
    def _add(self, code, src=''):
        self._items.append(('INST', code, src))
        self.pc += 1

    def _add_data(self, val, src=''):
        self._items.append(('DATA', val & 0xFFFFFF, src))
        self.pc += 1

    def label(self, name):
        self.labels[name] = self.pc

    # ---- 疑似命令 ----
    def nop(self):          self._add(NOP)
    def li(self, rd, imm, src=''): self._add(enc_i(0,rd,0,imm,4), src)
    def mov(self, rd, rs):  self._add(enc_r(0,rd,rs,0,4))
    def jump(self, cond, addr_placeholder, src=''):
        # 2パス用: アドレスは後で解決するためプレースホルダをリストに保存
        idx = len(self._items)
        self._items.append(('JUMP', cond, addr_placeholder, self.pc, src))
        self.pc += 1
    def ret(self, cond=0):  self._add(enc_r(cond,15,12,0,4))

    # ALU R形式
    def add(self,c,rd,rs1,rs2): self._add(enc_r(c,rd,rs1,rs2,4))
    def sub(self,c,rd,rs1,rs2): self._add(enc_r(c,rd,rs1,rs2,5))
    def adc(self,c,rd,rs1,rs2): self._add(enc_r(c,rd,rs1,rs2,6))
    def shr(self,c,rd,rs1):     self._add(enc_r(c,rd,rs1,0,7))
    def nand(self,c,rd,rs1,rs2):self._add(enc_r(c,rd,rs1,rs2,0))
    def ori(self,c,rd,rs1,rs2): self._add(enc_r(c,rd,rs1,rs2,1))
    def andi(self,c,rd,rs1,rs2):self._add(enc_r(c,rd,rs1,rs2,2))
    def xori(self,c,rd,rs1,rs2):self._add(enc_r(c,rd,rs1,rs2,3))
    # ALU I形式
    def addi(self,c,rd,rs,imm): self._add(enc_i(c,rd,rs,imm,4))
    def subi(self,c,rd,rs,imm): self._add(enc_i(c,rd,rs,imm,5))
    def andii(self,c,rd,rs,imm):self._add(enc_i(c,rd,rs,imm,2))
    def adci(self,c,rd,rs,imm): self._add(enc_i(c,rd,rs,imm,6))
    # Load/Store
    def ld(self,c,rd,base,imm,sub=0): self._add(enc_ls(c,rd,base,imm,(0<<1)|sub))
    def st(self,c,rd,base,imm,sub=0): self._add(enc_ls(c,rd,base,imm,(1<<1)|sub))
    # CALL展開: ADDI r12, r15, 1; ADDI r15, r0, target
    def call(self, target_label):
        # r12 = r15 + 1 (Stage2実行時 r15 は次命令アドレス → r12 = 次の次)
        idx = len(self._items)
        self._items.append(('CALL_SAVE', self.pc, target_label, ''))
        self.pc += 1
        self._items.append(('CALL_JUMP', self.pc, target_label, ''))
        self.pc += 1

    # 文字列定数データ
    def string(self, s):
        for ch in s:
            self._add_data(ord(ch), repr(ch))
        self._add_data(0, 'NULL')

    # ================================================================
    # Pass 2: ラベル解決 → コードリスト生成
    # ================================================================
    def resolve(self):
        out = []
        for item in self._items:
            kind = item[0]
            if kind == 'INST':
                out.append(item[1])
            elif kind == 'DATA':
                out.append(item[1])
            elif kind == 'JUMP':
                _, cond, lbl, pc, src = item
                target = self.labels[lbl] if isinstance(lbl, str) else lbl
                out.append(enc_i(cond, 15, 0, target, 4))
            elif kind == 'CALL_SAVE':
                _, pc, lbl, _ = item
                # ADDI r12, r15, 1  (pc+1がCALL_JUMPのアドレス、r15はpc+1を指す→r12=pc+2)
                out.append(enc_i(0, 12, 15, 1, 4))
            elif kind == 'CALL_JUMP':
                _, pc, lbl, _ = item
                target = self.labels[lbl] if isinstance(lbl, str) else lbl
                out.append(enc_i(0, 15, 0, target, 4))
        return out


# ================================================================
# テストプログラム本体
# ================================================================

def build():
    a = Asm()

    # ---------------------------------------------------------
    # 初期化: r9 = 0xFF00 (UART_DATA MMIO アドレス)
    # ---------------------------------------------------------
    a.label('_start')
    a.nand(0, 9, 0, 0)          # r9 = ~0 = 0xFFFF
    a.subi(0, 9, 9, 255)        # r9 = 0xFFFF - 255 = 0xFF00

    # スタートメッセージ
    a.li(1, 0, 'li r1, msg_start')          # 仮: 後で fix
    a.label('_patch_msg_start'); a._items[-1]  # 後でラベル解決
    a.call('print_str')

    # ---------------------------------------------------------
    # Test 1: ALU & フラグ検証
    # ---------------------------------------------------------
    a.label('test_alu')
    # (1) ADD
    a.li(1, 10)
    a.li(2, 5)
    a.add(0, 3, 1, 2)           # r3 = 15
    a.subi(0, 4, 3, 15)         # r4 = 0, Z=1
    a.jump(COND['NE'], 'fail_alu')

    # (2) SUB -> N=1
    a.sub(0, 5, 2, 1)           # r5 = 5-10 = -5, N=1, C=0
    a.jump(COND['PL'], 'fail_alu')  # N=0なら失敗

    # (3) AND
    a.li(1, 0x0F)
    a.li(2, 0x33)
    a.andi(0, 3, 1, 2)          # r3 = 0x03
    a.subi(0, 3, 3, 0x03)
    a.jump(COND['NE'], 'fail_alu')

    # (4) OR
    a.ori(0, 4, 1, 2)           # r4 = 0x3F
    a.subi(0, 4, 4, 0x3F)
    a.jump(COND['NE'], 'fail_alu')

    # (5) XOR
    a.xori(0, 5, 1, 2)          # r5 = 0x3C
    a.subi(0, 5, 5, 0x3C)
    a.jump(COND['NE'], 'fail_alu')

    # (6) NAND
    a.nand(0, 6, 1, 2)          # r6 = ~(0x0F & 0x33) = ~0x03 = 0xFFFC
    a.addi(0, 6, 6, 4)          # r6 = 0xFFFC + 4 = 0x0000, Z=1, C=1
    a.jump(COND['NE'], 'fail_alu')

    # (7) ADC (C=1 のまま)
    a.adc(0, 7, 0, 0)           # r7 = 0+0+1 = 1
    a.subi(0, 7, 7, 1)
    a.jump(COND['NE'], 'fail_alu')

    # (8) SHR & Carry
    a.li(1, 0x05)               # 0b0101
    a.shr(0, 2, 1)              # r2 = 2, C = 1
    a.subi(0, 2, 2, 2)
    a.jump(COND['NE'], 'fail_alu')
    a.jump(COND['NC'], 'fail_alu')  # C=0なら失敗

    # ALU PASS
    a.li(1, 0)  # patch later
    a.label('_patch_msg_alu_pass'); a.call('print_str')
    a.jump(COND['AL'], 'test_mem')

    a.label('fail_alu')
    a.li(1, 0)  # patch later
    a.label('_patch_msg_alu_fail'); a.call('print_str')
    a.jump(COND['AL'], 'test_halt')

    # ---------------------------------------------------------
    # Test 2: Load/Store & 24-bit メモリ転送
    # ---------------------------------------------------------
    a.label('test_mem')
    a.li(1, 200)                # ベースアドレス 200 (データ領域)
    a.li(2, 0x5A)
    a.mov(13, 2)                # r13[7:0] = 0x5A
    a.li(3, 0x12)

    # ST (加算) mem[200+5] = {0x5A, 0x0012}
    a.st(0, 3, 1, 5)

    # ST (減算) mem[200-10] = {0x5A, 0x0077}
    a.li(4, 0x77)
    a.st(0, 4, 1, 10, sub=1)

    # クリア
    a.li(5, 0)
    a.li(13, 0)

    # LD (加算) r5 = mem[200+5]
    a.ld(0, 5, 1, 5)
    a.subi(0, 5, 5, 0x12)
    a.jump(COND['NE'], 'fail_mem')

    # r13[7:0] == 0x5A?
    a.subi(0, 6, 13, 0x5A)
    a.jump(COND['NE'], 'fail_mem')

    # LD (減算) r7 = mem[200-10]
    a.ld(0, 7, 1, 10, sub=1)
    a.subi(0, 7, 7, 0x77)
    a.jump(COND['NE'], 'fail_mem')

    # MEM PASS
    a.li(1, 0)
    a.label('_patch_msg_mem_pass'); a.call('print_str')
    a.jump(COND['AL'], 'test_reg')

    a.label('fail_mem')
    a.li(1, 0)
    a.label('_patch_msg_mem_fail'); a.call('print_str')
    a.jump(COND['AL'], 'test_halt')

    # ---------------------------------------------------------
    # Test 3: 特殊レジスタ & 条件実行
    # ---------------------------------------------------------
    a.label('test_reg')
    # r0 書き込み無視
    a.addi(0, 0, 0, 99)
    a.add(0, 1, 0, 0)           # r1 = r0 = 0のはず
    a.jump(COND['NE'], 'fail_reg')

    # r14 フラグ直読み: SUBI 0-1 -> N=1,C=0,Z=0 -> flags = {N,C,Z} = 4
    a.subi(0, 2, 0, 1)          # r2 = -1 (0xFFFF), N=1
    a.add(0, 3, 14, 0)          # r3 = r14 = 4
    a.subi(0, 3, 3, 4)
    a.jump(COND['NE'], 'fail_reg')

    # r14 書き込み無視
    a.addi(0, 14, 0, 255)       # 試みる (flags -> Z=0,C=0,N=0 = 0に更新)
    a.add(0, 4, 14, 0)          # r4 = r14 = 0 (255でないこと)
    a.jump(COND['NE'], 'fail_reg')

    # 条件付き実行: EQ/NE
    a.li(1, 0)                  # Z=1
    a.addi(COND['NE'], 2, 0, 1) # NE -> スキップ
    a.addi(COND['EQ'], 2, 0, 88)# EQ -> 実行 r2=88
    a.subi(0, 2, 2, 88)
    a.jump(COND['NE'], 'fail_reg')

    # REG PASS
    a.li(1, 0)
    a.label('_patch_msg_reg_pass'); a.call('print_str')

    # 全テスト合格メッセージ
    a.li(1, 0)
    a.label('_patch_msg_all_pass'); a.call('print_str')

    # ---------------------------------------------------------
    # UART Echo モード
    # ---------------------------------------------------------
    a.li(1, 0)
    a.label('_patch_msg_echo'); a.call('print_str')

    a.label('echo_loop')
    a.ld(0, 2, 9, 1)            # r2 = UART_STATUS
    a.andii(0, 3, 2, 2)         # bit1: rx_ready
    a.jump(COND['EQ'], 'echo_loop')  # rx_ready==0 なら待機

    a.ld(0, 4, 9, 0)            # 受信データ読み出し

    a.label('echo_tx_wait')
    a.ld(0, 5, 9, 1)
    a.andii(0, 5, 5, 1)
    a.jump(COND['NE'], 'echo_tx_wait')
    a.st(0, 4, 9, 0)            # エコーバック送信
    a.jump(COND['AL'], 'echo_loop')

    a.label('fail_reg')
    a.li(1, 0)
    a.label('_patch_msg_reg_fail'); a.call('print_str')

    a.label('test_halt')
    a.li(1, 0)
    a.label('_patch_msg_halt'); a.call('print_str')

    a.label('halt_loop')
    a.jump(COND['AL'], 'halt_loop')

    # ---------------------------------------------------------
    # print_str サブルーチン
    # 引数: r1=文字列先頭アドレス
    # 破壊: r2(文字), r3(status)
    # 戻り: r12 (CALLで設定)
    # r9 = 0xFF00 (初期化済み)
    # ---------------------------------------------------------
    a.label('print_str')
    a.label('print_str_next')
    a.ld(0, 2, 1, 0)            # r2 = mem[r1+0] (1文字)
    a.sub(0, 0, 2, 0)           # r0 = r2 - 0, Z=1 if r2==0 (flags更新)
    a.jump(COND['EQ'], 'print_str_done')

    a.label('print_tx_wait')
    a.ld(0, 3, 9, 1)            # r3 = UART_STATUS
    a.andii(0, 3, 3, 1)
    a.jump(COND['NE'], 'print_tx_wait')
    a.st(0, 2, 9, 0)            # 送信
    a.addi(0, 1, 1, 1)          # r1++
    a.jump(COND['AL'], 'print_str_next')

    a.label('print_str_done')
    a.ret()

    # ---------------------------------------------------------
    # 文字列データ領域 (NULL終端)
    # ---------------------------------------------------------
    a.label('msg_start')
    a.string('\r\nK16 CPU ISA+UART Test\r\n')

    a.label('msg_alu_pass')
    a.string('[PASS] ALU\r\n')

    a.label('msg_alu_fail')
    a.string('[FAIL] ALU\r\n')

    a.label('msg_mem_pass')
    a.string('[PASS] MEM\r\n')

    a.label('msg_mem_fail')
    a.string('[FAIL] MEM\r\n')

    a.label('msg_reg_pass')
    a.string('[PASS] REG\r\n')

    a.label('msg_reg_fail')
    a.string('[FAIL] REG\r\n')

    a.label('msg_all_pass')
    a.string('>>> ALL PASS <<<\r\n')

    a.label('msg_echo')
    a.string('Echo mode:\r\n')

    a.label('msg_halt')
    a.string('[HALT]\r\n')

    # ---------------------------------------------------------
    # Pass 2: LI のアドレスパッチ
    # ---------------------------------------------------------
    def patch_li(label_of_li, msg_label):
        """label_of_li が指す _items インデックスの LI 命令を修正"""
        target_pc = a.labels[label_of_li]
        # 実際の _items の pc を探す
        current_pc = 0
        for idx, item in enumerate(a._items):
            if current_pc == target_pc:
                # I形式 LI: enc_i(0, rd=1, rs=0, imm=msg_addr, fk=4)
                msg_addr = a.labels[msg_label]
                assert msg_addr <= 255, f"msg addr {msg_label}={msg_addr} > 255 (8bit limit)"
                # rd は 1 固定
                a._items[idx] = ('INST', enc_i(0, 1, 0, msg_addr, 4), f'LI r1, {msg_label}')
                return
            kind = item[0]
            if kind in ('INST', 'DATA'):
                current_pc += 1
            elif kind in ('JUMP', 'CALL_SAVE', 'CALL_JUMP'):
                current_pc += 1

    # LI パッチを適用
    # _patch_* ラベルが指す直前の INST (LI) を修正
    # ラベルは LI の次の行 (call) に貼っているため -1
    def get_li_pc(patch_label):
        return a.labels[patch_label] - 2  # CALL=2命令, LI はその2つ前

    # ただし print_str の前は call の LI の前に別の形でラベルを置いた
    # 各パッチラベルの pc - 2 が LI の pc
    patches = [
        ('_patch_msg_start',    'msg_start'),
        ('_patch_msg_alu_pass', 'msg_alu_pass'),
        ('_patch_msg_alu_fail', 'msg_alu_fail'),
        ('_patch_msg_mem_pass', 'msg_mem_pass'),
        ('_patch_msg_mem_fail', 'msg_mem_fail'),
        ('_patch_msg_reg_pass', 'msg_reg_pass'),
        ('_patch_msg_all_pass', 'msg_all_pass'),
        ('_patch_msg_echo',     'msg_echo'),
        ('_patch_msg_reg_fail', 'msg_reg_fail'),
        ('_patch_msg_halt',     'msg_halt'),
    ]

    for patch_lbl, msg_lbl in patches:
        target_pc = a.labels[patch_lbl] - 1  # LI は _patch ラベルの1つ前
        msg_addr = a.labels[msg_lbl]
        assert msg_addr <= 255, f"{msg_lbl} addr={msg_addr} > 255"
        # _items を pc カウントして探す
        cur = 0
        for idx, item in enumerate(a._items):
            if cur == target_pc:
                a._items[idx] = ('INST', enc_i(0, 1, 0, msg_addr, 4), f'LI r1, {msg_lbl}({msg_addr})')
                break
            kind = item[0]
            if kind in ('INST', 'DATA', 'JUMP', 'CALL_SAVE', 'CALL_JUMP'):
                cur += 1

    return a


if __name__ == '__main__':
    a = build()
    codes = a.resolve()

    print(f'[INFO] プログラムサイズ: {len(codes)} words')
    for name, addr in sorted(a.labels.items(), key=lambda x: x[1]):
        if not name.startswith('_'):
            print(f'  {addr:4d}  {name}')

    with open('firmware.hex', 'w') as f:
        for code in codes:
            f.write(f'{code:06X}\n')
    print(f'[SUCCESS] firmware.hex 生成完了 ({len(codes)} words)')
