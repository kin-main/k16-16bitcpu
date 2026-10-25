# UART RX 取りこぼし修正 引き継ぎ（2026-10-24）

対象: Tang Nano 9K 実機で `uart_bubblesort` が「入力を受け付けない／固まる」件。
前資料: `HANDOVER_BUBBLESORT.md`（§4 の「旧ファーム」仮説は本資料で上書き）。

作業ディレクトリ: `C:\Users\nippa\k16-16bitcpu`

---

## 0. 結論（先に要点）

**実 RTL（iverilog）で再現・特定済み。原因は UART 受信側の 1 バイトバッファ。**

- `uart.v` の `rx_data` / `rx_ready` は **1 バイト分しか保持できない**。
- プログラムは 1 文字受信するたびに `CALL uart_tx` でエコーし、その間 **約 10 ビット時間（115200bps で約 0.87ms）** CPU が受信を見ない。
- その間に次の文字が届くと、**新しい文字で上書きされて前の文字が消える**（オーバーラン）。
- 起動直後の `[READY] (`（9 文字＝約 7.8ms）送信中に端末が入力を送ると、**先頭の `(` が落ちる**。
  - `wait_open` が `(` を永遠に待つ → 一見「入力を受け付けない」状態。
  - 端末側のローカルエコーが ON だと「入力した文字が表示されている」ように見えるため、余計に混乱する。

**実測（実 RTL）:**

| 条件 | 結果 |
|---|---|
| `[READY] (` の表示完了後、2 ビット間隔で送信 | ✅ `(5,4,3,2,1)(1,2,3,4,5)` → 再プロンプト |
| `[READY] (` の表示完了後、**連続（ペースト相当）** | ✅ 同上（この速度ならぎりぎり追従） |
| `[READY] (` の**送信中に送信開始** | ❌ `[READY] (,3,2,1)` と文字化け → `uart_rx` ポーリング（PC=0x00C2）で永久ループ |

→ **ユーザーはプロンプト表示前に打ち始めた／ペーストした可能性が高い。**
（Arduino シリアルモニタ等は接続直後に送信、Tera Term の貼り付けも即時送信。）

**一時的な回避策（実機ですぐ確認したい場合）**: `[READY] (` が完全に出てから入力する。
それで動くはず（上表 1 行目）。恒久対策は下記 FIFO。

---

## 1. なぜ sim_test で見逃したか

`sim_test.py` の `UARTModel.inject_rx()` を呼ぶ側が

```python
if inbuf and soc.uart.rx_ready == 0:
    soc.uart.inject_rx(inbuf.pop(0))
```

となっており、**「rx_ready が空くまで待つ」＝完璧なフロー制御を仮定**している。
実機のオーバーラン（上書き）をモデル化していないため、シミュレータは常に PASS する。

→ 修正時は `UARTModel` に FIFO（または「rx_ready=1 の間に新規受信したら上書き」）を実装し、
**プロンプト送信中に連続注入するテスト**を追加すること。

---

## 2. 推奨する恒久修正: UART RX FIFO

### 2.1 `uart.v`

16〜32 段のリングバッファを追加する。8bit×16 = 128 フリップフロップで、Tang Nano 9K なら余裕。

概略:

```verilog
localparam RX_FIFO_DEPTH = 16;              // 2 のべき乗
localparam RX_FIFO_AW    = 4;

reg [7:0]  rx_fifo [0:RX_FIFO_DEPTH-1];
reg [RX_FIFO_AW-1:0] rx_wr_ptr, rx_rd_ptr;
reg [RX_FIFO_AW:0]   rx_count;
reg                  rx_overflow;

wire rx_avail = (rx_count != 0);

// RX_STOP 完了時（現在 rx_ready <= 1 にしている箇所）
if (rx_count < RX_FIFO_DEPTH) begin
    rx_fifo[rx_wr_ptr] <= rx_shift_reg;
    rx_wr_ptr          <= rx_wr_ptr + 1'b1;
    rx_count           <= rx_count + 1'b1;
end else begin
    rx_overflow <= 1'b1;   // あふれたら捨てる（ワーストケース）
end

// 読み出し側（rx_clear パルスで 1 個 pop）
if (rx_clear && rx_count != 0) begin
    rx_rd_ptr <= rx_rd_ptr + 1'b1;
    rx_count  <= rx_count - 1'b1;
end

assign rx_data = rx_fifo[rx_rd_ptr];  // 常に先頭を組合せ出力
assign rx_ready = rx_avail;           // 既存名を維持（互換用）
```

注意点:

- `mmio.v` は `rdata <= {16'd0, rx_data}` を **アドレス 0xFF00 を出したサイクルの posedge** で行う。
  FIFO 先頭を組合せで出しておけば、このタイミングのままで正しい。
- `mmio.v` の STATUS `bit1` は `rx_avail`（= `rx_count != 0`）に接続。
- `rx_clear` は現在 `mmio.v` で「0xFF00 を **read**（`!we`）したとき」に 1 サイクルパルス。
  FIFO の pop もこのパルスでよい（CPU は 1 回読むごとに 1 個 pop）。
- できれば STATUS に **overrun (bit2)** を追加し、`rx_overflow` を read-clear するとデバッグが楽。
- `rx_ready` という名前を残すなら `wire` に変更（現在は `output reg`）。テストベンチ互換のため。

### 2.2 深さの目安

- `(5,4,3,2,1)` = 11 文字。プロンプト 9 文字＋入力 11 文字を考えても **16 段で十分**。
- 長い貼り付け（数十文字）も許すなら 32 段。

### 2.3 代替（RTL を触りたくない場合）

- プロンプトの各文字を送る前に `rx_ready` をポーリングして取り込む（プロンプト中の取りこぼしは 1 文字に減るが、ペースト中のエコーで still 落ちる）。
- エコーをやめる／遅延させる（UX 低下）。
→ **FIFO が本筋。**

---

## 3. 再現・検証手順（iverilog は既にインストール済み）

**重要**: `iverilog` は PATH に無い。フルパスを使う。

```
C:\iverilog\bin\iverilog.exe
C:\iverilog\bin\vvp.exe
```

TB はリポジトリ直下に追加済み: `tb_uart_rx.v`（未コミット）。
`firmware.hex` を読むので、**必ずリポジトリ直下で実行**する。

### 3.1 コンパイル

```powershell
C:\iverilog\bin\iverilog.exe -g2012 -o tb_uart_rx.vvp -s tb_uart `
  tb_uart_rx.v cpu.v alu.v regfile.v decoder.v cond_check.v ram.v mmio.v uart.v k16_soc.v
```

### 3.2 実行（モード指定）

```powershell
C:\iverilog\bin\vvp.exe tb_uart_rx.vvp +MODE=0   # プロンプト後に 2bit 間隔
C:\iverilog\bin\vvp.exe tb_uart_rx.vvp +MODE=1   # プロンプト後に連続（ペースト）
C:\iverilog\bin\vvp.exe tb_uart_rx.vvp +MODE=2   # プロンプト送信中に開始（再現）
```

期待（修正前）:

```
MODE=0,1: [READY] ((5,4,3,2,1)(1,2,3,4,5)\r\n[READY] (
MODE=2  : [READY] (,3,2,1)  → PC=0x00C2 で停止（rx_poll）
```

`WARNING: ram.v:14: $readmemh(firmware.hex): Not enough words...` は
`firmware.hex` が 209 語（未パディング）のため出るが、**無害**。

### 3.3 修正後の合格条件

- `MODE=0/1/2` のすべてで `(5,4,3,2,1)` → `(1,2,3,4,5)` が出て再プロンプトに戻る。
- `MODE=2` で文字化けしない（`(` を含む全文字がエコーされる）。

---

## 4. 修正後の作業チェックリスト

1. `uart.v` に FIFO 実装（上記）。
2. `mmio.v` の STATUS bit1 を `rx_avail` に接続。必要なら overrun bit 追加。
3. `tb_uart_rx.v` で MODE=0/1/2 を再実行（`iverilog` フルパス）。
4. `sim_test.py` の `UARTModel` / `MMIOModel` を FIFO 化し、
   **プロンプト中に連続注入する回帰テスト**を追加。
5. `python sim_test.py`（全テスト）と `python redesign\scripts\test_k16asm.py` を再実行。
6. バブルソートの境界ケース（1 要素、2 要素、多桁、連続入力）を再確認。
7. **Gowin で Run All → `.fs` 再書き込み**（RTL 変更なので必須）。
8. 実機で「プロンプト表示前にペースト」して動くことを確認。

---

## 5. 現在のリポジトリ状態（2026-10-24 時点）

- **HEAD = 9e676bd「かりでかりでpush」で、今回の修正群はすべてコミット＆push 済み。**
  - CALL 即値リンク化（`redesign/scripts/k16asm.py` / `build_firmware.py`）
  - バブルソートの C フラグ条件修正（`uart_bubblesort.k16`）
  - ドキュメント整合（`README.md`, `ISA_GUIDE.md`, `SPEC.md`, `HANDOVER.md`, `redesign/README.md`, `redesign/rtl/alu.v`, `alu.v`）
  - `SPEC.md` に残っていた**未解決コンフリクトマーカーを解消**（`<<<<<<<` / `=======` / `>>>>>>>` を削除し、両側の内容を統合。C フラグ記述も `A<B で 1` に修正）
  - `firmware.hex` = バブルソート版（209 語）
- **未追跡**: `tb_uart_rx.v`（本資料の再現 TB）、`HANDOVER_UART_RX.md`（本資料）
- 作業ツリーに他に未コミット変更なし。
- `git push` はこのエージェントからは実行できない（認証情報なし）。必要ならユーザーが実行。

---

## 6. 次セッション開始時の一文

> `uart_bubblesort` の実機不調は、実 RTL（`C:\iverilog\bin`）で「UART RX の 1 バイトバッファ取りこぼし」と特定済み。
> `tb_uart_rx.v` の `+MODE=2`（プロンプト送信中に入力開始）で再現する。`uart.v` に RX FIFO（16 段）を追加し、`mmio.v` の STATUS bit1 を FIFO 有効に接続。`sim_test.py` の UART モデルも FIFO 化して、`+MODE=0/1/2` と全回帰テストを通す。最後に Gowin で再合成・再書き込み。
