# k16 同期RAM対応 再設計案 (2段パイプライン+状態機械アプローチ)

## 概要

このディレクトリは、upstream の neumann ブランチ (3段パイプライン IF/ID/EX) とは
**別アプローチ** での同期BRAM対応実装案です。

- **upstream (neumann)**: 3段パイプライン (IF/ID/EX) + load_stall
- **本提案 (redesign)**: 2段パイプライン + 状態機械 (S_IDLE/S_MEM_RESP/S_FLUSH1)

両者は同じ問題（同期RAMの1-cycle latency対応）に取り組んだ別解法。
KISS原則の観点から、2段+状態機械でどこまでいけるかを検証したもの。

## 比較

| 項目 | upstream (neumann) | redesign (本提案) |
|---|---|---|
| パイプライン段数 | 3段 (IF/ID/EX) | 2段+状態機械 |
| LOAD ペナルティ | load_stall 1サイクル | S_MEM_RESP 1サイクル |
| 分岐フラッシュ | 2サイクル (3段のため) | 1サイクル (S_FLUSH1) |
| ハザード制御 | フォワーディング多重 | prev_wtaddr シンプル |
| ファイル構成 | cpu.v 単体 | cpu.v + memory_subsystem.v |
| MMIO | mmio.v, k16_soc.v 別管理 | memory_subsystem.v で統一 |

## 検証結果

- iverilog RTL直接検証: 10/10 PASS
- Pythonサイクルシミュレータ: 10/10 PASS
- LEDチカチカ動作: PASS

## ファイル構成

```
redesign/
├── README.md                 # このファイル
├── PULL_REQUEST.md           # PR本文
├── docs/
│   ├── memory_interface.md   # Memory Interface 契約書
│   └── mmio_spec.md          # MMIO 仕様書
├── rtl/
│   ├── top.v                 # Gowin合成用トップ
│   ├── cpu.v                 # CPU本体 (状態機械+パイプライン)
│   ├── decoder.v             # 命令デコーダ
│   ├── cond_check.v          # 条件判定
│   ├── alu.v                 # ALU
│   ├── regfile.v             # レジスタファイル (PC分離・bypass削除)
│   ├── ram.v                 # 同期RAM
│   ├── memory_subsystem.v    # RAM+MMIO ルーティング
│   ├── mmio.v                # LED/BTN/UART/Timer/GPIO
│   ├── tb_cpu.v              # ユニットテストベンチ (10ケース)
│   └── tb_blink.v            # LEDチカチカ動作確認用
├── scripts/
│   ├── sim_test.py           # Python サイクル精度シミュレータ
│   └── build_blink.py        # LEDチカチカファームウェア生成
└── build/
    ├── firmware.hex          # LEDチカチカファームウェア
    └── firmware_sim.hex      # シミュレーション用 (短縮ループ)
```

## 実行方法

```bash
cd redesign
iverilog -g2012 -o build/tb_cpu.vvp \
    rtl/tb_cpu.v rtl/cpu.v rtl/decoder.v rtl/cond_check.v rtl/alu.v \
    rtl/regfile.v rtl/memory_subsystem.v rtl/ram.v
vvp build/tb_cpu.vvp
```

## 比較検討ポイント

本提案を取り込むかどうかは、以下の観点で判断してください:

1. **KISS原則**: 2段+状態機械の方が状態数が少なくシンプル
2. **拡張性**: 3段の方が将来のキャッシュ/分岐予測等を実装しやすい
3. **パフォーマンス**: 分岐ペナルティは2段の方が小さい (1 vs 2サイクル)
4. **コード量**: 2段の方が少ない (cpu.v: 約425行 vs 約500行程度)
5. **既存資産**: neumann は既にSoC統合済み、redesign はCPU単体

**推奨**: redesign は「別案」として参考に留め、neumann を主軸開発継続。
