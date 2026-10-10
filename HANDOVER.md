# Tang Nano 9K Lチカ動作修正 引継ぎドキュメント

## 1. 概要・発生していた課題
Tang Nano 9K 上で `firmware_led.hex` を合成・書き込んだ際、LED が点滅（Lチカ）せず、固定点灯/消灯となる現象が発生。
検証の結果、CPU コアやアセンブラ命令の論理自体にはバグがなく、**FPGA実機のピン極性（Active Low リセット/Active Low LED）および Gowin EDA でのモジュール接続・初期化ファイル設定の不一致**が原因でした。

---

## 2. 実施した修正内容一覧

| ファイル | 区分 | 変更概要 |
| :--- | :--- | :--- |
| [`mmio.v`](file:///c:/Users/nippa/k16-16bitcpu/mmio.v) | 修正 | Tang Nano 9K の Active Low LED に対応するため `assign led = ~led_reg;` を追加 |
| [`k16_soc.v`](file:///c:/Users/nippa/k16-16bitcpu/k16_soc.v) | 修正 | デフォルトパラメータ `INIT_FILE` を `"firmware_led.hex"` に変更 |
| [`tangnano9k_top.v`](file:///c:/Users/nippa/k16-16bitcpu/tangnano9k_top.v) | 新規 | Tang Nano 9K 専用トップモジュール（S1 ボタン極性反転 `rst = ~rst_n` 含む） |
| [`tangnano9k.cst`](file:///c:/Users/nippa/k16-16bitcpu/tangnano9k.cst) | 新規 | Gowin EDA 用 Physical Constraint ピン配置制約ファイル |
| [`firmware_led.hex`](file:///c:/Users/nippa/k16-16bitcpu/firmware_led.hex) | 再生成 | 最新の `build_led_blink.py` スクリプトでビルド |

---

## 3. 次にやること（作業手順・動作確認ステップ）

### ステップ 1: Gowin EDA プロジェクト構成の確認
1. Gowin EDA を起動し、以下の RTL ファイルを Design Files に追加：
   - [`tangnano9k_top.v`](file:///c:/Users/nippa/k16-16bitcpu/tangnano9k_top.v) (Top Module に設定)
   - [`k16_soc.v`](file:///c:/Users/nippa/k16-16bitcpu/k16_soc.v)
   - [`cpu.v`](file:///c:/Users/nippa/k16-16bitcpu/cpu.v)
   - [`mmio.v`](file:///c:/Users/nippa/k16-16bitcpu/mmio.v)
   - [`ram.v`](file:///c:/Users/nippa/k16-16bitcpu/ram.v)
   - [`regfile.v`](file:///c:/Users/nippa/k16-16bitcpu/regfile.v)
   - [`alu.v`](file:///c:/Users/nippa/k16-16bitcpu/alu.v)
   - [`decoder.v`](file:///c:/Users/nippa/k16-16bitcpu/decoder.v)
   - [`cond_check.v`](file:///c:/Users/nippa/k16-16bitcpu/cond_check.v)
   - [`uart.v`](file:///c:/Users/nippa/k16-16bitcpu/uart.v)

2. Physical Constraints に [`tangnano9k.cst`](file:///c:/Users/nippa/k16-16bitcpu/tangnano9k.cst) を指定。

3. Gowin プロジェクトディレクトリ内に [`firmware_led.hex`](file:///c:/Users/nippa/k16-16bitcpu/firmware_led.hex) が配置されていることを確認。

### ステップ 2: 合成と書き込み
1. Gowin EDA にて **Run All** (Synthesize & Place & Route) を実行。
2. Gowin Programmer を開き、生成された Bitstream (`.fs` ファイル) を SRAM または Embedded Flash に書き込む。

### ステップ 3: 動作検証
1. **LED 点滅の確認**: Tang Nano 9K のオンボード LED (LED1〜LED6) が 0.5 秒ON / 0.5 秒OFF の周期でチカチカ点滅することを確認する。
2. **UART 送信の確認**: シリアルターミナル（115200 bps, 8N1）を開き、0.5 秒ごとに `'H'` と `'L'` が交互に受信されることを確認する。
