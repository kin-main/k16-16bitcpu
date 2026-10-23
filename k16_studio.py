#!/usr/bin/env python3
"""k16 CPU アセンブラ GUI (Tkinter)

外部ライブラリ不要で、リアルタイムアセンブル、逆アセンブルプレビュー、
エラー検出、Hexファイル出力、テンプレート読み込みが可能なデスクトップGUIです。
"""

from __future__ import annotations

import os
import re
import sys
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from pathlib import Path

# アセンブラ・逆アセンブラモジュールの読み込み
try:
    import k16asm
    import k16disasm
except ImportError:
    # パス解決
    sys.path.insert(0, str(Path(__file__).parent))
    import k16asm
    import k16disasm


SAMPLE_CODE = """; k16 CPU サンプルプログラム: UART送信とループ
.org 0x0000

start:
    LI      r1, 0xFF        ; ベースアドレス 0xFF00 の生成準備
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1      ; r1 = 0xFF00 (MMIO UART_TX)

    LI      r2, 0x4B        ; 'K' のASCIIコード
    ST      r2, [r1 + 0]    ; UART TXレジスタへ書き込み

    LI      r3, 0x31        ; '1'
    ST      r3, [r1 + 0]

    LI      r4, 0x36        ; '6'
    ST      r4, [r1 + 0]

main_loop:
    ADDI    r5, r5, 1       ; カウンタインクリメント
    JMP     main_loop       ; 無限ループ
"""

HELP_TEXT = """【k16 CPU 簡易命令リファレンス】

■ 基本構文 (ラベル・コメント)
  label:                      : アドレスの目印（例: start:, main_loop:）
  ; または #                  : 行末までのコメント（アセンブラは無視）

■ レジスタ
  r0 (ゼロレジスタ/書込不可), r1 ～ r13 (汎用), r14 (flags/書込不可), r15 (pc)
  ※ 特殊名: zero (r0), flags (r14), pc (r15)


■ 条件サフィックス (全命令に付加可能)
  .al (常時実行・省略時), .ne (非ゼロ), .nc (キャリー無), .pl (正),
  .nv (Never), .eq (ゼロ・一致), .cs (キャリー有), .mi (負)
  例: ADD.eq r1, r2, r3,  JMP.ne loop

■ フラグ更新タイミング & 規則 (Z, C, N)
  ・更新タイミング: ALU演算実行ステージ(EX)のクロック立ち上がりで更新
  ・更新対象命令  : ALU全命令(ADD/SUB/ADC/AND/OR/XOR/NAND/SHRおよび各即値形式I)、LI、MOV
  ・更新されない  : 分岐/PC書込(JMP/BRA/CALL)、ロード/ストア(LD/ST)、NOP、条件不成立時
  ・Z (Zero)      : 演算結果が 0x0000 のとき 1
  ・N (Negative)  : 演算結果の最上位bit (bit15) が 1 のとき 1
  ・C (Carry)     : 加算の溢れ、減算の非借用(A>=B)、SHRで溢れたbit0。論理演算時は直前の値を保持

■ 基本命令
  NOP                         : 何もしない (0x800000)
  LI      rd, imm8            : 8ビット即値をロード (rd = imm8)
  MOV     rd, rs              : レジスタ間コピー (rd = rs)
  JMP     target / BRA target : ジャンプ (pc = target)
  CALL    target              : 関数呼び出し (r12に復帰先退避)
  RET                         : 関数復帰 (pc = r12)

■ 比較・テスト疑似命令 (r0書き込み破棄・オペランド省略形)
  CMP     rs1, rs2            : レジスタ比較 (SUB r0, rs1, rs2: フラグのみ更新)
  CMPI    rs, imm8            : 即値比較 (SUBI r0, rs, imm8: フラグのみ更新)
  TEST    rs1, rs2            : ビットテスト (AND r0, rs1, rs2: フラグのみ更新)
  TESTI   rs, imm8            : 即値ビットテスト (ANDI r0, rs, imm8: フラグのみ更新)
  ※ 明示的に SUB r0, r1, r2 や AND r14, r1, r2 と書くことも可能です。

■ ALU演算 (3オペランド / 2オペランド対応)
  ADD     rd, rs1, rs2        : rd = rs1 + rs2 (2オペランド: ADD rd, rs2 -> rd = rd + rs2)
  SUB     rd, rs1, rs2        : rd = rs1 - rs2 (2オペランド: SUB rd, rs2)
  ADC     rd, rs1, rs2        : rd = rs1 + rs2 + carry
  AND     rd, rs1, rs2        : rd = rs1 & rs2 (2オペランド: AND rd, rs2)
  OR      rd, rs1, rs2        : rd = rs1 | rs2
  XOR     rd, rs1, rs2        : rd = rs1 ^ rs2
  NAND    rd, rs1, rs2        : rd = ~(rs1 & rs2)
  SHR     rd, rs              : rd = rs >> 1 (1オペランド: SHR rd -> rd = rd >> 1)

■ ALU即値演算 (3オペランド / 2オペランド対応)
  ADDI / SUBI / ADCI / ANDI / ORI / XORI / NANDI
  例: ADDI rd, rs, imm8 (2オペランド: ADDI rd, imm8 -> rd = rd + imm8)


■ メモリアクセス (LS形式)
  LD      rd, [base + offset] : メモリからロード (オフセット: 0〜511)
  LD      rd, [base - offset]
  ST      rs, [base + offset] : メモリへストア
  ST      rs, [base - offset]

■ ディレクティブ
  .org    address             : 開始アドレス設定
  .word   value               : 24ビットワード値配置
  .fill   count, value        : 指定個数のワード配置
  .string "text"              : ヌル終端文字列配置
  .ascii  "text"              : 文字列配置
"""


class K16AssemblerApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("k16 Assembler Studio")
        self.geometry("1100x750")
        self.minsize(800, 500)


        # フォント設定
        self.font_code = ("Consolas", 11)
        self.font_ui = ("Meiryo UI", 9)

        # 状態保持
        self.current_file: Path | None = None
        self.words: dict[int, int] = {}
        self.listing: list[tuple[int, int, str]] = []
        self.debounce_timer = None

        self._create_menu()
        self._create_widgets()
        self._setup_layout()
        self._setup_bindings()

        # 初期サンプル読み込み & アセンブル実行
        self.text_editor.insert("1.0", SAMPLE_CODE)
        self.do_assemble()

    def _create_menu(self):
        menubar = tk.Menu(self)

        # ファイルメニュー
        file_menu = tk.Menu(menubar, tearoff=0)
        file_menu.add_command(label="新規 (New)", command=self.on_new_file, accelerator="Ctrl+N")
        file_menu.add_command(label="開く (Open)...", command=self.on_open_file, accelerator="Ctrl+O")
        file_menu.add_command(label="上書き保存 (Save)", command=self.on_save_file, accelerator="Ctrl+S")
        file_menu.add_command(label="名前を付けて保存 (Save As)...", command=self.on_save_as_file)
        file_menu.add_separator()
        file_menu.add_command(label="Hex エクスポート (.hex)...", command=self.on_export_hex, accelerator="Ctrl+E")
        file_menu.add_command(label="リスティング エクスポート (.lst)...", command=self.on_export_listing)
        file_menu.add_separator()
        file_menu.add_command(label="終了", command=self.destroy)
        menubar.add_cascade(label="ファイル (F)", menu=file_menu)

        # 編集メニュー
        edit_menu = tk.Menu(menubar, tearoff=0)
        edit_menu.add_command(label="サンプルコード読込", command=self.load_sample)
        edit_menu.add_command(label="全選択", command=lambda: self.text_editor.tag_add("sel", "1.0", "end"), accelerator="Ctrl+A")
        menubar.add_cascade(label="編集 (E)", menu=edit_menu)

        # ビルドメニュー
        build_menu = tk.Menu(menubar, tearoff=0)
        build_menu.add_command(label="アセンブル再実行 (Assemble)", command=self.do_assemble, accelerator="F5")
        menubar.add_cascade(label="ビルド (B)", menu=build_menu)

        # ヘルプメニュー
        help_menu = tk.Menu(menubar, tearoff=0)
        help_menu.add_command(label="命令リファレンス", command=self.show_reference)
        help_menu.add_command(label="バージョン情報", command=self.show_about)
        menubar.add_cascade(label="ヘルプ (H)", menu=help_menu)

        self.config(menu=menubar)

    def _create_widgets(self):
        # ツールバー
        self.toolbar = ttk.Frame(self, padding=(6, 4))
        self.btn_open = ttk.Button(self.toolbar, text="📂 開く", command=self.on_open_file)
        self.btn_save = ttk.Button(self.toolbar, text="💾 保存", command=self.on_save_file)
        self.btn_export = ttk.Button(self.toolbar, text="⚡ Hex出力", command=self.on_export_hex)
        self.btn_assemble = ttk.Button(self.toolbar, text="▶ 再アセンブル (F5)", command=self.do_assemble)
        self.btn_ref = ttk.Button(self.toolbar, text="📖 リファレンス", command=self.show_reference)

        # 自動アセンブルチェックボックス
        self.var_auto_assemble = tk.BooleanVar(value=True)
        self.chk_auto = ttk.Checkbutton(self.toolbar, text="リアルタイムアセンブル", variable=self.var_auto_assemble)

        # 深度パディング入力 (オプション)
        self.lbl_depth = ttk.Label(self.toolbar, text="出力深度(word):")
        self.entry_depth = ttk.Entry(self.toolbar, width=6)
        self.entry_depth.insert(0, "")

        # メインスプリッター (左右分割)
        self.paned_main = ttk.PanedWindow(self, orient=tk.HORIZONTAL)

        # 左側: エディタ部
        self.frame_left = ttk.Frame(self.paned_main)
        self.lbl_src_title = ttk.Label(self.frame_left, text="アセンブリソース (.k16 / .asm)", font=("Meiryo UI", 9, "bold"))
        
        # エディタ用コンテナ (行番号 + テキストエリア)
        self.frame_text_container = ttk.Frame(self.frame_left)
        self.line_numbers = tk.Text(
            self.frame_text_container,
            width=5,
            padx=4,
            takefocus=0,
            border=0,
            background="#252526",
            foreground="#858585",
            font=self.font_code,
            state="disabled",
        )
        self.text_editor = tk.Text(
            self.frame_text_container,
            wrap="none",
            undo=True,
            font=self.font_code,
            background="#1E1E1E",
            foreground="#D4D4D4",
            insertbackground="#FFFFFF",
            selectbackground="#264F78",
            padx=6,
            pady=4,
        )
        self.scroll_y = ttk.Scrollbar(self.frame_text_container, orient=tk.VERTICAL, command=self._on_scroll_y)
        self.scroll_x = ttk.Scrollbar(self.frame_left, orient=tk.HORIZONTAL, command=self.text_editor.xview)
        self.text_editor.configure(
            yscrollcommand=self._on_text_scroll,
            xscrollcommand=self.scroll_x.set,
        )

        # 右側: プレビュー & リスティング & 出力部 (上下分割)
        self.paned_right = ttk.PanedWindow(self.paned_main, orient=tk.VERTICAL)

        # 右上: 生成ワード・逆アセンブルテーブル
        self.frame_right_top = ttk.Frame(self.paned_right)
        self.lbl_listing_title = ttk.Label(self.frame_right_top, text="マシン語・逆アセンブル出力 (24-bit HEX)", font=("Meiryo UI", 9, "bold"))
        
        # Treeview (Address, Hex Word, Disassembly, Source)
        columns = ("addr", "hex", "disasm", "src")
        self.tree_listing = ttk.Treeview(self.frame_right_top, columns=columns, show="headings", selectmode="browse")
        self.tree_listing.heading("addr", text="アドレス")
        self.tree_listing.heading("hex", text="HEX (24-bit)")
        self.tree_listing.heading("disasm", text="逆アセンブル")
        self.tree_listing.heading("src", text="元ソース")

        self.tree_listing.column("addr", width=70, anchor="center")
        self.tree_listing.column("hex", width=100, anchor="center")
        self.tree_listing.column("disasm", width=180, anchor="w")
        self.tree_listing.column("src", width=220, anchor="w")

        self.scroll_tree_y = ttk.Scrollbar(self.frame_right_top, orient=tk.VERTICAL, command=self.tree_listing.yview)
        self.tree_listing.configure(yscrollcommand=self.scroll_tree_y.set)

        # 右下: コンソール / エラーメッセージ
        self.frame_right_bottom = ttk.Frame(self.paned_right)
        self.lbl_status_title = ttk.Label(self.frame_right_bottom, text="ステータス / アセンブル結果", font=("Meiryo UI", 9, "bold"))
        self.text_status = tk.Text(
            self.frame_right_bottom,
            height=6,
            wrap="word",
            font=("Consolas", 10),
            background="#252526",
            foreground="#D4D4D4",
            state="disabled",
            padx=6,
            pady=4,
        )
        self.scroll_status = ttk.Scrollbar(self.frame_right_bottom, orient=tk.VERTICAL, command=self.text_status.yview)
        self.text_status.configure(yscrollcommand=self.scroll_status.set)

        # ステータスバー (最下部)
        self.statusbar = ttk.Frame(self, relief=tk.SUNKEN, padding=(6, 2))
        self.lbl_status_msg = ttk.Label(self.statusbar, text="準備完了", anchor="w")
        self.lbl_word_count = ttk.Label(self.statusbar, text="命令数: 0", anchor="e")

    def _setup_layout(self):
        # ツールバー配置
        self.toolbar.pack(side=tk.TOP, fill=tk.X)
        self.btn_open.pack(side=tk.LEFT, padx=2)
        self.btn_save.pack(side=tk.LEFT, padx=2)
        self.btn_export.pack(side=tk.LEFT, padx=2)
        self.btn_assemble.pack(side=tk.LEFT, padx=6)
        self.chk_auto.pack(side=tk.LEFT, padx=6)
        self.lbl_depth.pack(side=tk.LEFT, padx=(12, 2))
        self.entry_depth.pack(side=tk.LEFT, padx=2)
        self.btn_ref.pack(side=tk.RIGHT, padx=4)

        # メインスプリッター配置
        self.paned_main.pack(fill=tk.BOTH, expand=True, padx=4, pady=2)

        # 左側 (エディタ)
        self.lbl_src_title.pack(anchor="w", pady=(2, 4))
        self.frame_text_container.pack(fill=tk.BOTH, expand=True)
        self.line_numbers.pack(side=tk.LEFT, fill=tk.Y)
        self.text_editor.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.scroll_y.pack(side=tk.RIGHT, fill=tk.Y)
        self.scroll_x.pack(side=tk.BOTTOM, fill=tk.X)
        self.paned_main.add(self.frame_left, weight=3)

        # 右側 (プレビュー + ステータス)
        # 上部: リスティング
        self.lbl_listing_title.pack(anchor="w", pady=(2, 4))
        self.tree_listing.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.scroll_tree_y.pack(side=tk.RIGHT, fill=tk.Y)
        self.paned_right.add(self.frame_right_top, weight=4)

        # 下部: ステータス
        self.lbl_status_title.pack(anchor="w", pady=(2, 4))
        self.text_status.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.scroll_status.pack(side=tk.RIGHT, fill=tk.Y)
        self.paned_right.add(self.frame_right_bottom, weight=1)

        self.paned_main.add(self.paned_right, weight=4)

        # 最下部ステータスバー
        self.statusbar.pack(side=tk.BOTTOM, fill=tk.X)
        self.lbl_status_msg.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.lbl_word_count.pack(side=tk.RIGHT)

        # タグ設定 (シンタックスハイライト・エラー表示用)
        self.text_editor.tag_configure("comment", foreground="#6A9955")
        self.text_editor.tag_configure("label", foreground="#DCDCAA")
        self.text_editor.tag_configure("directive", foreground="#C586C0")
        self.text_editor.tag_configure("opcode", foreground="#569CD6")
        self.text_editor.tag_configure("error_line", background="#5A1D1D")

    def _setup_bindings(self):
        self.text_editor.bind("<KeyRelease>", self._on_editor_change)
        self.text_editor.bind("<<Modified>>", self._on_editor_modified)
        self.tree_listing.bind("<<TreeviewSelect>>", self._on_listing_select)

        # ショートカットキー
        self.bind("<Control-n>", lambda e: self.on_new_file())
        self.bind("<Control-o>", lambda e: self.on_open_file())
        self.bind("<Control-s>", lambda e: self.on_save_file())
        self.bind("<Control-e>", lambda e: self.on_export_hex())
        self.bind("<F5>", lambda e: self.do_assemble())

    def _on_scroll_y(self, *args):
        self.text_editor.yview(*args)
        self.line_numbers.yview(*args)

    def _on_text_scroll(self, *args):
        self.scroll_y.set(*args)
        self.line_numbers.yview_moveto(args[0])

    def _update_line_numbers(self):
        lines = int(self.text_editor.index("end-1c").split(".")[0])
        nums = "\n".join(str(i) for i in range(1, lines + 1))
        self.line_numbers.configure(state="normal")
        self.line_numbers.delete("1.0", "end")
        self.line_numbers.insert("1.0", nums)
        self.line_numbers.configure(state="disabled")

    def _on_editor_change(self, event=None):
        self._update_line_numbers()
        self._highlight_syntax()
        if self.var_auto_assemble.get():
            # デバウンス処理 (入力後 250ms 経過でアセンブル実行)
            if self.debounce_timer:
                self.after_cancel(self.debounce_timer)
            self.debounce_timer = self.after(250, self.do_assemble)

    def _on_editor_modified(self, event=None):
        if self.text_editor.edit_modified():
            self._update_line_numbers()
            self.text_editor.edit_modified(False)

    def _highlight_syntax(self):
        # 既存タグの消去
        for tag in ("comment", "label", "directive", "opcode"):
            self.text_editor.tag_remove(tag, "1.0", "end")

        content = self.text_editor.get("1.0", "end-1c")
        lines = content.splitlines()

        opcodes = set(k16asm.ALU_R | k16asm.ALU_I | {"NOP", "LI", "MOV", "JMP", "BRA", "CALL", "RET", "LD", "ST", "CMP", "CMPI", "TEST", "TESTI"})


        for line_idx, line in enumerate(lines, 1):
            # コメントのハイライト (; または #)
            c_pos = None
            for delim in (";", "#"):
                p = line.find(delim)
                if p != -1 and (c_pos is None or p < c_pos):
                    c_pos = p
            if c_pos is not None:
                self.text_editor.tag_add("comment", f"{line_idx}.{c_pos}", f"{line_idx}.end")
                code_part = line[:c_pos]
            else:
                code_part = line

            # ラベル (例: "start:")
            if ":" in code_part:
                colon_idx = code_part.find(":")
                lbl_start = len(code_part[:colon_idx]) - len(code_part[:colon_idx].lstrip())
                self.text_editor.tag_add("label", f"{line_idx}.{lbl_start}", f"{line_idx}.{colon_idx+1}")
                code_part = code_part[colon_idx+1:]

            # ディレクティブ (.org, .word, .fill など)
            dir_matches = re.finditer(r"\.[A-Za-z0-9_]+", code_part)
            for m in dir_matches:
                self.text_editor.tag_add("directive", f"{line_idx}.{m.start()}", f"{line_idx}.{m.end()}")

            # 命令オピコード (大文字・小文字、条件サフィックス対応)
            words = re.finditer(r"\b[A-Za-z_][A-Za-z0-9_\.]*\b", code_part)
            for m in words:
                token = m.group(0).upper()
                base_token = token.split(".")[0]
                if base_token in opcodes:
                    self.text_editor.tag_add("opcode", f"{line_idx}.{m.start()}", f"{line_idx}.{m.end()}")

    def _on_listing_select(self, event=None):
        selected = self.tree_listing.selection()
        if not selected:
            return
        item_vals = self.tree_listing.item(selected[0], "values")
        if item_vals and len(item_vals) >= 4:
            src_text = item_vals[3]
            # ソースコード内を簡易検索してフォーカス
            content = self.text_editor.get("1.0", "end-1c")
            pos = content.find(src_text)
            if pos != -1:
                idx = self.text_editor.index(f"1.0 + {pos} chars")
                self.text_editor.see(idx)
                self.text_editor.tag_remove("sel", "1.0", "end")
                self.text_editor.tag_add("sel", idx, f"{idx} lineend")

    def do_assemble(self):
        # 既存のエラーハイライト消去
        self.text_editor.tag_remove("error_line", "1.0", "end")

        content = self.text_editor.get("1.0", "end-1c")
        
        # 一時ファイルに保存して既存の k16asm.assemble() を活用
        temp_dir = Path.home() / ".k16_tmp"
        temp_dir.mkdir(parents=True, exist_ok=True)
        temp_file = temp_dir / "_editor_temp.k16"
        temp_file.write_text(content, encoding="utf-8")

        try:
            words, listing = k16asm.assemble(temp_file)
            self.words = words
            self.listing = listing

            # ツリービュー更新
            self.tree_listing.delete(*self.tree_listing.get_children())
            for address, word, source in listing:
                disasm = k16disasm.disassemble_word(word)
                self.tree_listing.insert(
                    "",
                    "end",
                    values=(f"0x{address:04X}", f"{word:06X}", disasm, source),
                )

            # ステータス更新
            msg = f"✔ アセンブル成功: {len(words)} ワード生成 (アドレス範囲: 0x{min(words, default=0):04X} ～ 0x{max(words, default=0):04X})"
            self._set_status_log(msg, is_error=False)
            self.lbl_status_msg.config(text="アセンブル正常終了", foreground="#4EC9B0")
            self.lbl_word_count.config(text=f"生成ワード数: {len(words)}")

        except Exception as exc:
            err_msg = str(exc)
            self._set_status_log(f"✖ エラー: {err_msg}", is_error=True)
            self.lbl_status_msg.config(text="アセンブルエラー", foreground="#F48771")

            # エラー行の特定とハイライト (例: "12: unknown mnemonic ...")
            match = re.match(r"^(\d+):", err_msg)
            if match:
                line_no = int(match.group(1))
                self.text_editor.tag_add("error_line", f"{line_no}.0", f"{line_no}.end")
                self.text_editor.see(f"{line_no}.0")

    def _set_status_log(self, text: str, is_error: bool = False):
        self.text_status.configure(state="normal")
        self.text_status.delete("1.0", "end")
        self.text_status.insert("1.0", text)
        if is_error:
            self.text_status.configure(foreground="#F48771")
        else:
            self.text_status.configure(foreground="#D4D4D4")
        self.text_status.configure(state="disabled")

    # ---- ファイル操作 ----
    def on_new_file(self):
        if messagebox.askyesno("新規作成", "現在の編集内容を破棄して新規作成しますか？"):
            self.text_editor.delete("1.0", "end")
            self.current_file = None
            self.title("k16 Assembler Studio - 無題")
            self.do_assemble()

    def on_open_file(self):
        path = filedialog.askopenfilename(
            title="k16 アセンブリファイルを開く",
            filetypes=[("k16 アセンブリ", "*.k16 *.asm *.s"), ("すべてのファイル", "*.*")],
        )
        if path:
            p = Path(path)
            try:
                content = p.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                content = p.read_text(encoding="shift_jis")
            self.text_editor.delete("1.0", "end")
            self.text_editor.insert("1.0", content)
            self.current_file = p
            self.title(f"k16 Assembler Studio - {p.name}")
            self.do_assemble()

    def on_save_file(self):
        if self.current_file is None:
            self.on_save_as_file()
        else:
            content = self.text_editor.get("1.0", "end-1c")
            self.current_file.write_text(content, encoding="utf-8")
            self.lbl_status_msg.config(text=f"保存完了: {self.current_file.name}", foreground="#4EC9B0")

    def on_save_as_file(self):
        path = filedialog.asksaveasfilename(
            title="名前を付けて保存",
            defaultextension=".k16",
            filetypes=[("k16 アセンブリ", "*.k16"), ("アセンブリ", "*.asm"), ("すべてのファイル", "*.*")],
        )
        if path:
            self.current_file = Path(path)
            self.on_save_file()
            self.title(f"k16 Assembler Studio - {self.current_file.name}")

    def on_export_hex(self):
        self.do_assemble()
        if not self.words:
            messagebox.showerror("エラー", "アセンブル結果が空か、エラーが発生しています。")
            return

        depth_val = None
        depth_str = self.entry_depth.get().strip()
        if depth_str:
            try:
                depth_val = int(depth_str, 0)
            except ValueError:
                messagebox.showerror("エラー", f"深度の数値が不正です: {depth_str}")
                return

        path = filedialog.asksaveasfilename(
            title="Hexファイルを保存",
            initialfile="firmware.hex",
            defaultextension=".hex",
            filetypes=[("HEXファイル", "*.hex"), ("すべてのファイル", "*.*")],
        )
        if path:
            output = Path(path)
            try:
                k16asm.write_hex(self.words, output, depth_val)
                messagebox.showinfo("成功", f"HEXファイルを保存しました:\n{output.resolve()}\n(深度: {depth_val or max(self.words)+1} ワード)")
            except Exception as exc:
                messagebox.showerror("エラー", f"HEX保存に失敗しました:\n{exc}")

    def on_export_listing(self):
        self.do_assemble()
        if not self.listing:
            messagebox.showerror("エラー", "リスティングが生成されていません。")
            return
        path = filedialog.asksaveasfilename(
            title="リスティングファイルを保存",
            initialfile="listing.lst",
            defaultextension=".lst",
            filetypes=[("リスティングファイル", "*.lst"), ("すべてのファイル", "*.*")],
        )
        if path:
            output = Path(path)
            with output.open("w", encoding="utf-8", newline="\n") as s:
                for address, word, source in self.listing:
                    s.write(f"{address:04X}  {word:06X}  {k16disasm.disassemble_word(word):<24} ; {source}\n")
            messagebox.showinfo("成功", f"リスティングを保存しました:\n{output.resolve()}")

    def load_sample(self):
        if messagebox.askyesno("サンプル読込", "エディタ内容をサンプルコードで上書きしますか？"):
            self.text_editor.delete("1.0", "end")
            self.text_editor.insert("1.0", SAMPLE_CODE)
            self.do_assemble()

    def show_reference(self):
        win = tk.Toplevel(self)
        win.title("k16 命令セットリファレンス")
        win.geometry("640x550")

        txt = tk.Text(win, font=self.font_code, wrap="none", padx=8, pady=8, background="#1E1E1E", foreground="#D4D4D4")
        txt.insert("1.0", HELP_TEXT)
        txt.configure(state="disabled")
        sc = ttk.Scrollbar(win, orient=tk.VERTICAL, command=txt.yview)
        txt.configure(yscrollcommand=sc.set)
        sc.pack(side=tk.RIGHT, fill=tk.Y)
        txt.pack(fill=tk.BOTH, expand=True)

    def show_about(self):
        messagebox.showinfo(
            "k16 Assembler Studio",
            "k16 16-bit CPU アセンブラ GUI\n\nリアルタイム構文チェック・逆アセンブルプレビュー・Hex出力を備えた開発環境です。\nPython 標準 Tkinter 実装。"
        )


def main():
    app = K16AssemblerApp()
    app.mainloop()


if __name__ == "__main__":
    main()
