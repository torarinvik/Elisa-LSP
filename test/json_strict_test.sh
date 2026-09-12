#!/usr/bin/env bash
# J01: malformed JSON bodies receive a JSON-RPC ParseError (id null) instead of
# being silently coerced or crashing; valid bodies still dispatch; hostile
# nesting is bounded.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
def fb(b):
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def run(payload):
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=30)
    return p
def frames(buf):
    out, pos = [], 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        assert sep >= 0, "truncated header"
        ln = int(buf[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        out.append(json.loads(buf[start:start+ln]))
        pos = start+ln
    return out

init = fb(json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}).encode())
shut = fb(json.dumps({"jsonrpc":"2.0","id":9,"method":"shutdown"}).encode())
ex   = fb(json.dumps({"jsonrpc":"2.0","method":"exit"}).encode())

# 1. Each malformed body yields exactly one ParseError with id null.
bads = [b'{bad', b'{"a":}', b'[1,2', b'{"x":1}trailing', b'"unterminated',
        b'{"n":01}', b'{}extra', b'nan', b'{"a":1,}', b'\x00', b'  ', b'-']
payload = [init]
for b in bads:
    payload.append(fb(b))
payload += [shut, ex]
p = run(b"".join(payload))
assert p.returncode == 0, f"exit {p.returncode}"
ms = frames(p.stdout)
errs = [m for m in ms if m.get("error", {}).get("code") == -32700]
assert len(errs) == len(bads), f"expected {len(bads)} ParseErrors, got {len(errs)}: {ms}"
for e in errs:
    assert e.get("id") is None, f"ParseError id must be null: {e}"
    assert "jsonrpc" in e and e["jsonrpc"] == "2.0", e

# 2. Valid JSON still dispatches (initialize + shutdown answered).
assert any(m.get("id") == 1 and "result" in m for m in ms), "initialize must still work"
assert any(m.get("id") == 9 and "result" in m for m in ms), "shutdown must still work"

# 3. Hostile nesting is rejected (bounded), not a crash or hang.
deep = b"[" * 5000 + b"]" * 5000
p = run(init + fb(deep) + shut + ex)
assert p.returncode == 0, f"deep nesting must not crash: rc={p.returncode}"
ms = frames(p.stdout)
assert any(m.get("error", {}).get("code") == -32700 for m in ms), "deep nesting must be a ParseError"

# 4. Valid nested JSON within the bound is accepted.
ok_nested = fb(json.dumps({"jsonrpc":"2.0","id":2,"method":"$/elisa/stats","params":{"a":[1,{"b":[True,None]}],"s":"x"}}).encode())
p = run(init + ok_nested + shut + ex)
ms = frames(p.stdout)
assert any(m.get("id") == 2 and "result" in m for m in ms), f"valid nesting must dispatch: {ms}"

print(f"json strict OK: {len(bads)} malformed bodies -> ParseError(id null), depth bounded")
PY
