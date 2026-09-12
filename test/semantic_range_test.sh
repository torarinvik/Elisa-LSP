#!/usr/bin/env bash
# H05: semanticTokens/range — decode the cached full result, keep entries
# intersecting the requested range, and re-encode from document zero (not the
# range start). Whole-document range equals the full result; empty/unknown yield
# empty; malformed ranges clamp.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
DOC = ('def f() -> void:\n'      # 0
       '    x: i64 = 1\n'        # 1
       '    y: i64 = 2\n'        # 2
       '    return\n')           # 3
def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
msgs = [frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})]
msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                   "params":{"textDocument":{"uri":"file:///rng.elisa","languageId":"Elisa","version":1,"text":DOC}}}))
msgs.append(frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
                   "params":{"textDocument":{"uri":"file:///rng.elisa"}}}))
def rng(i, sline, schar, eline, echar, uri="file:///rng.elisa"):
    return frame({"jsonrpc":"2.0","id":i,"method":"textDocument/semanticTokens/range",
                  "params":{"textDocument":{"uri":uri},"range":{"start":{"line":sline,"character":schar},
                                                                 "end":{"line":eline,"character":echar}}}})
msgs.append(rng(3, 1, 0, 1, 99))          # line 1 only
msgs.append(rng(4, 0, 0, 3, 99))          # whole document
msgs.append(rng(5, 3, 0, 3, 0))           # empty range
msgs.append(rng(6, 1, 8, 2, 6))           # spans the line 1/2 boundary
msgs.append(rng(7, -5, -5, 999, 999))     # malformed -> clamped to document
msgs.append(rng(8, 0, 0, 0, 0, uri="file:///absent.elisa"))
msgs.append(frame({"jsonrpc":"2.0","id":9,"method":"shutdown"}))
msgs.append(frame({"jsonrpc":"2.0","method":"exit"}))
p = subprocess.run([srv], input=b"".join(msgs), capture_output=True, timeout=30)
assert p.returncode == 0
out, pos, res = p.stdout, 0, {}
while pos < len(out):
    sep = out.find(b"\r\n\r\n", pos)
    ln = int(out[pos:sep].split(b":",1)[1].strip())
    start = sep+4
    msg = json.loads(out[start:start+ln])  # every frame valid JSON
    if msg.get("id") in (2,3,4,5,6,7,8): res[msg["id"]] = msg["result"]["data"]
    pos = start+ln
def decode(data):
    line = col = 0
    out = []
    for i in range(0, len(data), 5):
        dl, dc, ln, tt, mods = data[i:i+5]
        assert mods == 0
        line += dl
        col = (col + dc) if dl == 0 else dc
        out.append((line, col, ln, tt))
    return out

full = decode(res[2])
line1 = decode(res[3])
assert line1 == [(l,c,n,t) for (l,c,n,t) in full if l == 1], f"line range wrong: {line1}"
# Re-encoded from document zero: first entry carries its absolute line.
assert line1 and line1[0][0] == 1, f"range must use document-zero baseline: {line1}"

# Whole-document range equals the full result exactly.
assert res[4] == res[2], "whole-document range must equal full"
# Empty range -> empty.
assert res[5] == [], res[5]
# Boundary-spanning range keeps tokens from both lines.
bound = decode(res[6])
lines = {l for (l,_,_,_) in bound}
assert lines == {1, 2}, f"boundary range lines: {lines}"
# Malformed range clamps to the document (same as whole-document).
assert res[7] == res[2], "malformed range must clamp to the document"
# Unknown URI -> empty, no crash.
assert res[8] == [], res[8]

print(f"semantic range OK: {len(line1)} tokens on line 1, document-zero baseline, clamping")
PY
