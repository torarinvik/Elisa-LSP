#!/usr/bin/env bash
# H03: semantic tokens never cross a line. Multiline comments (and any span
# wider than its start line) split into valid per-line tokens; CRLF's CR is
# excluded; Unicode lines convert through the shared coordinate layer.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def tokens_for(text):
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":"file:///mt.elisa","languageId":"Elisa","version":1,"text":text}}})
    m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
                "params":{"textDocument":{"uri":"file:///mt.elisa"}}})
    m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    p = subprocess.run([srv], input=m, capture_output=True, timeout=30)
    assert p.returncode == 0
    out, pos, data = p.stdout, 0, None
    while pos < len(out):
        sep = out.find(b"\r\n\r\n", pos)
        ln = int(out[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(out[start:start+ln])
        if msg.get("id") == 2:
            data = msg["result"]["data"]
        pos = start+ln
    assert data is not None
    toks, line, col = [], 0, 0
    for i in range(0, len(data), 5):
        dl, dc, ln, tt, _ = data[i:i+5]
        line += dl; col = (col + dc) if dl == 0 else dc
        toks.append((line, col, ln, tt))
    return toks

def u16len(s):
    return len(s.encode("utf-16-le")) // 2

def check(text, label):
    lines = text.split("\n")
    toks = tokens_for(text)
    prev = None
    for (line, col, ln, tt) in toks:
        assert 0 <= line < len(lines), f"{label}: line OOB {line}"
        assert ln > 0, f"{label}: zero-length token {(line,col,ln,tt)}"
        assert col + ln <= u16len(lines[line]), \
            f"{label}: token crosses its line: line={line} {col}+{ln} > {u16len(lines[line])} ({lines[line]!r})"
        if prev is not None:
            assert (line, col) >= (prev[0], prev[1]), f"{label}: out of order {prev} -> {(line,col,ln,tt)}"
            if line == prev[0]:
                assert col >= prev[1] + prev[2], f"{label}: overlap at line {line}: {prev} then {(line,col,ln,tt)}"
        prev = (line, col, ln, tt)
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
for (line, col, ln, tt) in toks:
    if tt == 40:
        assert crlf.split("\r\n")[line][col:col+ln].find("\r") == -1, "CR leaked into a token"

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
