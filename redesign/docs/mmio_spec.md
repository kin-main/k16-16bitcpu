# k16 MMIO 仕様書

## 1. アドレスマップ概要

| アドレス範囲 | サイズ | 用途 |
|---|---|---|
| `0x0000 - 0xFEFF` | 65,280 word | RAM（命令・データ共用） |
| `0xFF00 - 0xFFFF` | 256 word | **MMIO** |

MMIO領域は下位8bitでレジスタを識別。

## 2. MMIO レジスタマップ

| アドレス | 名称 | R/W | 幅 | 説明 |
|---|---|---|---|---|
| `0xFF00` | `UART_TX` | W | 8 | UART送信データ（下位8bit有効） |
| `0xFF01` | `UART_RX` | R | 8 | UART受信データ（下位8bit有効） |
| `0xFF02` | `UART_STATUS` | R | 3 | `{1'b0, TX_READY, RX_READY}` |
| `0xFF03` | `UART_BAUD` | R/W | 16 | ボーレート分周値 |
| `0xFF10` | `LED` | R/W | 16 | LED出力（16bit） |
| `0xFF20` | `BTN` | R | 4 | ボタン入力 `{3'b0, BTN0, BTN1, BTN2}` |
| `0xFF30` | `TIMER_CTRL` | W | 1 | `0`=停止, `1`=開始 |
| `0xFF31` | `TIMER_CNT` | R | 16 | タイマ現在値（読み出しでクリア可） |
| `0xFF32` | `TIMER_CMP` | R/W | 16 | タイマ比較値（一致でIRQ） |
| `0xFF40` | `GPIO_OUT` | R/W | 16 | GPIO出力 |
| `0xFF41` | `GPIO_IN` | R | 16 | GPIO入力 |
| `0xFF42` | `GPIO_DIR` | R/W | 16 | GPIO方向（0=入力, 1=出力） |

## 3. 各ペリフェラル仕様

### 3.1 UART (0xFF00-0xFF03)

#### UART_TX (0xFF00, Write-only)

```
STORE [r_base + offset], r_data
```

- `r_data[7:0]` をUART送信バッファに書き込む
- 書き込み後、`UART_STATUS[TX_READY]` が `0` になる
- 送信完了後、`TX_READY` が `1` に戻る
- **レイテンシ**: 1 baud周期（ボーレートに依存）

#### UART_RX (0xFF01, Read-only)

```
LOAD r_dest, [r_base + offset]
```

- 受信データの下位8bitを `r_dest` に格納
- 読み出し後、`RX_READY` が `0` になる
- 新しい受信データがあると `RX_READY` が `1` になる
- **レイテンシ**: 1サイクル（同期レジスタ読み出し）

#### UART_STATUS (0xFF02, Read-only)

```
bit 0: RX_READY (1 = 受信データあり)
bit 1: TX_READY (1 = 送信可能)
bit 2-23: 0
```

- **レイテンシ**: 1サイクル

#### UART_BAUD (0xFF03, Read/Write)

- ボーレート分周値。`clk_freq / baud_rate - 1` を設定
- 例: 27MHz / 115200 = 234 → 233を設定

### 3.2 LED (0xFF10)

```
STORE [r_base + 0xFF10 - r_base], r_val   ; LED = r_val[15:0]
LOAD  r_dest, [r_base + 0xFF10 - r_base]  ; r_dest = LED
```

- 16bit LED出力。Tang Nano 9KのオンボードLEDに接続
- **レイテンシ**: 1サイクル（書き込み即時反映、読み出し1サイクル）

### 3.3 Button (0xFF20)

```
LOAD r_dest, [r_base + 0xFF20 - r_base]   ; r_dest = {3'b0, BTN2, BTN1, BTN0}
```

- 読み出し専用。ボタンの現在状態を返す
- 押下 = 1, 開放 = 0
- **レイテンシ**: 1サイクル
- **チャタリング**: ハードウェアで10msデバウンス推奨

### 3.4 Timer (0xFF30-0xFF32)

#### TIMER_CTRL (0xFF30, Write-only)

```
bit 0: TIMER_ENABLE (1 = カウント開始, 0 = 停止・リセット)
```

#### TIMER_CNT (0xFF31, Read-only)

- 16bitダウンカウンタ現在値
- `TIMER_CMP` に一致したら0にリセットされ、IRQ発生
- **レイテンシ**: 1サイクル

#### TIMER_CMP (0xFF32, Read/Write)

- タイマ比較値。0〜65535
- デフォルト = 0xFFFF

### 3.5 GPIO (0xFF40-0xFF42)

#### GPIO_OUT (0xFF40, R/W)

- GPIO出力レジスタ。`GPIO_DIR[n]=1` のピンから出力

#### GPIO_IN (0xFF41, Read-only)

- GPIO入力レジスタ。`GPIO_DIR[n]=0` のピンから入力

#### GPIO_DIR (0xFF42, R/W)

- ピン方向設定。`0` = 入力, `1` = 出力
- デフォルト = 0x0000（全ピン入力）

## 4. MMIOアクセスのタイミング契約

### 4.1 1-cycle レスポンス（LED, BTN, GPIO, Timer, UART_STATUS/RX）

```
Cycle N  : CPU が mem_data_req=1, mem_addr=MMIO_ADDR を駆動
Cycle N+1: MMIO が mem_rdata=レジスタ値, mem_ready=1 を駆動
```

RAMと同じ1サイクルレスポンス。CPUからはRAMと区別不要。

### 4.2 可変レイテンシ（UART_TX送信中）

```
Cycle N    : CPU が STORE [UART_TX], r_val を発行
Cycle N+1  : MMIO が mem_ready=1（書き込み受付完了）
             送信開始（非同期、バックグラウンド実行）
Cycle N+2〜: CPU は次命令を実行可能
             TX_READY=0 の間、次のTX書き込みは上書き or ストール推奨
```

**CPU側はmem_readyを待つだけで、ペリフェラルの内部状態を知る必要がない。**

### 4.3 MMIO LOAD待ち（将来の拡張: SDRAM等）

```
Cycle N    : CPU が LOAD [MMIO_ADDR] を発行
Cycle N+1  : MMIO が mem_ready=0（まだデータ未確定）
             CPU は S_MEM_RESP で保持
Cycle N+k  : MMIO が mem_ready=1, mem_rdata=データ
             CPU がデータをキャプチャし、S_IDLEへ遷移
```

## 5. プログラミング例

### 5.1 LED点灯

```asm
; r1 = 0xFF10 (LED アドレス)
ADDI r1, r0, 0xFF10
; r2 = 0x0001 (LED0 点灯)
ADDI r2, r0, 1
; LED = r2
ST [r1 + 0], r2
```

### 5.2 UART送信（ポーリング）

```asm
; r1 = 0xFF02 (UART_STATUS)
; r2 = 0xFF00 (UART_TX)
; r3 = 送信データ 'A' = 0x41
ADDI r1, r0, 0xFF02
ADDI r2, r0, 0xFF00
ADDI r3, r0, 0x41

wait_tx:
    LD r4, [r1 + 0]      ; r4 = UART_STATUS
    AND r4, r4, 2         ; TX_READY bit抽出
    EQ r4, r4, 0          ; Z = (r4==0)?
    BEQ wait_tx           ; TX_READY=0 なら待機

ST [r2 + 0], r3           ; UART_TX = r3
```

### 5.3 タイマ割込み設定

```asm
; 1秒ごとのIRQ（27MHz / 65536 ≈ 412Hz → 65536カウント）
ADDI r1, r0, 0xFF30   ; TIMER_CTRL
ADDI r2, r0, 0xFF32   ; TIMER_CMP
ADDI r3, r0, 0xFFFF   ; 比較値
ST [r2 + 0], r3       ; TIMER_CMP = 0xFFFF
ADDI r3, r0, 1
ST [r1 + 0], r3       ; TIMER_CTRL = 1 (開始)
```

## 6. Memory Subsystem実装要件

Memory Subsystem (`memory_subsystem.v`) は以下を満たすこと:

1. `mem_addr[15:8] == 0xFF` のときMMIO、それ以外はRAMへルーティング
2. フェッチ（`mem_data_req=0`）でMMIOアドレスを指定された場合、NOP (`0x800000`) を返す
3. RAM・MMIOともに `mem_rdata` は **1サイクル遅延で出力**（同期Read）
4. `mem_ready` は RAM=常時1、MMIO=ペリフェラル依存
5. MMIOモジュールへのインターフェースは下位8bitアドレス + 24bitデータ
