#!/usr/bin/env python3
"""Generate the Elisa-LSP diagnostic-code adapter from the compiler enum.

The LSP exposes stable names of the form ``ELISA-<DiagnosticKind>``.  The
compiler owns wording and severity; this generated adapter only gives each enum
member a machine-readable identifier.  Run with ``--check`` in CI to reject a
frontend enum change that has not been reviewed and regenerated.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ENUM_RELATIVE = Path("src/semantic/semantic_types_diagnostic_kind.elisa")
VARIANT_RE = re.compile(r"^\s{12}([A-Za-z_][A-Za-z0-9_]*)\s*$", re.MULTILINE)
ENUM_START_RE = re.compile(r"^\s{8}const enum DiagnosticKind of u16:\s*$", re.MULTILINE)
ENUM_END_RE = re.compile(r"^\s{8}(?:const enum|enum|extend)\b", re.MULTILINE)


def enum_variants(path: Path) -> list[str]:
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise SystemExit(f"error: cannot read DiagnosticKind enum {path}: {exc}")
    start = ENUM_START_RE.search(source)
    if start is None:
        raise SystemExit(f"error: DiagnosticKind enum declaration not found in {path}")
    tail = source[start.end() :]
    # The enum is the final declaration in the current frontend file.  Keep the
    # extraction conservative: only the exact enum-member indentation is valid.
    end = ENUM_END_RE.search(tail)
    body = tail[: end.start()] if end else tail
    variants = VARIANT_RE.findall(body)
    if not variants:
        raise SystemExit(f"error: DiagnosticKind enum has no variants in {path}")
    if len(set(variants)) != len(variants):
        raise SystemExit("error: DiagnosticKind enum contains duplicate variant names")
    return variants


def render(compiler_root: Path, variants: list[str]) -> str:
    lines = [
        "# GENERATED FILE. Do not edit by hand.",
        "# Source: src/semantic/semantic_types_diagnostic_kind.elisa in the pinned compiler.",
        "# Regenerate with: python3 scripts/generate_diagnostic_codes.py",
        "# Stable identifiers are ELISA-<DiagnosticKind>; wording/severity remain frontend-owned.",
        "def diagnostic_code(kind: Semantic::DiagnosticKind) -> sview:",
        "    return match kind:",
    ]
    lines.extend(f'        Semantic::DiagnosticKind.{name}: "ELISA-{name}"' for name in variants)
    lines.extend([
        '        _: "ELISA-Unknown"',
        "",
    ])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler-root", type=Path, help="Elisa-compiler checkout")
    parser.add_argument("--output", type=Path, default=Path("src/diagnostic_codes.elisa"))
    parser.add_argument("--check", action="store_true", help="fail when output is not current")
    args = parser.parse_args()
    root = args.compiler_root
    if root is None:
        root = Path(__file__).resolve().parents[1].parent / "Elisa-compiler"
    root = root.resolve()
    variants = enum_variants(root / ENUM_RELATIVE)
    rendered = render(root, variants)
    if args.check:
        try:
            current = args.output.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            print(f"error: cannot read generated adapter {args.output}: {exc}", file=sys.stderr)
            return 2
        if current != rendered:
            print(
                f"error: {args.output} is stale for {root / ENUM_RELATIVE} ({len(variants)} variants); regenerate it",
                file=sys.stderr,
            )
            return 1
        print(f"diagnostic code adapter is current ({len(variants)} variants): {args.output}")
        return 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")
    print(f"generated {args.output} from {root / ENUM_RELATIVE} ({len(variants)} variants)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
