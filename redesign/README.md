# k16 memo準拠実装（同期RAM対応）

このディレクトリは、初期の `author's memo` にあるk16のISA・レジスタ構成・
2段パイプラインを基準にした実装です。

初期スケッチの意図は維持しつつ、FPGAで実際に動かすために必要な同期RAMの
1クロック遅延、Load応答待ち、分岐フラッシュ、RAWハザードをCPU側で処理します。
これらはISAの変更ではなく、メモリ実装に起因する補正です。仕様の根拠と修正点は
`docs/author_memo.md` にまとめています。

## 固定するISA

- 16-bitデータパス、24-bit固定長命令
- 16-bitアドレス
- 条件実行 `AL / NE / NC / PL / NV / EQ / CS / MI`
- 2段パイプライン
- `r0` はゼロ、`r1`〜`r12` は汎用、`r13` はメモリ上位バイト、
  `r14` はフラグ、`r15` はPC
- ALU: `NAND / OR / AND / XOR / ADD / SUB / ADC / SHR`
- Load/Store: 9-bit即値によるベース加算・減算
- 24-bit転送: `{r13[7:0], 16-bit data}`

命令ビット配置は初期メモのままです。

```text
レジスタ間: cond(3) | op=00 | rd(4) | rs1(4) | rs2(4) | unused(4) | funct(3)
即値演算:   cond(3) | op=01 | rd(4) | rs(4)  | imm(8)  | funct(3)
Load/Store:  cond(3) | op=11 | rd(4) | base(4)| imm(9)  | funct(2)
```

## 同期メモリインターフェース

CPUとメモリは単一ポートのインターフェースで接続します。

```text
CPU -> MEM: mem_data_req, mem_addr, mem_wdata, mem_we
MEM -> CPU: mem_rdata, mem_ready
```

要求をサイクルNに出し、応答をサイクルN+1以降に受け取ります。
`mem_ready=0` の間はCPUがデータ要求を保持します。

内部状態は次の3つだけです。

- `S_IDLE`: 通常命令の実行、フェッチ、データ要求の発行
- `S_MEM_RESP`: LOAD/STOREの応答待ちとLOAD書き戻し
- `S_FLUSH1`: 分岐後の古い命令を破棄

## メモリ容量

ISAのアドレス幅は16-bitですが、Tang Nano 9KのBRAM容量に合わせ、
現在のプラットフォーム実装は `RAM_ADDR_WIDTH=14`（16Kワード）です。
したがって、実機の有効RAM範囲は `0x0000〜0x3FFF` です。
`0xFF00〜0xFFFF` はMMIOに予約しています。

これは以前のドキュメントにあった「`0x0000〜0xFEFF` がRAM」という記述を
実装に合わせて修正したものです。アドレスを折り返して別のRAMを参照する動作は
許可しません。

## MMIO

MMIOはISA外のプラットフォーム拡張です。現在の実装ではUART、LED、ボタン、
タイマ、GPIOを提供します。詳細は `docs/mmio_spec.md` を参照してください。
CPUコアはMMIOの個別機能を知らず、`mem_ready` だけを見て待機します。

## 検証

アセンブラ:

```powershell
cd redesign
python scripts\k16asm.py examples\hello.k16 -o build\hello.hex --depth 16384 --listing build\hello.lst
```

引数なしで起動すると、説明を表示したあと `input()` で1命令を受け取り、
24-bit HEXを `print` します。

```powershell
python scripts\k16asm.py
```

命令名には条件サフィックスを付けられます（例: `ADD.eq`、`LD.ne`）。
コメントは `;` または `#` から行末までです。`JMP` と `CALL` のラベルは、
ISAの即値幅に合わせて0〜255ワードに制限しています。
`CALL` は `ADDI r12, r15, 2` と `ADDI r15, r0, target` の2語へ展開されます。
生成されたlistingには、アドレス・24-bit機械語・元ソースが出力されます。

Pythonモデル:

```powershell
cd redesign
python scripts/sim_test.py
```

RTL検証（`iverilog` / `vvp` が必要）:

```powershell
cd redesign
iverilog -g2012 -o build\tb_cpu.vvp `
  rtl\tb_cpu.v rtl\cpu.v rtl\decoder.v rtl\cond_check.v rtl\alu.v `
  rtl\regfile.v rtl\memory_subsystem.v rtl\ram.v
vvp build\tb_cpu.vvp
```

`build/` 内の生成物、`.vvp`、`.vcd`、`__pycache__` は追跡しません。
