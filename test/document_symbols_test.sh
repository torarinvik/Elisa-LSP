#!/usr/bin/env bash
# F02: document symbols — flat SymbolInformation and hierarchical DocumentSymbol
# shapes, source order, nested containment, exact declaration-name selection,
# prelude exclusion, restricted symbolKind.valueSet, unknown/closed URIs, and
# malformed-source safety.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]

DOC = ('def alpha(x: i64) -> i64:\n    return x\n\n'
       'enum Color:\n    Red\n    Green\n\n'
       'struct Point:\n    x: i64\n    y: i64\n\n'
       'const LIMIT: i64 = 10\n'
       'alias Num = Num.Num\n'
       'def main() -> int:\n    return 0\n')
URI = "file:///outline.elisa"


def symbols(caps, uri=URI, text=DOC):
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": text,
            }
        })
        result = client.request("textDocument/documentSymbol", {
            "textDocument": {"uri": uri},
        }, timeout=30)
        unknown = client.request("textDocument/documentSymbol", {
            "textDocument": {"uri": "file:///missing.elisa"},
        }, timeout=30)
        assert "result" in result, result
        assert "result" in unknown, unknown
        client.finish(timeout=30)
        return result["result"], unknown["result"]


# 1. Flat default: SymbolInformation with location, source order, no builtins.
flat, unknown = symbols({})
assert unknown == [], f"unknown URI must be empty: {unknown}"
names = [s["name"] for s in flat]
assert names == ["alpha", "Color", "Point", "LIMIT", "Num", "main"], names
assert all("location" in s and "range" in s["location"] for s in flat), "flat shape must be SymbolInformation"
assert not any("location" in s and s["location"]["uri"] != URI for s in flat), "location uri must echo"
kinds = {s["name"]: s["kind"] for s in flat}
assert kinds == {"alpha": 12, "Color": 10, "Point": 23, "LIMIT": 14, "Num": 5, "main": 12}, kinds
# source order by line
lines = [s["location"]["range"]["start"]["line"] for s in flat]
assert lines == sorted(lines), f"symbols must be source-ordered: {lines}"
assert all(not any(c in n for n in names) for c in ()), "sanity"

# 2. Hierarchical: DocumentSymbol with children; selection within range.
hier, _ = symbols({"textDocument": {"documentSymbol": {"hierarchicalDocumentSymbolSupport": True}}})
assert all("location" not in s and "children" in s for s in hier), "hier shape must be DocumentSymbol"
for s in hier:
    r, sr = s["range"], s["selectionRange"]
    assert (sr["start"]["line"] >= r["start"]["line"] and sr["end"]["line"] <= r["end"]["line"]), \
        f"selectionRange must be inside range: {s['name']} {r} {sr}"
    assert (sr["end"]["character"] >= sr["start"]["character"]), f"inverted selection: {s['name']}"
alpha_selection = next(s["selectionRange"] for s in hier if s["name"] == "alpha")
assert alpha_selection == {
    "start": {"line": 0, "character": 4},
    "end": {"line": 0, "character": 9},
}, alpha_selection
alias_selection = next(s["selectionRange"] for s in hier if s["name"] == "Num")
assert alias_selection == {
    "start": {"line": 12, "character": 6},
    "end": {"line": 12, "character": 9},
}, alias_selection

# 3. Restricted symbolKind.valueSet: nothing outside the set is emitted.
restricted, _ = symbols({"textDocument": {"documentSymbol": {"symbolKind": {"valueSet": [12, 10, 0.5, "15", True]}}}})
assert {s["name"] for s in restricted} == {"alpha", "Color", "main"}, [s["name"] for s in restricted]
assert all(s["kind"] in (12, 10) for s in restricted)

# 4. Malformed source still yields a valid outline (recovery), never malformed JSON.
BROKEN = "def good() -> void:\n    pass\ndef bad( -> void:\n"
br, _ = symbols({}, uri="file:///broken.elisa", text=BROKEN)
assert any(s["name"] == "good" for s in br), f"unfinished code must keep earlier decls: {br}"

# 5. Same-spelled declarations in different modules remain separate outline
# entries. The frontend's file-wide symbol table intentionally contains both;
# an outline must preserve their separate source identities instead of
# deduplicating by name. Validate every reported range against this source and
# keep each duplicate anchored to its own declaration line.
DUPLICATES = ('module Alpha:\n'
              '    struct Value:\n'
              '        left: i64\n'
              'module Beta:\n'
              '    struct Value:\n'
              '        right: i64\n')
dups_flat, _ = symbols({}, uri="file:///duplicates.elisa", text=DUPLICATES)
dups_hier, _ = symbols({"textDocument": {"documentSymbol": {"hierarchicalDocumentSymbolSupport": True}}},
                       uri="file:///duplicates.elisa", text=DUPLICATES)
assert [s["name"] for s in dups_flat] == ["Alpha", "Value", "Beta", "Value"], dups_flat
assert [s["name"] for s in dups_hier] == ["Alpha", "Beta"], dups_hier
assert [s["name"] for s in dups_hier[0]["children"]] == ["Value"], dups_hier
assert [s["name"] for s in dups_hier[1]["children"]] == ["Value"], dups_hier
assert dups_hier[0]["children"][0]["selectionRange"] == {
    "start": {"line": 1, "character": 11},
    "end": {"line": 1, "character": 16},
}, dups_hier
assert dups_hier[1]["children"][0]["selectionRange"] == {
    "start": {"line": 4, "character": 11},
    "end": {"line": 4, "character": 16},
}, dups_hier
assert dups_hier[0]["range"]["end"]["line"] == 2, dups_hier[0]
assert dups_hier[1]["range"]["end"]["line"] == 5, dups_hier[1]
source_lines = DUPLICATES.splitlines()
value_lines = [s["location"]["range"]["start"]["line"] for s in dups_flat if s["name"] == "Value"]
assert value_lines == [1, 4], f"duplicate names must retain distinct locations: {value_lines}"
assert all(source_lines[line].startswith("    struct Value:") for line in value_lines), \
       "each Value must point to its own declaration"

# Deeply nested module declarations keep their source order and attach each
# row to the nearest containing module. The compiler represents the inner
# module as one qualified symbol (`Outer::Inner`) beneath its real `Outer`
# row. A later sibling at the outer level must not be pulled into the inner
# module's range.
NESTED = ('module Outer:\n'
          '    module Inner:\n'
          '        def leaf() -> i64:\n'
          '            return 1\n'
          '    def sibling() -> i64:\n'
          '        return 2\n')
nested_hier, _ = symbols({"textDocument": {"documentSymbol": {"hierarchicalDocumentSymbolSupport": True}}},
                        uri="file:///nested-outline.elisa", text=NESTED)
assert [s["name"] for s in nested_hier] == ["Outer"], nested_hier
outer_children = nested_hier[0]["children"]
assert [s["name"] for s in outer_children] == ["Outer::Inner", "sibling"], outer_children
assert [s["name"] for s in outer_children[0]["children"]] == ["leaf"], outer_children
assert outer_children[0]["range"]["start"]["line"] == 1, outer_children[0]
assert outer_children[0]["range"]["end"]["line"] == 3, outer_children[0]
assert outer_children[1]["range"]["start"]["line"] == 4, outer_children[1]
def walk(items):
    for sym in items:
        yield sym
        yield from walk(sym.get("children", []))

for items, hierarchical in ((dups_flat, False), (list(walk(dups_hier)), True)):
    for sym in items:
        r = sym["range"] if hierarchical else sym["location"]["range"]
        start, end = r["start"], r["end"]
        assert 0 <= start["line"] <= end["line"] < len(source_lines), (sym, r)
        assert 0 <= start["character"] <= len(source_lines[start["line"]]), (sym, r)
        assert 0 <= end["character"] <= len(source_lines[end["line"]]), (sym, r)
        assert (start["line"], start["character"]) <= (end["line"], end["character"]), (sym, r)
        if hierarchical:
            sr = sym["selectionRange"]
            selection_start = (sr["start"]["line"], sr["start"]["character"])
            selection_end = (sr["end"]["line"], sr["end"]["character"])
            assert 0 <= selection_start[0] <= selection_end[0] < len(source_lines), (sym, sr)
            assert 0 <= selection_start[1] <= len(source_lines[selection_start[0]]), (sym, sr)
            assert 0 <= selection_end[1] <= len(source_lines[selection_end[0]]), (sym, sr)
            assert (start["line"], start["character"]) <= selection_start <= selection_end <= \
                   (end["line"], end["character"]), (sym, r, sr)

# 6. Hierarchical selection ranges use the negotiated position encoding for
# both endpoints. UTF-8 uses bytes, so the two-byte Greek identifier spans two
# characters even though its UTF-16 span is one code unit.
UNICODE = "def π() -> void:\n    pass\n"
unicode_hier, _ = symbols({
    "general": {"positionEncodings": ["utf-8"]},
    "textDocument": {"documentSymbol": {"hierarchicalDocumentSymbolSupport": True}},
}, uri="file:///unicode-outline.elisa", text=UNICODE)
assert len(unicode_hier) == 1 and unicode_hier[0]["name"] == "π", unicode_hier
unicode_selection = unicode_hier[0]["selectionRange"]
assert unicode_selection == {
    "start": {"line": 0, "character": 4},
    "end": {"line": 0, "character": 6},
}, unicode_selection

print("symbols OK: flat/hier shapes, order, nested module/function containment, exact declaration selection, prelude excluded, valueSet clamp, recovery, duplicate names, Unicode UTF-8 selection ranges and valid ranges")
PY
