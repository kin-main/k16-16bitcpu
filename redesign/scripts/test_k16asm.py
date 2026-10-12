import tempfile
import unittest
from pathlib import Path

from k16asm import AssemblerError, assemble, assemble_line, encode_i, encode_r


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

    def test_rejects_special_register_writes_and_large_immediates(self):
        for source in ("LI r0, 1", "ADD r14, r1, r2", "ADDI r1, r0, 256"):
            with self.assertRaises(AssemblerError):
                self.assemble_text(source)

    def test_interactive_single_line_assembly(self):
        self.assertEqual(assemble_line("LI r1, 10 ; explanation"), [encode_i(0, 1, 0, 10, 4)])


if __name__ == "__main__":
    unittest.main()
