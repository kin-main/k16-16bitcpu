# uart_bubblesort 不具合修正 引き継ぎドキュメント（2026-10-24）

前セッション（uv_bubblesort 動作不具合の調査・修正）の引き継ぎ資料。
作業ディレクトリ: `C:\Users\nippa\k16-16bitcpu`

---

## 1. 状況まとめ

### 1.1 発端
- ユーザーが `uart_bubblesort.k16` が動かないと報告（コミット c5c7066 「firmwareをクイックソートに換えたが動かん」の流れで、quicksort を削除し bubblesort に置き換えた後）。
- 症状(1回目・シミュレータ): プロンプト `[READY] (` の `[` が無限に出続ける。
- 症状(2回目・Tang Nano 9K 実機): `[READY] (3,4,2,1,5)` とエコーした後、ソート結果が出ない（完全沈黙）。

### 1.2 調査に使用したツール
- **dist TestCase-based simulator**: `sim_test.py` の `SystemSoC`（cpu.v/alu.v/regfile.v/ram.v/mmio.v/uart.v を模倣するサイクル精度モデル）。
  - UART RX は `soc.uart.inject_rx(byte)` で注入（rx_ready==0 のとき）。
  - TX は `soc.mmio.tx_start_q` / `soc.mmio.tx_hold_q` を見て文字を拾う。
  - 実機相当パラメータ: `SystemSoC(mem, clks_per_bit=234)`（27MHz / 115200bps）。
- デバッグスクリプトは `%TEMP%\opencode\` 配下（debug_bs.py / trace_bs.py / regtrace.py / call_test2.py / dup_check.py / edge_cases.py 等）作成し使用。**削除されている可能性があるため、必要なら再度書き起こすこと**（方法は §4）。

---

## 2. 適用した修正（確定事項）

### 2.1 【根本原因A】CALL のリンク保存方式
- EX 段実行中の命令が `r15` を読むと、**実機 RTL では「実行中命令自身のアドレス A」** が返る。
  - `cpu.v` のフォワーディング: `fwd_data_a = (id_ex_rs1==15) ? id_ex_pc : ...`（`id_ex_pc <= if_id_pc`）。author_memo.md の「r15読出しは実行中命令のアドレス」どおり。
  - 一方 `sim_test.py` は regfile の r15 をオートインクリメント PC として読むため、ライブ値が A+1〜A+3 と文脈依存で揺れ、**RTL と模倣が不一致**。旧「無限 `[`」はこの不一致によるシミュレータのみの現象（旧 `+2` 展開は実機に対しては正しかった）。
- 対策: `r12 = r15 + k` に依存しない**即値リンク方式**に統一（どちらの意味論でも正しい）。
  - `redesign/scripts/k16asm.py`: CALL → `ADDI r12, r0, link` + `ADDI r15, r0, target`（`link = CALL のアドレス + 2`、8bit 制約チェック追加）。
  - `build_firmware.py`: `CALL_SAVE` を上記方式へ（旧 `enc_i(0,12,15,1,4)`、さらにその前は `+2`）。
  - `k16_studio.py` は `k16asm.assemble` 経由のため変更不要。
- RET = `ADD r15, r12, 0` は不変。

### 2.2 【根本原因B】SUB/CMPI の C フラグの向き（ユーザー決定: **RTL 現状維持**）
- 実装（`alu.v`）: `temp = {1'b0,A} - {1'b0,B}`（17bit reg 差）。**A < B で折り返し bit16=1 → C=1 ⇔ A<B（ボロー、x86 流）**。
- 旧ドキュメント（alu.v コメント / README / HANDOVER）は「SUB は Borrow なし」＝ARM 流のように読める表記で、プログラム側は ARM 流前提の `.cs/.nc` を書いていたため分岐が逆になった。
- `uart_bubblesort.k16` 内 8 箇所を RTL 準拠に修正（`.cs ⇔ .nc` 入れ替え）:
  - parse: `CMPI r1,48 → JMP.nc digit_upper`（>= '0' が数字判定）
  - digit_upper: `CMPI r1,58 → JMP.nc delimiter`
  - finish_input: `CMPI r8,2 → JMP.cs print_result`（<2 ならソート省略）
  - print_loop: `CMP r6,r8 → JMP.nc print_done`
  - sort_inner: `CMP r5,r6 → JMP.nc sort_next_pass`
  - ソート比較: `CMP r2,r1 → JMP.nc sort_no_swap`（r2>=r1 で非交換＝昇順）
  - sort_next_pass: `CMP r4,r8 → JMP.nc sort_done`
  - print_dec: `CMPI r1,10 → JMP.cs remainder_ready`
  - 先頭コメントにフラグ規約（C=1 ⇔ A<B）を注記済み。

### 2.3 ドキュメント整合
- `alu.v` コメント（C フラグ意味）、`README.md` §5.2.1、`HANDOVER.md`、`redesign/README.md`（CALL 展開の説明）を更新。
- `redesign/scripts/test_k16asm.py`: CALL エンコード期待値更新中（6/6 PASS）。

### 2.4 生成物の再作成
- `uart_bubblesort.hex` / `uart_bubblesort.lst` / `firmware.hex` を再生成（ルートの k16asm ラッパ → redesign/scripts/k16asm.py を使用）。
- `firmware.hex` 現在の内容＝**バブルソート**（HANDOVER.md が説明する「K16 START … ALL OK!」ではなくなっている点に注意）。

---

## 3. 検証結果（全て PASS）

シミュレータ（`sim_test.SystemSoC`, clks_per_bit=234）:
- `(5,1,4,1,3)` → `[READY] ((5,1,4,1,3)(1,1,3,4,5)\r\n[READY] (` ＋再待機
- `(7)`→`(7)`、`(2,1)`→`(1,2)`、`(9,3,7,1,5)`→`(1,3,5,7,9)`、`(300,25,9)`→`(9,25,300)`、連続2回入力 `(5,4)(1,2)`
- `(3,4,2,1,5)` → `(1,2,3,4,5)`（手打ち相当・ペースト相当どちらも）
- `build_firmware.py` 生成物: `K16 START / ALU OK / MEM OK / REG OK / ALL OK! / ECHO: Z（受信文字エコー）`
- ルート `sim_test.py` 本体テスト: ALL TESTS PASSED
- LD 直後命令の重複実行なし（dup_check で確認。r2=3, r1=200）

---

## 4. 最重要: 未完了タスク（実機が沈黙する件）

> **[2026-10-24 追記]** 実 RTL（iverilog）で原因を再現しました。詳細は **`HANDOVER_UART_RX.md`** を参照。
> 一言でいうと「プロンプト送信中／エコー中に届いた RX 文字が、1 バイトしか持てない受信バッファで取りこぼされる」。
> 送信側が `[READY] (` の表示完了を待たずに打ち始めると `(` が落ちて `wait_open` で固まる。
> 対策は UART RX FIFO の追加。以下の「旧ファーム」仮説はこの追記で置き換え。

**現状**: 実機で `[READY] (3,4,2,1,5)` エコー後、ソート結果が出ない（リポジトリの新ファーム未書き込みの場合の予測症状と完全一致）。
シミュレータでは同入力が正常のため、**ボードが旧ファームのまま**が濃厚。

### 手順（ユーザーへ依頼済み、応答待ち）
1. Gowin プロジェクト内の `firmware.hex` をリポジトリ最新版にコピー。
   - 確認目印: 1 行目 `050000`、CALL 部分が `0E00C4`（= `ADDI r12, r0, 0x18` 即値リンク）/ `0F8654`（JMP 0xCA）。
2. **合成からやり直し（Run All）→ `.fs` 再書き込み**（INIT_FILE 変更は再合成必須、旧ビットの再プログラムでは反映されない）。
3. `)` まで入力 → 1 秒以内に `(1,2,3,4,5)` が出るはず。

### それでも沈黙する場合の次のアクション
- **iverilog 未導入**（コマンド不在確認済み）。インストールして実 RTL を UART シリアル注入で直接検証する:
  - tb 方針: `k16_soc` を `CLKS_PER_BIT=234`, `INIT_FILE="firmware.hex"` でインスタンスし、UART RX ラインに 234 サイクル/ビットで `start(0)+8 データビット(LSB first)+stop(1)` を手動生成して `(3,4,2,1,5)` を送る。TX ラインをサンプリングして文字を記録、沈黙箇所を `u_soc.u_cpu` 階層参照（tb_cpu_debug.v の手法、`if_id_pc` / `id_ex_pc` / `u_regfile.regs[15]` 等）で特定する。
  - 重点疑念: このプロジェクトの検証は sim_test（Python 模倣）＋tb（シミュレータ経由の別物）で、**実 RTL に対する独立検証が弱い**。RTL と sim の差分が原因になる箇所の列挙は §5。

---

## 5. 後続エージェントが知っておくべき技術メモ

### 5.1 CPU の意味論（実 RTL 基準）
- **r15 の EX 読み出し = 実行中命令自身のアドレス A**（`fwd_data_a` の `rs1==15 → id_ex_pc` 特別扱い）。
  - regfile 内部の `regs[15]` は「次のフェッチアドレス（オート +1、`pc_hold` で保持、分岐は明示書込み）」であり、EX 経由で読ませない設計。
  - **`sim_test.py` はこれを正しく模倣していない**。再現性重視なら sim 側の forwarding に `rs1==15 → 命令アドレス` を入れ、regfile 自動 +1 のモデルを修正すべき（その際旧 CALL `+2` が実機で正に戻るが、即値リンク方式はそのまま有効）。
- **SUB の C = 1 ⇔ A < B**（17bit 減算折り返し＝ボロー）。ADD/ADC は temp[16]、SHR は A[0]、論理演算は保持。
- CALL 現行展開: `ADDI r12, r0, A+2` / `ADDI r15, r0, target`（即値リンク）。target・link とも 8bit（0〜255）制限。

### 5.2 プロジェクト構成メモ（全体診断結果）
- ルート側（`cpu.v` + `tangnano9k_top.v`）が現行主系、`redesign/` は同期 BRAM 再設計（PC 分離、mem_req/ready、Timer/GPIO 拡張）で「主実装候補」耘※2 つの系統で sim_test / tb_cpu が同名別物で重複。
- 整備候補（前回指摘済み):
  - README「RAM: 0x0000–0xFEFF（64K）」対 ram.v 実体 16K（addr[13:0]）の表記ゆれ。
  - `redesign/build/firmware*.hex` が git 管理対象（.gitignore の意図と矛盾）。
  - `k16disasm.py` 等に UTF-8/CP932 文字化けコメント。
  - `firmware.hex` 内容と HANDOVER.md の確認ログが不一致（今はバブルソート）。
- `CLKS_PER_BIT`: 実機は tangnano9k_top.v から 234 を正しく渡している（k16_soc/uart の既定 868 は 100MHz 用で、TB は独自値）。

### 5.3 デバッグ手法の再現方法（スクリプトが消えていても書ける）
```python
import sys
sys.path.insert(0, r"C:\Users\nippa\k16-16bitcpu")
from sim_test import SystemSoC

mem = {i: int(l,16) for i,l in enumerate(open("uart_bubblesort.hex").read().split()) if l}
soc = SystemSoC(mem, clks_per_bit=234)
out = []
for cycle in range(400000):
    if soc.mmio.tx_start_q:
        out.append(chr(soc.mmio.tx_hold_q))
    if inbuf and soc.uart.rx_ready == 0:
        soc.uart.inject_rx(inbuf.pop(0))   # inbuf = list(b"(5,1,4,1,3)")
    soc.step()
print(repr("".join(out)))
```
- 命令単位トレース: `soc.id_ex_addr`（計測用に command が同行）と `k16disasm.disassemble_word(mem[addr])` を組み合わせる。
- レジスタ書込トレース: `soc.rf.write` をラップして (wtaddr, wtdata, soc.id_ex_addr) を記録。
- EX 段の r15 ライブ値を実測したい場合: `r12` への書込み値から逆算（`wtdata - imm`）。

### 5.4 git 状態（セッション終了時点）
- 修正済み・コミット未: `alu.v`, `build_firmware.py`, `README.md`, `HANDOVER.md`, `redesign/README.md`, `redesign/scripts/k16asm.py`, `redesign/scripts/test_k16asm.py`, `firmware.hex`, `uart_bubblesort.{k16,hex,lst}`（未追跡→追加推奨）。
- ユーザー自身の変更（触っていない）: `k16_studio.py`（大規模変更）, `quicksort.*`, `uart_quicksort.k16` 削除。
- 本ドキュメント自体も未コミット。

---

## 6. 開始時に伝えるべき一文（次セッション用）

> uart_bubblesort は CALL の即値リンク化と SUB/C フラグ方向の整合（RTL: C=1⇔A<B）でシミュレータ全ケース PASS。未確定は**実機が `)` 入力後に沈黙**することで、第一仮説は「Gowin プロジェクトの firmware.hex が旧版のまま（再合成未実施）」。ユーザーに最新 hex 再合成・再書き込みを確認し、それでも沈黙なら iverilog を入れて実 RTL を UART 注入でトレースし、sim_test の r15 模倣差異を含めた RTL との不一致を特定すること。
