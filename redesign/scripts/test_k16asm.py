import tempfile
import unittest
from pathlib import Path

<<<<<<< HEAD
from k16asm import (
    AssemblerError,
    MNEMONICS,
    assemble,
    assemble_line,
    encode_i,
    encode_r,
)
=======
from k16asm import AssemblerError, MNEMONICS, assemble, assemble_line, encode_i, encode_r
>>>>>>> bf3719485c4b0f76c70152074a8499d4f52adacb


class AssemblerTests(unittest.TestCase):
    def assemble_text(self, text):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "test.k16"
            source.write_text(text, encoding="utf-8")
            return assemble(source)

    def test_labels_and_call_listing_words(self):
        words, listing = self.assemble_text(
            """
            start:
                LI r1, 3
                CALL done
                SHR r2, r1
            done:
                RET
            """
        )
        self.assertEqual(words[0], encode_i(0, 1, 0, 3, 4))
        self.assertEqual(words[1], encode_i(0, 12, 15, 2, 4))
        self.assertEqual(words[2], encode_i(0, 15, 0, 4, 4))
        self.assertEqual(len(listing), 5)

    def test_memory_sign_and_comments(self):
        words, _ = self.assemble_text("LD.eq r3, [r4 - 7] # comment\nST r3, [r4 + 2]")
        self.assertEqual(words[0], (5 << 21) | (3 << 19) | (3 << 15) | (4 << 11) | (7 << 2) | 1)
        self.assertEqual(words[1], (3 << 19) | (3 << 15) | (4 << 11) | (2 << 2) | 2)

    def test_allows_special_register_writes_and_rejects_large_immediates(self):
        # r0/r14 への書き込みはハードウェア仕様で無視（破棄）されるため、アセンブラで許可される
        words, _ = self.assemble_text("SUB r0, r1, r2\nADD r14, r1, r2")
        self.assertEqual(words[0], encode_r(0, 0, 1, 2, 5))
        self.assertEqual(words[1], encode_r(0, 14, 1, 2, 4))

        # 即値オーバーフローは拒絶される
        with self.assertRaises(AssemblerError):
            self.assemble_text("ADDI r1, r0, 256")

    def test_cmp_test_and_two_operand_syntax(self):
        # CMP r1, r2 は SUB r0, r1, r2
        self.assertEqual(assemble_line("CMP r1, r2"), [encode_r(0, 0, 1, 2, 5)])
        # CMPI r1, 10 は SUBI r0, r1, 10
        self.assertEqual(assemble_line("CMPI r1, 10"), [encode_i(0, 0, 1, 10, 5)])
        # TEST r1, r2 は AND r0, r1, r2
        self.assertEqual(assemble_line("TEST r1, r2"), [encode_r(0, 0, 1, 2, 2)])
        # TESTI r1, 0x0F は ANDI r0, r1, 0x0F
        self.assertEqual(assemble_line("TESTI r1, 0x0F"), [encode_i(0, 0, 1, 0x0F, 2)])

        # 2オペランド構文: ADD r1, r2 -> ADD r1, r1, r2
        self.assertEqual(assemble_line("ADD r1, r2"), [encode_r(0, 1, 1, 2, 4)])
        # 2オペランド構文: ADDI r1, 5 -> ADDI r1, r1, 5
        self.assertEqual(assemble_line("ADDI r1, 5"), [encode_i(0, 1, 1, 5, 4)])
        # 1オペランド SHR: SHR r1 -> SHR r1, r1
        self.assertEqual(assemble_line("SHR r1"), [encode_r(0, 1, 1, 0, 7)])

    def test_interactive_single_line_assembly(self):
        self.assertEqual(assemble_line("LI r1, 10 ; explanation"), [encode_i(0, 1, 0, 10, 4)])

    def test_mnemonic_list_covers_supported_instruction_groups(self):
<<<<<<< HEAD
        names = {mnemonic for mnemonic, _ in MNEMONICS}
        self.assertTrue({"NOP", "LI", "ADD", "ADDI", "LD", "ST", "CMP", "CMPI", "TEST", "TESTI"} <= names)
=======
        listed = {name for name, _ in MNEMONICS}
        self.assertTrue({"NOP", "LI", "ADD", "ADDI", "LD", "ST"}.issubset(listed))
>>>>>>> bf3719485c4b0f76c70152074a8499d4f52adacb


if __name__ == "__main__":
    unittest.main()

