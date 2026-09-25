# 同期BRAM対応 再設計 (Tang Nano 9K向け)

## 概要

元のk16-16bitcpuを **同期BRAM** に対応させる再設計。Tang Nano 9K等のGowin FPGAで実用的にBRAMを使用できるようにする。

## 背景

元の設計は非同期Read RAM (`assign rdata = memory[addr]`) を前提としていた。これは:
- シミュレーションでは動くが、**Gowin FPGAのBRAM (SDP/pROM) に推論されない**
- 64K×24bit = 1.5Mbit を分散RAM (LUT RAM) で実装するとリソース超過
- 実用上BRAM必須 → 同期Read必須 → CPU側の再設計が必要

## 主な変更

### 1. 同期RAM対応 cpu.v 再設計
- **3状態機械**: `S_IDLE` / `S_MEM_RESP` / `S_FLUSH1`
- `fetch_pc` と `ir_addr` を分離し、r15読出しを正確化 (SPEC.md準拠)
- LOAD/STORE時に `prefetch_buf` で次命令を退避 (1サイクルペナルティ)
- 分岐時1サイクルフラッシュ (同期RAM遅延対応)
- MMIO可変レイテンシ対応 (`mem_ready` でstall)

### 2. nonblocking race 修正 (重要バグ修正)
**バグ**: `saved_rd` を S_IDLE→S_MEM_RESP 遷移時に `<= rd` で更新していたが、同じposedgeで `regfile` が `wtaddr` をサンプリングするため、`saved_rd` の更新前の古い値が見えていた。

**修正**: S_IDLE で `wb_rd_latch`, `wb_load_en_latch`, `wb_is_load_r15_latch` を追加。S_MEM_RESP では `saved_*` ではなく `wb_*_latch` を使って wtaddr/wtenable を計算し、nonblocking raceを回避。

### 3. regfile.v
- Write-first bypass **削除** (`ADD r1, r1, r2` で組み合わせループ形成を回避)
- PC (r15) を regfile から分離、CPU側で `fetch_pc` / `ir_addr` として管理
- `pc_cur` 入力で r15読出し時に `ir_addr` を返す
- `pc_hold` 入力削除 (CPU側で直接制御)

### 4. Memory Interface 契約
- `mem_data_req` / `mem_addr` / `mem_wdata` / `mem_we` / `mem_rdata` / `mem_ready`
- 同期RAM: Cycle Nで要求 → Cycle N+1で応答
- MMIO可変レイテンシ対応
- 後のSDRAM/DMA拡張もこのインターフェースで吸収可能

### 5. MMIO サブシステム
- `0xFF00-0xFFFF` (256 word) にMMIOマップ
- LED (0xFF10) / BTN (0xFF20) / Timer (0xFF30-0xFF32) / GPIO (0xFF40-0xFF42) / UART (0xFF00-0xFF03)
- フェッチでMMIOアドレスを指定された場合は NOP (`0x800000`) を返す (MMIO領域は実行不可)
- `memory_subsystem.v` でRAM/MMIO自動ルーティング

### 6. `top.v` 追加
- Tang Nano 9K 向けピン接続
- 27MHz オンボードクロック
- LED 6個、BTN 2個、UART、GPIO ヘッダ

## サイクルタイミング

| ケース | サイクル | ペナルティ |
|---|---|---|
| ALU→ALU | 1/命令 | 0 |
| LOAD→ALU (load-use) | 3 | 1 |
| LOAD→STORE | 4 | 1+1 |
| STORE→LOAD | 4 | 1+1 |
| ALU→r15 (分岐) | 2 | 1 |
| LOAD→r15 (分岐+Load) | 3 | 2 |
| 条件不成立 LOAD/STORE | 1 | 0 |
| back-to-back LOAD → ADD | 5 | 1+1+1 |
| MMIO LOAD | 2+wait | 1+MMIO |

## 検証結果

### iverilog RTL直接検証 (10ケース全PASS)
```
Test 1: ALU → ALU           5/5 PASS
Test 2: LOAD → ALU          3/3 PASS
Test 3: LOAD → STORE        1/1 PASS
Test 4: STORE → LOAD        3/3 PASS
Test 5: ALU → r15 (Branch)  4/4 PASS
Test 6: LOAD → r15          4/4 PASS
Test 7: Conditional LOAD    3/3 PASS
Test 8: back-to-back LOAD   3/3 PASS
Test 9: MMIO LOAD/STORE     2/2 PASS
Test 10: r15 read (PC-rel)  2/2 PASS
ALL TESTS PASSED
```

### LED チカチカ動作確認
ファームウェアを `firmware.hex` としてロードし、LEDがトグルすることを確認。

### Pythonサイクルシミュレータ (10/10 PASS)
RTLと同じ状態機械・信号依存をPythonで模倣し、ロジック検証を実施。

## ファイル構成

```
k16-redesign/
├── docs/
│   ├── memory_interface.md   # Memory Interface 契約書
│   └── mmio_spec.md          # MMIO 仕様書
├── rtl/
│   ├── top.v                 # Gowin合成用トップ (Tang Nano 9K)
│   ├── cpu.v                 # CPU本体 (状態機械+パイプライン, v2修正版)
│   ├── decoder.v             # 命令デコーダ (元から変更なし)
│   ├── cond_check.v          # 条件判定 (元から変更なし)
│   ├── alu.v                 # ALU (元から変更なし)
│   ├── regfile.v             # レジスタファイル (PC分離・bypass削除)
│   ├── ram.v                 # 同期RAM
│   ├── memory_subsystem.v    # RAM+MMIO ルーティング
│   ├── mmio.v                # LED/BTN/UART/Timer/GPIO
│   ├── tb_cpu.v              # ユニットテストベンチ (10ケース)
│   └── tb_blink.v            # LEDチカチカ動作確認用
├── scripts/
│   ├── sim_test.py           # Python サイクル精度シミュレータ
│   └── build_blink.py        # LEDチカチカファームウェア生成
└── README.md
```

## 破壊的変更 (Breaking Changes)

- **RAMが同期Readに変更**: 既存のファームウェアはそのまま動作 (ISA互換)
- **外部インターフェース変更**: `mem_data_req` / `mem_ready` 追加
- **regfile.v の pc_hold 入力削除**: CPU側で fetch_pc を直接制御
- **`top.v` が新規追加**: 既存のtb_cpu.vは `memory_subsystem` を含むため互換性なし

## テスト方法

```bash
# iverilog インストール済みであること
cd k16-redesign
iverilog -g2012 -o build/tb_cpu.vvp \
    rtl/tb_cpu.v rtl/cpu.v rtl/decoder.v rtl/cond_check.v rtl/alu.v \
    rtl/regfile.v rtl/memory_subsystem.v rtl/ram.v
vvp build/tb_cpu.vvp
```

## 今後の拡張

- [ ] Gowin EDA で合成検証 (BRAM推論・タイミング制約)
- [ ] Tang Nano 9K 実機実装
- [ ] UART ブートローダ
- [ ] 拡張命令 (SHL, MUL, 比較命令)
- [ ] 割込み対応 (Timer IRQ, UART RX IRQ)

## チェックリスト

- [x] 同期RAM対応
- [x] 論理2段パイプライン維持
- [x] 全ハザードケース検証 (ALU/LOAD/STORE/分岐/条件付き)
- [x] MMIO基本実装 (LED/BTN/UART/Timer/GPIO)
- [x] nonblocking race 修正
- [x] iverilog RTL直接検証 10/10 PASS
- [x] LEDチカチカ動作確認
- [ ] Gowin合成検証 (実機前に必要)
- [ ] Tang Nano 9K 実機動作確認
