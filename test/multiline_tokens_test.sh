#!/usr/bin/env bash
# H03: semantic tokens never cross a line. Multiline comments (and any span
# wider than its start line) split into valid per-line tokens; CRLF's CR is
# excluded; Unicode lines convert through the shared coordinate layer.
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


def tokens_for(text):
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": {}})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": "file:///mt.elisa",
                "languageId": "Elisa",
                "version": 1,
                "text": text,
            }
        })
        response = client.request("textDocument/semanticTokens/full", {
            "textDocument": {"uri": "file:///mt.elisa"},
        }, timeout=30)
        assert "result" in response, response
        data = response["result"]["data"]
        client.finish(timeout=30)
    toks, line, col = [], 0, 0
    for i in range(0, len(data), 5):
        dl, dc, length, tt, _ = data[i:i + 5]
        line += dl
        col = (col + dc) if dl == 0 else dc
        toks.append((line, col, length, tt))
    return toks


def u16len(s):
    return len(s.encode("utf-16-le")) // 2


def check(text, label):
    lines = [line[:-1] if line.endswith("\r") else line for line in text.split("\n")]
    toks = tokens_for(text)
    prev = None
    for (line, col, length, tt) in toks:
        assert 0 <= line < len(lines), f"{label}: line OOB {line}"
        assert length > 0, f"{label}: zero-length token {(line, col, length, tt)}"
        assert col + length <= u16len(lines[line]), \
            f"{label}: token crosses its line: line={line} {col}+{length} > {u16len(lines[line])} ({lines[line]!r})"
        if prev is not None:
            assert (line, col) >= (prev[0], prev[1]), f"{label}: out of order {prev} -> {(line, col, length, tt)}"
            if line == prev[0]:
                assert col >= prev[1] + prev[2], \
                    f"{label}: overlap at line {line}: {prev} then {(line, col, length, tt)}"
        prev = (line, col, length, tt)
    return toks


# 1. Multiline doc comment: every covered line carries a comment token.
doc = ('def f() -> void:\n'
       '    x: i64 = 1\n'
       '    """\n'
       '    a doc comment\n'
       '    spanning lines\n'
       '    """\n'
       '    y: i64 = 2\n')
toks = check(doc, "LF")
comment_lines = sorted({t[0] for t in toks if t[3] == 40})
assert comment_lines == [2, 3, 4, 5], f"multiline comment must cover lines 2-5: {comment_lines}"

# 2. CRLF: the CR is excluded from every comment piece.
crlf = doc.replace("\n", "\r\n")
toks = check(crlf, "CRLF")
for (line, col, length, tt) in toks:
    if tt == 40:
        assert crlf.split("\r\n")[line][col:col + length].find("\r") == -1, \
            "CR leaked into a token"

# A normal code token can be reported by the frontend at the CR byte itself.
# That byte is outside the LSP line, so it must be omitted from semantic spans.
simple_crlf = "def cr() -> void:\r\n    pass\r\n"
check(simple_crlf, "simple CRLF")

# 3. Unicode inside a multiline comment: unit lengths stay in bounds.
uni = ('def f() -> void:\n'
       '    """\n'
       '    héllo 🌍 wörld\n'
       '    """\n'
       '    pass\n')
toks = check(uni, "unicode")
assert any(t[3] == 40 for t in toks if t[0] == 2), "unicode comment line must be tokenized"

print("multiline tokens OK: per-line split, no crossings, CRLF/Unicode safe")
PY
