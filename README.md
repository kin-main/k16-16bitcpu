# k16 16-bit RISC CPU

FPGA向けに設計された、シンプルで高クロック動作を目指す **16bit RISC CPU**（2段パイプライン）のVerilog-HDL実装です。
KISS原則（Keep It Simple, Stupid）に基づき、必要最小限のシンプルな回路構成で最大の効率と見通しの良さを実現しています。
一部AI使用
このプロジェクトのライセンスはGPL v3です
---

## 1. 主要諸元 (Specifications)

| 項目 | 仕様 | 備考 |
|---|---|---|
| **アーキテクチャ** | 16-bit RISC | FPGA向け最適化・シンプル設計 |
| **パイプライン** | 2段パイプライン | Stage 1: Fetch/Decode, Stage 2: Execute/Mem/WB |
| **命令長** | **24-bit** 固定長 | 全命令に条件実行フィールド（cond）を装備 |
| **データ幅** | **16-bit** | レジスタ・ALU演算幅 |
| **アドレス空間** | **16-bit** (64Kワード) | 24bit幅メモリ空間 |
| **汎用レジスタ** | 16本 (`r0` 〜 `r15`) | 16bit幅、特殊レジスタ含む |
| **条件実行** | 全命令対応 (3bit cond) | Z (Zero), C (Carry), N (Negative) による条件分岐・実行 |
| **ハザード制御** | フォワーディング & フラッシュ | RAWハザード回避バイパス、分岐時1サイクルバブル |

---

## 2. システムブロック図 (Architecture Block Diagram)

```mermaid
graph TD
    subgraph S1["Stage 1: Fetch and Decode"]
        PC["PC (r15)"] -->|inst_addr| MEM_INST["命令メモリ (24bit)"]
        MEM_INST -->|inst_data| IR["命令レジスタ IR [23:0]"]
        IR --> DEC["命令デコーダ (decoder.v)"]
    end

    subgraph S2["Stage 2: Execute, Memory and WriteBack"]
        DEC -->|cond| COND["条件判定サブデコーダ (cond_check.v)"]
        DEC -->|rs1, rs2| RF["レジスタファイル (regfile.v) r0-r15"]
        DEC -->|imm| MUX_B["ALU B入力セレクタ"]
        DEC -->|alu_funct| ALU["ALU演算器 (alu.v)"]
        
        RF -->|rddata_a| FWD_A["フォワーディング A"]
        RF -->|rddata_b| FWD_B["フォワーディング B"]
        
        FWD_A --> ALU
        FWD_B --> MUX_B
        MUX_B --> ALU

        ALU -->|Z, C, N| FLAGS["フラグレジスタ (Z, C, N)"]
        FLAGS -.->|zf, cf, nf| COND
        FLAGS -.->|zf, cf, nf| RF

        COND -->|cond_match| CTRL["実行制御 (wtenable / mem_we)"]

        ALU -->|mem_addr| MEM_DATA["データメモリ (24bit)"]
        FWD_B -->|mem_wdata[15:0]| MEM_DATA
        RF -->|topout r13[7:0]| MEM_DATA

        MEM_DATA -->|mem_rdata[15:0]| MUX_WB["WriteBackセレクタ"]
        ALU -->|alu_result| MUX_WB
        MEM_DATA -->|mem_rdata[23:16]| RF

        MUX_WB -->|wtdata| RF
        CTRL -->|wtenable| RF
    end

    RF -->|PC更新| PC
    CTRL -->|分岐フラッシュ| IR
```

---

## 3. レジスタ構成 (Register File)

| レジスタ | 名前 | 役割・動作 |
|---|---|---|
| `r0` | **Zero Register** | 常に `0x0000` を出力。書き込みは無視されます。 |
| `r1` 〜 `r12` | **汎用レジスタ (GPR)** | 16bit 演算・データ処理用レジスタ |
| `r13` | **拡張バイトレジスタ** | 24bit メモリアクセス時の上位8bit (`[23:16]`) を `r13[7:0]` で送受信 |
| `r14` | **フラグレジスタ** | ALUフラグ (`{13'b0, N, C, Z}`) をRead専用で出力。書き込みは無視 |
| `r15` | **プログラムカウンタ (PC)** | 実行中の命令アドレス。明示的な書き込みでジャンプ（分岐） |

---

## 4. 命令フォーマット (Instruction Format)

全命令は **24bit固定長** で、最上位3bitに条件実行フィールド `cond[23:21]` を備えます。

### 1) レジスタ間演算命令 (`op = 00`)
```
23       21 20 19 18    15 14    11 10     7 6      3 2     0
+----------+-----+--------+--------+--------+--------+-------+
| cond (3) | 0 0 | rd (4) | rs1(4) | rs2(4) | unused | funkt |
+----------+-----+--------+--------+--------+--------+-------+
```

### 2) レジスタ即値演算命令 (`op = 01`)
```
23       21 20 19 18    15 14    11 10              3 2     0
+----------+-----+--------+--------+-----------------+-------+
| cond (3) | 0 1 | rd (4) | rs (4) |    im (8bit)    | funkt |
+----------+-----+--------+--------+-----------------+-------+
```

### 3) ロード / ストア命令 (`op = 11`)
```
23       21 20 19 18    15 14    11 10              2 1   0
+----------+-----+--------+--------+-----------------+-----+
| cond (3) | 1 1 | rd (4) | base(4)|    im (9bit)    |funkt|
+----------+-----+--------+--------+-----------------+-----+
```

---

## 5. 命令一覧 (Instruction Set)

### 条件実行フィールド (`cond[23:21]`)
| cond | アセンブリ | 実行条件 | 説明 |
|---|---|---|---|
| `000` | (なし) / AL | 常に実行 (Always) | 無条件実行 |
| `001` | NE | `Z == 0` | ゼロでない (Not Equal) |
| `010` | NC | `C == 0` | キャリーなし (No Carry) |
| `011` | PL | `N == 0` | 正またはゼロ (Plus) |
| `100` | NV | 実行しない (Never) | NOP (No Operation) |
| `101` | EQ | `Z == 1` | ゼロ (Equal) |
| `110` | CS | `C == 1` | キャリーあり (Carry Set) |
| `111` | MI | `N == 1` | 負数 (Minus) |

### ALU演算 (`funkt[2:0]`, `op = 00 / 01`)
| funkt | 演算 | 動作説明 | フラグ変化 |
|---|---|---|---|
| `000` | **NAND** | `rd = ~(A & B)` | Z, N |
| `001` | **OR** | `rd = A \| B` | Z, N |
| `010` | **AND** | `rd = A & B` | Z, N |
| `011` | **XOR** | `rd = A ^ B` | Z, N |
| `100` | **ADD** | `rd = A + B` | Z, C, N |
| `101` | **SUB** | `rd = A - B` (`A + ~B + 1`) | Z, C, N |
| `110` | **ADC** | `rd = A + B + C` | Z, C, N |
| `111` | **SHR** | `rd = A >> 1` (論理右シフト, C = A[0]) | Z, C, N |

### ロード / ストア (`funkt[1:0]`, `op = 11`)
| funkt | 命令 | 動作説明 | 24bitデータ転送 |
|---|---|---|---|
| `00` | **LD (加算)** | `rd = mem[base + im]` | `rd <= mem[15:0]`, `r13[7:0] <= mem[23:16]` |
| `01` | **LD (減算)** | `rd = mem[base - im]` | `rd <= mem[15:0]`, `r13[7:0] <= mem[23:16]` |
| `10` | **ST (加算)** | `mem[base + im] = {r13[7:0], rd}` | `mem[15:0] <= rd`, `mem[23:16] <= r13[7:0]` |
| `11` | **ST (減算)** | `mem[base - im] = {r13[7:0], rd}` | `mem[15:0] <= rd`, `mem[23:16] <= r13[7:0]` |

---

## 6. ファイル構成 (File Structure)

```
k16-16bitcpu-1/
├── README.md        # 本書（概要・仕様・構成）
├── SPEC.md          # 詳細仕様書
├── alu.v            # 16bit 算術論理演算器 (ALU)
├── regfile.v        # 16bit×16本 レジスタファイル
├── decoder.v        # 24bit 命令デコーダ
├── cond_check.v     # 条件判定サブデコーダ
├── cpu.v            # 2段パイプライン CPUトップモジュール
├── ram.v            # 24bit幅 シミュレーション用メモリ
├── tb_cpu.v         # Verilog テストベンチ
├── sim_test.py      # サイクル精度検証 Python スクリプト
└── author’s memo/   # 設計構想スケッチ・原案画像
```

---

## 7. シミュレーション & 動作検証 (Simulation)

Pythonによるサイクル精度シミュレータが同梱されており、Verilogの論理と完全一致するテストを即座に実行できます。

```bash
python3 sim_test.py
```

### 検証結果例:
```
=== k16 CPU シミュレーション検証結果 ===
[PASS] r1 (分岐先実行 ADD 10+1): 11 (期待値: 11)
[PASS] r2 (NAND ~11): 65524 (期待値: 65524)
[PASS] r3 (ADD 10+5): 15 (期待値: 15)
[PASS] r4 (SUB 0-50 -> -50, N=1): 65486 (期待値: 65486)
[PASS] r5 (N==1条件成立実行 -> 123): 123 (期待値: 123)
[PASS] r6 (N==0条件不成立スキップ 200にならず15を維持): 15 (期待値: 15)
[PASS] r8 (減算Load & SHR検証 -> 99): 99 (期待値: 99)
[PASS] r10 (条件成立実行 Z==1 -> 77): 77 (期待値: 77)
[PASS] r11 (条件不成立スキップ Z==0 -> 0): 0 (期待値: 0)
[PASS] r12 (Load & 分岐フラッシュ成功 -> 15): 15 (期待値: 15)
[PASS] mem[12] (Store {0x5A, 15} -> 0x5A000F): 5898255 (期待値: 5898255)
[PASS] mem[10] (減算Store {0x77, 99} -> 0x770063): 7798883 (期待値: 7798883)
[PASS] r13[7:0] (減算Load時上位8bit -> 0x77): 119 (期待値: 119)

>>> 全てのテストに合格しました！ (ALL TESTS PASSED) <<<
```
