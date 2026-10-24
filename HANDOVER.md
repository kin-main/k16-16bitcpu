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
| [`build_firmware.py`](file:///c:/Users/nippa/k16-16bitcpu/build_firmware.py) | 修正 | CALL擬似命令のリンクレジスタ保存方式を修正。EX段実行時の r15 生値はパイプラインストールで A+1〜A+3 と変わるため `r12 = r15 + k` では不安定。`ADDI r12, r0, link`（即値リンク）へ変更 |
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

---

## 4. フラグ更新仕様（引継ぎ要点）

RTL（`decoder.v` / `cpu.v` / `alu.v` / `cond_check.v`）に合わせた運用上の要点を以下に固定します。

- フラグ更新対象は、**条件成立した ALU レジスタ演算 / ALU 即値演算のみ**。
- デコード後に実行段へ入った命令について、ALU組み合わせ結果を受け、
  **実行サイクルの `posedge clk`** で `Z/C/N` を更新。
- 更新されたフラグは次命令の条件判定から使用される。
- 条件不成立命令、Load/Store、`r15`（PC）宛てALU演算はフラグを更新しない。
- `Z = (result == 0)`、`N = result[15]`。
- `C` は次の規則:
  - `ADD/SUB/ADC`: `temp[16]`（`SUB` は 17bit 減算の折り返しで **`A<B` なら C=1**＝ボロー発生。x86 流）
  - `SHR`: `A[0]`（シフトアウト）
  - `NAND/OR/AND/XOR`: 保持
- リセットは非同期で `Z/C/N = 0`。
- `r14` は読み出し専用で `{13'b0, N, C, Z}` を返し、書き込みは無視。
