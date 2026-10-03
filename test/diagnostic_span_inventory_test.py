#!/usr/bin/env python3
"""Keep static compiler span coverage pinned to the exact release frontend."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.diagnostic_span_inventory import build_inventory, scan_diagnostic_constructors


def main() -> int:
    synthetic = '''
# Diagnostic{kind: DiagnosticKind.TypeMismatch, pos: fake} is only a comment.
comment = "Diagnostic{kind: DiagnosticKind.TypeMismatch, pos: fake}"
one: Diagnostic = Diagnostic{
    kind: Semantic::DiagnosticKind.TypeMismatch,
    name: "x, }",
    pos: Ast::Pos{line: 1, column: 2, offset: 3, end_line: 1, end_column: 4, end_offset: 5},
}
two: Diagnostic = Diagnostic{kind: runtime_kind, line: 7, expected: "", actual: ""}
three: Diagnostic = Diagnostic{kind: DiagnosticKind.UndefinedName, line: 8, expected: "", actual: ""}
'''
    synthetic_rows = scan_diagnostic_constructors(synthetic, "synthetic.elisa")
    assert synthetic_rows == [
        {
            "kind": "TypeMismatch",
            "explicit_position_argument": True,
            "site": "synthetic.elisa:4",
        },
        {
            "kind": "runtime_kind",
            "explicit_position_argument": False,
            "site": "synthetic.elisa:9",
        },
        {
            "kind": "UndefinedName",
            "explicit_position_argument": False,
            "site": "synthetic.elisa:10",
        },
    ], synthetic_rows

    manifest_path = ROOT / "build/manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    compiler_root = Path(manifest["staged_compiler_root"])
    assert compiler_root.is_dir(), f"manifest compiler snapshot missing: {compiler_root}"
    actual = build_inventory(compiler_root)
    assert actual["compiler_source_fingerprint"] == manifest["compiler_sources_sha256"]

    inventory_path = ROOT / "docs/diagnostic-span-coverage.json"
    recorded = json.loads(inventory_path.read_text(encoding="utf-8"))
    assert recorded == actual, (
        "diagnostic span inventory is stale; regenerate with "
        "scripts/diagnostic_span_inventory.py against the manifest-pinned compiler snapshot"
    )

    summary = actual["summary"]
    assert summary["construction_site_count"] == (
        summary["classified_construction_site_count"]
        + summary["unclassified_construction_site_count"]
    )
    assert summary["explicit_position_site_count"] + summary["default_position_site_count"] == summary["construction_site_count"]
    assert len(actual["diagnostics"]) == summary["diagnostic_kind_count"]
    assert summary["unclassified_construction_site_count"] == len(summary["unclassified_sites"])
    print(
        "diagnostic span coverage inventory OK: "
        f"{summary['construction_site_count']} compiler constructors, "
        f"{summary['diagnostic_kind_count']} DiagnosticKind values, "
        f"{summary['default_position_site_count']} without explicit pos, "
        f"frontend {actual['compiler_source_fingerprint'][:12]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
