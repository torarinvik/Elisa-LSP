#!/usr/bin/env python3
"""The configured compiler checkout, not the adjacent default, owns includes."""
from __future__ import annotations

import importlib.util
import hashlib
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_hashes", ROOT / "scripts" / "build_hashes.py")
assert SPEC is not None and SPEC.loader is not None
BUILD_HASHES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD_HASHES)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="elisa-lsp-override-test-") as temporary:
        base = Path(temporary)
        lsp = base / "Elisa-LSP"
        source = lsp / "src" / "main.elisa"
        source.parent.mkdir(parents=True)
        source.write_text('include "../../Elisa-compiler/src/semantic/semantic.elisa"\n', encoding="utf-8")

        adjacent = base / "Elisa-compiler"
        selected = base / "Elisa-compiler-latest"
        for compiler_root, contents in ((adjacent, "adjacent-default\n"), (selected, "selected-override\n")):
            frontend = compiler_root / "src" / "semantic" / "semantic.elisa"
            frontend.parent.mkdir(parents=True)
            frontend.write_text(contents, encoding="utf-8")

        fake_compiler = base / "elisac-stage0"
        fake_compiler.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        fake_compiler.chmod(0o755)

        closure = BUILD_HASHES.compiler_include_closure(lsp, selected, fake_compiler)
        compiler_records = [record for record in closure["files"] if record["path"] == "compiler/src/semantic/semantic.elisa"]
        assert closure["mode"] == "recursive-include-parser", closure
        assert len(compiler_records) == 1, closure
        expected = hashlib.sha256(b"selected-override\n").hexdigest()
        assert compiler_records[0]["sha256"] == expected, compiler_records
        print("build_hashes_override_test: PASS")


if __name__ == "__main__":
    main()
