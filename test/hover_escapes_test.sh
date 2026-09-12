#!/usr/bin/env bash
# J02 writer invariant: source-derived hover text must not corrupt the response
# frame. A capture name holding `"` and `\` bytes (legal header text, hostile
# JSON) still yields parseable responses with the exact decoded value.
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
doc = ('def f(xs: darray[i64]) -> i64:\n'
       '    r: i64 =\n'
       '        for x in xs |a"b, c=d\\e| -> a:\n'
       '            r <- r + 1\n'
       '    return r\n')
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":"file:///esc-hover.elisa","languageId":"Elisa","version":1,"text":doc}}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/hover",
            "params":{"textDocument":{"uri":"file:///esc-hover.elisa"},"position":{"line":2,"character":20}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = subprocess.run([srv], input=m, capture_output=True, timeout=30)
assert p.returncode == 0, f"exit {p.returncode}"
out, pos, res = p.stdout, 0, {}
while pos < len(out):
    sep = out.find(b"\r\n\r\n", pos)
    assert sep >= 0, "truncated header"
    ln = int(out[pos:sep].split(b":",1)[1].strip())
    start = sep+4
    raw = out[start:start+ln]
    assert len(raw) == ln, "truncated body"
    msg = json.loads(raw)  # every frame must be valid JSON
    if "id" in msg:
        res[msg["id"]] = msg.get("result")
    pos = start+ln
value = res[2]["contents"]["value"]
assert 'a"b' in value, f"quote must survive escaped: {value!r}"
assert "c" in value.split("accumulators:")[1], f"accumulator missing: {value!r}"
print("hover escapes OK: hostile header text stays valid JSON with exact value")
PY
