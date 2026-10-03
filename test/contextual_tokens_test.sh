#!/usr/bin/env bash
# H02: resolved bindings beat contextual-word spelling, while signature syntax
# keeps its contextual keyword classification when it shares a line/name.
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
uri = "file:///contextual-tokens.elisa"
source = "def demo(can: i64) can[Console]:\n    return can\n"

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    legend = initialized["result"]["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"]
    assert legend[16] == "elisa.bind.param"
    assert legend[21] == "elisa.effect.grant"
    assert legend[27] == "elisa.flow.branch"

    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": 1,
            "text": source,
        }
    })
    response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    })
    assert "result" in response, response
    data = response["result"]["data"]
    client.finish(timeout=30)

decoded = []
line = col = 0
for i in range(0, len(data), 5):
    dline, dcol, length, token_type, _mods = data[i:i + 5]
    line += dline
    col = col + dcol if dline == 0 else dcol
    decoded.append((line, col, length, token_type))

def type_at(line_no, column, text):
    matches = [
        token_type
        for token_line, token_col, length, token_type in decoded
        if token_line == line_no and token_col == column and length == len(text)
    ]
    assert len(matches) == 1, (line_no, column, text, matches, decoded)
    return matches[0]

# The parameter declaration and its use resolve as parameters. The same spelling
# in the signature's `can[...]` clause remains the effect-grant keyword.
assert type_at(0, 9, "can") == 16
assert type_at(0, 19, "can") == 21
assert type_at(1, 11, "can") == 16
# Reserved lexer keywords keep their syntactic token class alongside the
# contextual identifier checks above.
assert type_at(1, 4, "return") == 27
print("contextual tokens OK: resolved binding and signature keyword retain distinct classes")
PY
