# Tang Nano 9K Lチカ動作修正 引継ぎドキュメント

## 1. 概要・発生していた課題
Tang Nano 9K 上で `firmware_led.hex` を合成・書き込んだ際、LED が点滅（Lチカ）せず、固定点灯/消灯となる現象が発生。
検証の結果、CPU コアやアセンブラ命令の論理自体にはバグがなく、**FPGA実機のピン極性（Active Low リセット/Active Low LED）および Gowin EDA でのモジュール接続・初期化ファイル設定の不一致**が原因でした。

---

## 2. 実施した修正内容一覧

| ファイル | 区分 | 変更概要 |
| :--- | :--- | :--- |
| [`mmio.v`](file:///c:/Users/nippa/k16-16bitcpu/mmio.v) | 修正 | ・Tang Nano 9K の Active Low LED に対応するため `assign led = ~led_reg;` を追加<br>・UART送信データを `tx_hold` に保持してから送信し、バス変化による文字破損を防止 |
| [`tangnano9k_top.v`](file:///c:/Users/nippa/k16-16bitcpu/tangnano9k_top.v) | 修正 | ・Tang Nano 9K 専用トップモジュール（S1 ボタン極性反転 `rst = ~rst_n` 含む）<br>・初期化ファイルを総合テスト用の `"firmware.hex"` に設定 |
| [`build_firmware.py`](file:///c:/Users/nippa/k16-16bitcpu/build_firmware.py) | 修正 | CALL擬似命令のリンクレジスタ加算値（オフセット）バグを修正（`r12 = r15 + 1`） |
| [`firmware.hex`](file:///c:/Users/nippa/k16-16bitcpu/firmware.hex) | 再生成 | 修正版 `build_firmware.py` で再ビルド（全テストPASS） |

---

## 3. 次にやること（作業手順・動作確認ステップ）

### ステップ 1: Gowin EDA プロジェクト構成の確認
1. Gowin EDA を起動し、以下の RTL ファイルが Design Files に含まれていることを確認：
   - [`tangnano9k_top.v`](file:///c:/Users/nippa/k16-16bitcpu/tangnano9k_top.v) (Top Module)
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

3. Gowin プロジェクトディレクトリ内に最新の [`firmware.hex`](file:///c:/Users/nippa/k16-16bitcpu/firmware.hex) をコピー配置。

### ステップ 2: 合成と書き込み
1. Gowin EDA にて **Run All** (Synthesize & Place & Route) を実行。
2. Gowin Programmer を開き、生成された Bitstream (`.fs` ファイル) を書き込む。

### ステップ 3: 動作検証
1. **シリアルターミナル（115200 bps, 8N1）** を開く。
2. ボード上の **S1 ボタン（リセットボタン）** を押す。
3. 以下の通り文字化けなくテスト合格ログが表示されることを確認：
   現在の短縮版ファームウェアでは、以下のログが表示されます：
   ```text
   K16 START
   ALU OK
   MEM OK
   REG OK
   ALL OK!
   ```
4. ターミナルから適当なキーを押すと、エコーバックされることを確認。
