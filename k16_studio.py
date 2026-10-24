#!/usr/bin/env python3
"""k16 アセンブラ Studio.

標準ライブラリの Tkinter だけで動作する、k16 アセンブリ用の小さなIDEです。
"""

from __future__ import annotations

import re
import sys
import tempfile
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk


ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import k16asm  # noqa: E402
import k16disasm  # noqa: E402


SAMPLE_CODE = """; k16 CPU sample
.org 0x0000

start:
    LI      r1, 0xFF
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1
    ADD     r1, r1, r1      ; r1 = 0xFF00

    LI      r2, 0x4B
    ST      r2, [r1 + 0]

main_loop:
    ADDI    r5, r5, 1
    JMP     main_loop
"""


HELP_TEXT = """k16 アセンブラ リファレンス

コメント:
  ; または # から行末まで

レジスタ:
  r0〜r13 / zero / flags / pc

条件サフィックス:
  .al .ne .nc .pl .nv .eq .cs .mi
  例: ADD.eq r1, r2, r3

基本命令:
  NOP
  LI rd, imm8
  MOV rd, rs
  JMP target / BRA target
  CALL target
  RET

演算:
  ADD SUB ADC AND OR XOR NAND rd, rs1, rs2
  SHR rd, rs
  ADDI SUBI ADCI ANDI ORI XORI NANDI rd, rs, imm8
  2オペランド形式にも対応しています。

比較:
  CMP rs1, rs2
  CMPI rs, imm8
  TEST rs1, rs2
  TESTI rs, imm8

メモリ:
  LD rd, [base + offset]
  LD rd, [base - offset]
  ST rs, [base + offset]
  ST rs, [base - offset]

ディレクティブ:
  .org address
  .word value
  .fill count, value
  .string "text"
  .ascii "text"
"""


class K16Studio(tk.Tk):
    """k16 アセンブリを編集・アセンブルするGUI。"""

    def __init__(self) -> None:
        super().__init__()
        self.current_file: Path | None = None
        self.words: dict[int, int] = {}
        self.listing: list[tuple[int, int, str]] = []
        self._assemble_after: str | None = None
        self._updating_editor = False

        self.title("k16 Assembler Studio")
        self.geometry("1200x760")
        self.minsize(820, 520)

        self._build_menu()
        self._build_widgets()
        self._bind_events()
        self._load_text(SAMPLE_CODE)
        self.after_idle(self.assemble)

    def _build_menu(self) -> None:
        menu = tk.Menu(self)

        file_menu = tk.Menu(menu, tearoff=False)
        file_menu.add_command(label="新規", command=self.new_file, accelerator="Ctrl+N")
        file_menu.add_command(label="開く...", command=self.open_file, accelerator="Ctrl+O")
        file_menu.add_command(label="保存", command=self.save_file, accelerator="Ctrl+S")
        file_menu.add_command(label="名前を付けて保存...", command=self.save_as)
        file_menu.add_separator()
        file_menu.add_command(label="HEX出力...", command=self.export_hex, accelerator="Ctrl+E")
        file_menu.add_command(label="LST出力...", command=self.export_listing)
        file_menu.add_separator()
        file_menu.add_command(label="終了", command=self.destroy)
        menu.add_cascade(label="ファイル", menu=file_menu)

        edit_menu = tk.Menu(menu, tearoff=False)
        edit_menu.add_command(label="サンプルを読み込む", command=self.load_sample)
        edit_menu.add_command(
            label="全選択", command=lambda: self.editor.tag_add("sel", "1.0", "end"), accelerator="Ctrl+A"
        )
        menu.add_cascade(label="編集", menu=edit_menu)

        build_menu = tk.Menu(menu, tearoff=False)
        build_menu.add_command(label="アセンブル", command=self.assemble, accelerator="F5")
        menu.add_cascade(label="ビルド", menu=build_menu)

        help_menu = tk.Menu(menu, tearoff=False)
        help_menu.add_command(label="命令リファレンス", command=self.show_reference)
        help_menu.add_command(label="バージョン情報", command=self.show_about)
        menu.add_cascade(label="ヘルプ", menu=help_menu)
        self.config(menu=menu)

    def _build_widgets(self) -> None:
        toolbar = ttk.Frame(self, padding=6)
        toolbar.pack(fill=tk.X)
        ttk.Button(toolbar, text="開く", command=self.open_file).pack(side=tk.LEFT, padx=2)
        ttk.Button(toolbar, text="保存", command=self.save_file).pack(side=tk.LEFT, padx=2)
        ttk.Button(toolbar, text="HEX出力", command=self.export_hex).pack(side=tk.LEFT, padx=2)
        ttk.Button(toolbar, text="再アセンブル (F5)", command=self.assemble).pack(side=tk.LEFT, padx=8)
        self.auto_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(toolbar, text="リアルタイム", variable=self.auto_var).pack(side=tk.LEFT, padx=4)
        ttk.Label(toolbar, text="深度:").pack(side=tk.LEFT, padx=(14, 2))
        self.depth_entry = ttk.Entry(toolbar, width=8)
        self.depth_entry.pack(side=tk.LEFT)
        ttk.Button(toolbar, text="リファレンス", command=self.show_reference).pack(side=tk.RIGHT)

        main = ttk.PanedWindow(self, orient=tk.HORIZONTAL)
        main.pack(fill=tk.BOTH, expand=True, padx=5, pady=(0, 4))

        left = ttk.Frame(main)
        ttk.Label(left, text="ソース (.k16 / .asm)").pack(anchor="w", pady=(2, 4))
        editor_frame = ttk.Frame(left)
        editor_frame.pack(fill=tk.BOTH, expand=True)
        self.line_numbers = tk.Text(
            editor_frame, width=5, state="disabled", takefocus=False, borderwidth=0,
            background="#252526", foreground="#858585", font=("Consolas", 11),
        )
        self.line_numbers.pack(side=tk.LEFT, fill=tk.Y)
        self.editor = tk.Text(
            editor_frame, wrap="none", undo=True, font=("Consolas", 11),
            background="#1E1E1E", foreground="#D4D4D4",
            insertbackground="white", selectbackground="#264F78",
        )
        self.editor.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.editor_y_scroll = ttk.Scrollbar(editor_frame, command=self._scroll_editor)
        self.editor_y_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        x_scroll = ttk.Scrollbar(left, orient=tk.HORIZONTAL, command=self.editor.xview)
        x_scroll.pack(side=tk.BOTTOM, fill=tk.X)
        self.editor.configure(yscrollcommand=self._editor_scrolled, xscrollcommand=x_scroll.set)
        main.add(left, weight=3)

        right = ttk.PanedWindow(main, orient=tk.VERTICAL)
        listing_frame = ttk.Frame(right)
        ttk.Label(listing_frame, text="マシン語 / 逆アセンブル").pack(anchor="w", pady=(2, 4))
        columns = ("address", "word", "disassembly", "source")
        self.listing_view = ttk.Treeview(listing_frame, columns=columns, show="headings")
        headings = {"address": "アドレス", "word": "HEX (24-bit)", "disassembly": "逆アセンブル", "source": "ソース"}
        widths = {"address": 80, "word": 100, "disassembly": 190, "source": 320}
        for column in columns:
            self.listing_view.heading(column, text=headings[column])
            self.listing_view.column(column, width=widths[column], anchor="w")
        listing_scroll = ttk.Scrollbar(listing_frame, command=self.listing_view.yview)
        self.listing_view.configure(yscrollcommand=listing_scroll.set)
        self.listing_view.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        listing_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        right.add(listing_frame, weight=4)

        status_frame = ttk.Frame(right)
        ttk.Label(status_frame, text="ステータス").pack(anchor="w", pady=(2, 4))
        self.status_text = tk.Text(
            status_frame, height=5, state="disabled", wrap="word",
            background="#252526", foreground="#D4D4D4", font=("Consolas", 10),
        )
        self.status_text.pack(fill=tk.BOTH, expand=True)
        right.add(status_frame, weight=1)
        main.add(right, weight=4)

        self.status_label = ttk.Label(self, text="準備完了", anchor="w")
        self.status_label.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=6, pady=3)
        self.count_label = ttk.Label(self, text="ワード数: 0", anchor="e")
        self.count_label.pack(side=tk.RIGHT, padx=6, pady=3)

        for tag, color in {
            "comment": "#6A9955", "label": "#DCDCAA", "directive": "#C586C0",
            "opcode": "#569CD6",
        }.items():
            self.editor.tag_configure(tag, foreground=color)
        self.editor.tag_configure("error", background="#5A1D1D")

    def _bind_events(self) -> None:
        self.editor.bind("<KeyRelease>", self._editor_changed)
        self.editor.bind("<<Modified>>", self._modified_changed)
        self.listing_view.bind("<<TreeviewSelect>>", self._listing_selected)
        self.bind("<Control-n>", lambda event: self.new_file())
        self.bind("<Control-o>", lambda event: self.open_file())
        self.bind("<Control-s>", lambda event: self.save_file())
        self.bind("<Control-e>", lambda event: self.export_hex())
        self.bind("<F5>", lambda event: self.assemble())

    def _load_text(self, text: str) -> None:
        self._updating_editor = True
        try:
            self.editor.delete("1.0", tk.END)
            self.editor.insert("1.0", text)
            self.editor.edit_modified(False)
        finally:
            self._updating_editor = False
        self._update_line_numbers()
        self._highlight()

    def _modified_changed(self, _event: tk.Event | None = None) -> None:
        if self.editor.edit_modified():
            self.editor.edit_modified(False)
            self._update_line_numbers()

    def _editor_changed(self, _event: tk.Event | None = None) -> None:
        self._update_line_numbers()
        self._highlight()
        if self.auto_var.get():
            if self._assemble_after is not None:
                self.after_cancel(self._assemble_after)
            self._assemble_after = self.after(300, self.assemble)

    def _update_line_numbers(self) -> None:
        line_count = int(self.editor.index("end-1c").split(".")[0])
        value = "\n".join(str(number) for number in range(1, line_count + 1))
        self.line_numbers.configure(state="normal")
        self.line_numbers.delete("1.0", tk.END)
        self.line_numbers.insert("1.0", value)
        self.line_numbers.configure(state="disabled")

    def _scroll_editor(self, *args: str) -> None:
        self.editor.yview(*args)
        self.line_numbers.yview(*args)

    def _editor_scrolled(self, first: str, last: str) -> None:
        self.line_numbers.yview_moveto(first)
        self.editor_y_scroll.set(first, last)

    def _highlight(self) -> None:
        for tag in ("comment", "label", "directive", "opcode"):
            self.editor.tag_remove(tag, "1.0", tk.END)
        opcodes = set(k16asm.ALU_R | k16asm.ALU_I)
        opcodes.update({"NOP", "LI", "MOV", "JMP", "BRA", "CALL", "RET", "LD", "ST",
                        "CMP", "CMPI", "TEST", "TESTI"})
        for line_no, raw_line in enumerate(self.editor.get("1.0", "end-1c").splitlines(), 1):
            code = raw_line
            comment_start = min((p for p in (raw_line.find(";"), raw_line.find("#")) if p >= 0), default=-1)
            if comment_start >= 0:
                self.editor.tag_add("comment", f"{line_no}.{comment_start}", f"{line_no}.end")
                code = raw_line[:comment_start]
            label_match = re.match(r"^(\s*[A-Za-z_][A-Za-z0-9_]*:)", code)
            if label_match:
                self.editor.tag_add("label", f"{line_no}.0", f"{line_no}.{len(label_match.group(1))}")
                code = code[label_match.end():]
            for match in re.finditer(r"\.[A-Za-z0-9_]+", code):
                offset = len(raw_line) - len(code)
                self.editor.tag_add("directive", f"{line_no}.{offset + match.start()}",
                                    f"{line_no}.{offset + match.end()}")
            for match in re.finditer(r"\b[A-Za-z_][A-Za-z0-9_.]*\b", code):
                if match.group(0).upper().split(".")[0] in opcodes:
                    offset = len(raw_line) - len(code)
                    self.editor.tag_add("opcode", f"{line_no}.{offset + match.start()}",
                                        f"{line_no}.{offset + match.end()}")

    def assemble(self) -> None:
        self._assemble_after = None
        self.editor.tag_remove("error", "1.0", tk.END)
        text = self.editor.get("1.0", "end-1c")
        try:
            with tempfile.TemporaryDirectory(prefix="k16studio-") as directory:
                source = Path(directory) / "editor.k16"
                source.write_text(text, encoding="utf-8")
                words, listing = k16asm.assemble(source)
        except Exception as exc:
            self.words = {}
            self.listing = []
            self._clear_listing()
            self._set_status(f"アセンブルエラー\n{exc}", error=True)
            self._highlight_error(str(exc))
            return

        self.words, self.listing = words, listing
        self._clear_listing()
        for address, word, source_text in listing:
            self.listing_view.insert(
                "", tk.END,
                values=(f"0x{address:04X}", f"{word:06X}",
                        k16disasm.disassemble_word(word), source_text),
            )
        if words:
            address_range = f"0x{min(words):04X} - 0x{max(words):04X}"
        else:
            address_range = "空"
        self._set_status(f"アセンブル成功: {len(words)} ワード ({address_range})")
        self.status_label.configure(text="アセンブル正常終了", foreground="#4EC9B0")
        self.count_label.configure(text=f"ワード数: {len(words)}")

    def _clear_listing(self) -> None:
        self.listing_view.delete(*self.listing_view.get_children())
        self.count_label.configure(text="ワード数: 0")

    def _set_status(self, text: str, error: bool = False) -> None:
        self.status_text.configure(state="normal", foreground="#F48771" if error else "#D4D4D4")
        self.status_text.delete("1.0", tk.END)
        self.status_text.insert("1.0", text)
        self.status_text.configure(state="disabled")
        if error:
            self.status_label.configure(text="アセンブルエラー", foreground="#F48771")

    def _highlight_error(self, message: str) -> None:
        match = re.match(r"\s*(\d+):", message)
        if match:
            line = int(match.group(1))
            self.editor.tag_add("error", f"{line}.0", f"{line}.end")
            self.editor.see(f"{line}.0")

    def _listing_selected(self, _event: tk.Event | None = None) -> None:
        selected = self.listing_view.selection()
        if not selected:
            return
        source = self.listing_view.item(selected[0], "values")[-1]
        content = self.editor.get("1.0", "end-1c")
        position = content.find(source)
        if position >= 0:
            start = self.editor.index(f"1.0 + {position} chars")
            self.editor.see(start)
            self.editor.tag_remove("sel", "1.0", tk.END)
            self.editor.tag_add("sel", start, f"{start} lineend")

    def new_file(self) -> None:
        if messagebox.askyesno("新規", "現在の内容を破棄しますか？"):
            self.current_file = None
            self.title("k16 Assembler Studio - 無題")
            self._load_text("")
            self.assemble()

    def open_file(self) -> None:
        selected = filedialog.askopenfilename(
            title="アセンブリファイルを開く",
            filetypes=[("k16 assembly", "*.k16 *.asm *.s"), ("すべてのファイル", "*.*")],
        )
        if not selected:
            return
        path = Path(selected)
        try:
            try:
                content = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                content = path.read_text(encoding="cp932")
        except OSError as exc:
            messagebox.showerror("開く失敗", str(exc))
            return
        self.current_file = path
        self.title(f"k16 Assembler Studio - {path.name}")
        self._load_text(content)
        self.assemble()

    def save_file(self) -> None:
        if self.current_file is None:
            self.save_as()
            return
        try:
            self.current_file.write_text(self.editor.get("1.0", "end-1c"), encoding="utf-8")
        except OSError as exc:
            messagebox.showerror("保存失敗", str(exc))
            return
        self.status_label.configure(text=f"保存完了: {self.current_file.name}", foreground="#4EC9B0")

    def save_as(self) -> None:
        selected = filedialog.asksaveasfilename(
            title="名前を付けて保存", defaultextension=".k16",
            filetypes=[("k16 assembly", "*.k16"), ("assembly", "*.asm"), ("すべてのファイル", "*.*")],
        )
        if selected:
            self.current_file = Path(selected)
            self.save_file()
            self.title(f"k16 Assembler Studio - {self.current_file.name}")

    def export_hex(self) -> None:
        self.assemble()
        if not self.words:
            messagebox.showerror("HEX出力失敗", "アセンブル結果がありません。")
            return
        depth: int | None = None
        value = self.depth_entry.get().strip()
        if value:
            try:
                depth = int(value, 0)
            except ValueError:
                messagebox.showerror("HEX出力失敗", f"深度が不正です: {value}")
                return
        selected = filedialog.asksaveasfilename(
            title="HEXファイルを保存", initialfile="firmware.hex",
            defaultextension=".hex", filetypes=[("HEX", "*.hex"), ("すべてのファイル", "*.*")],
        )
        if selected:
            try:
                k16asm.write_hex(self.words, Path(selected), depth)
            except (OSError, ValueError) as exc:
                messagebox.showerror("HEX出力失敗", str(exc))
                return
            messagebox.showinfo("HEX出力", f"保存しました:\n{Path(selected).resolve()}")

    def export_listing(self) -> None:
        self.assemble()
        if not self.listing:
            messagebox.showerror("LST出力失敗", "リスティングがありません。")
            return
        selected = filedialog.asksaveasfilename(
            title="LSTファイルを保存", initialfile="listing.lst",
            defaultextension=".lst", filetypes=[("LST", "*.lst"), ("すべてのファイル", "*.*")],
        )
        if selected:
            try:
                with Path(selected).open("w", encoding="utf-8", newline="\n") as stream:
                    for address, word, source in self.listing:
                        disassembly = k16disasm.disassemble_word(word)
                        stream.write(f"{address:04X}  {word:06X}  {disassembly:<24} ; {source}\n")
            except OSError as exc:
                messagebox.showerror("LST出力失敗", str(exc))

    def load_sample(self) -> None:
        if messagebox.askyesno("サンプル", "現在の内容をサンプルで置き換えますか？"):
            self._load_text(SAMPLE_CODE)
            self.assemble()

    def show_reference(self) -> None:
        window = tk.Toplevel(self)
        window.title("k16 命令リファレンス")
        window.geometry("700x600")
        text = tk.Text(window, wrap="none", font=("Consolas", 11), padx=8, pady=8)
        text.insert("1.0", HELP_TEXT)
        text.configure(state="disabled")
        scroll = ttk.Scrollbar(window, command=text.yview)
        text.configure(yscrollcommand=scroll.set)
        scroll.pack(side=tk.RIGHT, fill=tk.Y)
        text.pack(fill=tk.BOTH, expand=True)

    def show_about(self) -> None:
        messagebox.showinfo("k16 Assembler Studio", "k16 16-bit CPU アセンブラ GUI\nPython 標準 Tkinter 実装")


def main() -> None:
    K16Studio().mainloop()


if __name__ == "__main__":
    main()
