#!/usr/bin/env python3
"""Inventory compiler diagnostic constructors with and without explicit spans.

This is a source audit, not proof that an explicit ``pos`` value is accurate at
runtime. Exact/Unicode range behavior is separately exercised by the LSP
diagnostic integration tests. Keeping this inventory tied to the compiler
source fingerprint makes default-position producers reviewable after upgrades.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.build_hashes import compiler_sources_sha256
from scripts.generate_diagnostic_codes import enum_variants


CONSTRUCTOR_RE = re.compile(r"\bDiagnostic\b\s*\{")
FIELD_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:")
KIND_RE = re.compile(r"\bDiagnosticKind\.([A-Za-z_][A-Za-z0-9_]*)\b")
IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _mask_literals_and_comments(source: str) -> str:
    """Replace comments and quoted text with spaces while preserving newlines."""
    chars = list(source)
    index = 0
    while index < len(source):
        if source[index] == "#":
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            for cursor in range(index, end):
                chars[cursor] = " "
            index = end
            continue

        quote = source[index]
        if quote not in ("\"", "'"):
            index += 1
            continue

        delimiter = quote * 3 if quote == '"' and source.startswith('"""', index) else quote
        cursor = index + len(delimiter)
        while cursor < len(source):
            if source[cursor] == "\\":
                cursor += 2
                continue
            if source.startswith(delimiter, cursor):
                cursor += len(delimiter)
                break
            cursor += 1
        for position in range(index, min(cursor, len(source))):
            if source[position] != "\n":
                chars[position] = " "
        index = cursor
    return "".join(chars)


def _split_constructor_fields(masked: str, opening: int) -> list[str] | None:
    """Split named fields at the constructor's outer level; return None if unclosed."""
    fields: list[str] = []
    stack: list[str] = []
    field_start = opening
    matching = {")": "(", "]": "[", "}": "{"}
    for index in range(opening, len(masked)):
        char = masked[index]
        if char in "([{":
            stack.append(char)
        elif char in ")]}":
            if char == "}" and not stack:
                fields.append(masked[field_start:index])
                return fields
            if not stack or stack[-1] != matching[char]:
                return None
            stack.pop()
        elif char == "," and not stack:
            fields.append(masked[field_start:index])
            field_start = index + 1
    return None


def scan_diagnostic_constructors(source: str, relative_path: str) -> list[dict[str, Any]]:
    """Return source sites and explicit-position status for Diagnostic literals."""
    masked = _mask_literals_and_comments(source)
    records: list[dict[str, Any]] = []
    for match in CONSTRUCTOR_RE.finditer(masked):
        fields = _split_constructor_fields(masked, match.end())
        if fields is None:
            line = source.count("\n", 0, match.start()) + 1
            raise ValueError(f"unclosed Diagnostic literal at {relative_path}:{line}")

        kind = "dynamic/unknown"
        has_position = False
        for field in fields:
            field_match = FIELD_RE.match(field)
            if field_match is None:
                continue
            field_name = field_match.group(1)
            if field_name == "pos":
                has_position = True
            elif field_name == "kind":
                kind_match = KIND_RE.search(field)
                if kind_match is not None:
                    kind = kind_match.group(1)
                else:
                    value = field[field_match.end():].strip()
                    kind = value if IDENTIFIER_RE.fullmatch(value) else "dynamic/unknown"

        records.append({
            "kind": kind,
            "explicit_position_argument": has_position,
            "site": f"{relative_path}:{source.count(chr(10), 0, match.start()) + 1}",
        })
    return records


def build_inventory(compiler_root: Path) -> dict[str, Any]:
    compiler_root = compiler_root.resolve(strict=True)
    source_root = compiler_root / "src"
    if not source_root.is_dir():
        raise ValueError(f"compiler source directory is missing: {source_root}")

    variants = enum_variants(compiler_root / "src/semantic/semantic_types_diagnostic_kind.elisa")
    records: list[dict[str, Any]] = []
    source_files = sorted(source_root.rglob("*.elisa"))
    for path in source_files:
        relative = path.relative_to(compiler_root).as_posix()
        records.extend(scan_diagnostic_constructors(path.read_text(encoding="utf-8"), relative))

    stats: dict[str, dict[str, Any]] = defaultdict(lambda: {
        "construction_sites": 0,
        "explicit_position_sites": 0,
        "default_position_sites": [],
    })
    known_kinds = set(variants)
    unclassified: list[dict[str, Any]] = []
    unknown_kind_names: set[str] = set()
    explicit_position_sites = 0
    for record in records:
        kind = record["kind"]
        explicit_position_sites += int(record["explicit_position_argument"])
        if kind not in known_kinds:
            unclassified.append({
                "kind_expression": kind,
                "site": record["site"],
                "explicit_position_argument": record["explicit_position_argument"],
            })
            unknown_kind_names.add(kind)
            continue
        entry = stats[kind]
        entry["construction_sites"] += 1
        if record["explicit_position_argument"]:
            entry["explicit_position_sites"] += 1
        else:
            entry["default_position_sites"].append(record["site"])

    diagnostics = []
    for kind in sorted(variants):
        entry = stats.get(kind, {
            "construction_sites": 0,
            "explicit_position_sites": 0,
            "default_position_sites": [],
        })
        diagnostics.append({
            "kind": kind,
            "construction_sites": entry["construction_sites"],
            "explicit_position_sites": entry["explicit_position_sites"],
            "default_position_sites": sorted(entry["default_position_sites"]),
        })

    summary = {
        "diagnostic_kind_count": len(variants),
        "source_file_count": len(source_files),
        "construction_site_count": len(records),
        "classified_construction_site_count": len(records) - len(unclassified),
        "unclassified_construction_site_count": len(unclassified),
        "kinds_with_constructors": sum(1 for item in diagnostics if item["construction_sites"]),
        "kinds_with_only_explicit_position_arguments": sum(
            1 for item in diagnostics
            if item["construction_sites"] and not item["default_position_sites"]
        ),
        "kinds_with_default_position_sites": sum(
            1 for item in diagnostics if item["default_position_sites"]
        ),
        "explicit_position_site_count": explicit_position_sites,
        "default_position_site_count": len(records) - explicit_position_sites,
        "unclassified_explicit_position_site_count": sum(
            1 for item in unclassified if item["explicit_position_argument"]
        ),
        "unclassified_default_position_site_count": sum(
            1 for item in unclassified if not item["explicit_position_argument"]
        ),
        "unclassified_sites": sorted(unclassified, key=lambda item: (item["kind_expression"], item["site"])),
        "unknown_kind_names": sorted(unknown_kind_names),
    }
    return {
        "schema_version": 1,
        "compiler_source_fingerprint": compiler_sources_sha256(compiler_root),
        "inventory_method": "static_named_struct_literal_scan",
        "position_field_semantics": "An explicit pos field is not proof of a precise or valid runtime span. The LSP integration tests separately verify exact ranges and bounded fallback behavior.",
        "summary": summary,
        "diagnostics": diagnostics,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler-root", type=Path, required=True, help="exact Elisa compiler source snapshot")
    parser.add_argument("--output", type=Path, default=Path("docs/diagnostic-span-coverage.json"))
    parser.add_argument("--check", action="store_true", help="fail when the inventory is stale")
    args = parser.parse_args()

    try:
        inventory = build_inventory(args.compiler_root)
        rendered = json.dumps(inventory, indent=2, ensure_ascii=False) + "\n"
        if args.check:
            current = args.output.read_text(encoding="utf-8")
            if current != rendered:
                raise ValueError(
                    f"{args.output} is stale for compiler source fingerprint "
                    f"{inventory['compiler_source_fingerprint']}"
                )
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(rendered, encoding="utf-8")
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"diagnostic span inventory error: {exc}", file=sys.stderr)
        return 2

    summary = inventory["summary"]
    print(
        "diagnostic span inventory OK: "
        f"{summary['construction_site_count']} constructors, "
        f"{summary['diagnostic_kind_count']} kinds, "
        f"{summary['default_position_site_count']} constructors without explicit positions, "
        f"compiler {inventory['compiler_source_fingerprint'][:12]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
