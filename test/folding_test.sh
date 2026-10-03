#!/usr/bin/env bash
# E04: folding ranges — nested indentation regions, comment runs and doc
# blocks, line-only shape, rangeLimit, unknown URI, and no empty folds.
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
DOC = ('def outer() -> void:\n'        # 0
       '    x: i64 = 1\n'              # 1
       '    if x > 0:\n'               # 2
       '        y: i64 = 2\n'          # 3
       '        while y > 0:\n'        # 4
       '            y <- y - 1\n'      # 5
       '    # a comment line\n'        # 6
       '    # another comment line\n'  # 7
       '    """\n'                      # 8
       '    doc block\n'                # 9
       '    """\n'                      # 10
       '    return\n')                  # 11


def folds(caps, uri="file:///fold.elisa", text=DOC):
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
        result = client.request("textDocument/foldingRange", {
            "textDocument": {"uri": uri},
        }, timeout=30)
        missing = client.request("textDocument/foldingRange", {
            "textDocument": {"uri": "file:///missing.elisa"},
        }, timeout=30)
        assert "result" in result, result
        assert "result" in missing, missing
        client.finish(timeout=30)
        return result["result"], missing["result"]


fs, miss = folds({})
assert miss == [], f"unknown URI must be empty: {miss}"
pairs = [(f["startLine"], f["endLine"]) for f in fs]
assert (0, 11) in pairs, f"outer function body fold missing: {pairs}"
assert (2, 5) in pairs, f"if-block fold missing: {pairs}"
assert (4, 5) in pairs, f"while-block fold missing: {pairs}"
comments = [(f["startLine"], f["endLine"]) for f in fs if f.get("kind") == "comment"]
assert (6, 7) in comments, f"comment-run fold missing: {comments}"
assert (8, 10) in comments, f"doc-block fold missing: {comments}"
for f in fs:
    assert f["startLine"] < f["endLine"], f"empty/inverted fold: {f}"
    assert f["endLine"] < len(DOC.split("\n")), f"fold beyond EOF: {f}"
    # line-only shape: no character fields.
    assert "startCharacter" not in f and "endCharacter" not in f, f"non-line fold: {f}"

# rangeLimit caps the number of returned folds.
limited, _ = folds({"textDocument": {"foldingRange": {"rangeLimit": 2}}})
assert len(limited) == 2, f"rangeLimit not honored: {limited}"

# lineFoldingOnly clients get the same line-only ranges.
lfo, _ = folds({"textDocument": {"foldingRange": {"lineFoldingOnly": True}}})
assert lfo == fs, "lineFoldingOnly must not change line-only output"

print(f"folding OK: {len(fs)} nested/comment folds, limit honored, unknown empty")
PY
