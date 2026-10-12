#!/usr/bin/env python3
"""Run the k16 assembler from the repository root.

The implementation is shared with the memo-faithful redesign assembler so
that both build trees use the same instruction encoding.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def _load_assembler():
    assembler_path = Path(__file__).parent / "redesign" / "scripts" / "k16asm.py"
    spec = importlib.util.spec_from_file_location("k16asm_impl", assembler_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load assembler: {assembler_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


_impl = _load_assembler()
AssemblerError = _impl.AssemblerError
assemble = _impl.assemble
assemble_line = _impl.assemble_line
encode_i = _impl.encode_i
encode_r = _impl.encode_r


def main() -> int:
    return _impl.main()


if __name__ == "__main__":
    raise SystemExit(main())
