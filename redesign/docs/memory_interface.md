# k16 Memory Interface 契約書

## 1. 概要

k16 CPUとMemory Subsystem間の単一ポート・同期Readインターフェースの契約定義。
von Neumann型（命令・データ共用）。

## 2. 信号定義

### CPU → Memory Subsystem

| 信号 | 幅 | 方向 | 説明 |
|---|---|---|---|
| `mem_data_req` | 1 | CPU→MEM | `1` = データアクセス(LOAD/STORE)、`0` = 命令フェッチ |
| `mem_addr` | 16 | CPU→MEM | メモリアドレス |
| `mem_wdata` | 24 | CPU→MEM | 書き込みデータ（STORE時） |
| `mem_we` | 1 | CPU→MEM | `1` = 書き込み（STORE）、`0` = 読み出し |

### Memory Subsystem → CPU

| 信号 | 幅 | 方向 | 説明 |
|---|---|---|---|
| `mem_rdata` | 24 | MEM→CPU | 読み出しデータ |
| `mem_ready` | 1 | MEM→CPU | `1` = `mem_rdata` 有効 |

## 3. タイミング契約

### 3.1 基本契約

```
Cycle N  : CPU が mem_addr, mem_data_req, mem_we, mem_wdata を駆動
Cycle N+1: MEM が mem_rdata, mem_ready を駆動
```

**CPUはCycle Nでリクエストを発行し、Cycle N+1でレスポンスを受け取る。**

### 3.2 RAM（同期Read）の挙動

```
always @(posedge clk) begin
    if (we) memory[addr] <= wdata;
    rdata <= memory[addr];   // 常に1サイクル遅延で出力
end
```

- `mem_ready` = **常に1**（1サイクルで必ず応答）
- `mem_rdata` は **Cycle N+1** で `memory[mem_addr_N]` が確定
- 書き込みはCycle Nのposedgeで確定。Cycle N+1以降の読み出しに反映

### 3.3 MMIOの挙動

- `mem_ready` = 可変レイテンシ（0〜Nサイクル）
- MMIOモジュールは `mem_data_req=1` かつ `mem_addr` がMMIO範囲のときリクエストを受理
- `mem_ready=1` になるまでCPUはstall（PC保持・IR保持）
- `mem_ready=1` のサイクルで `mem_rdata` が有効

### 3.4 フェッチ vs データアクセス

| `mem_data_req` | `mem_addr` 範囲 | 挙動 |
|---|---|---|
| 0 (フェッチ) | 0x0000-0xFEFF | RAMから命令を読む |
| 0 (フェッチ) | 0xFF00-0xFFFF | **NOP (0x800000) を返す**（MMIO領域は実行不可） |
| 1 (データ) | 0x0000-0xFEFF | RAM データアクセス |
| 1 (データ) | 0xFF00-0xFFFF | MMIO データアクセス |

## 4. CPU側の状態機械との対応

### 4.1 状態遷移とmem_addr駆動

| 状態 | 条件 | mem_addr | mem_data_req | 備考 |
|---|---|---|---|---|
| S_IDLE | 通常ALU | `fetch_pc` | 0 | フェッチ継続 |
| S_IDLE | LOAD/STORE成立 | `data_addr` | 1 | データ要求発行 |
| S_IDLE | 分岐成立(ALU r15) | `alu_result` | 0 | 分岐先フェッチ開始 |
| S_MEM_RESP | mem_ready=1 (通常) | `fetch_pc` | 0 | フェッチ再開 |
| S_MEM_RESP | mem_ready=1 (LOAD r15) | `mem_rdata[15:0]` | 0 | 分岐先フェッチ開始 |
| S_MEM_RESP | mem_ready=0 (MMIO待ち) | `data_addr`(保持) | 1 | MMIO待機 |
| S_FLUSH1 | — | `fetch_pc` | 0 | 分岐先の次をフェッチ |

### 4.2 CPU側のレスポンス処理

- **S_IDLE通常**: `mem_rdata` → IR（次命令ロード）
- **S_IDLE LOAD/STORE**: `mem_rdata` → `prefetch_buf`（次命令を退避）
- **S_MEM_RESP LOAD**: `mem_rdata[15:0]` → `regs[rd]`, `mem_rdata[23:16]` → `r13[7:0]`
- **S_FLUSH1**: `mem_rdata` → IR（分岐先命令ロード）

## 5. 同期RAM固有の注意事項

### 5.1 フェッチパイプライン遅延

同期RAMでは **PC提示→IR更新が2サイクル** かかる:

```
Cycle N  : mem_addr = PC    (フェッチ要求)
Cycle N+1: mem_rdata = memory[PC]  (レスポンス到着)
Cycle N+2: IR = mem_rdata   (IR更新・実行開始)
```

このため、CPU内部で `fetch_pc`（次フェッチアドレス）と `ir_addr`（現在実行中の命令アドレス = r15読出し値）を **分離管理** する。

### 5.2 分岐フラッシュ

同期RAMでは分岐後 **1サイクルのフラッシュ** が必要:

```
Cycle N  : 分岐命令実行。mem_addr = TARGET に切替
Cycle N+1: S_FLUSH1。mem_rdata = memory[TARGET] 到着。IR=NOP
Cycle N+2: IR = memory[TARGET] 実行開始
```

### 5.3 LOAD/STORE バブル

LOAD/STORE実行サイクルはバスがデータアクセスに占有されるため、フェッチ不可。1サイクルのバブル（S_MEM_RESP）を挿入し、次命令を `prefetch_buf` に退避しておく。

## 6. 今後の拡張ポイント

- **SDRAM**: `mem_ready` を使って可変レイテンシに対応可能
- **DMA**: `mem_data_req` にバスアービタを追加
- **キャッシュ**: `mem_ready` の前にキャッシュヒット判定を挿入
