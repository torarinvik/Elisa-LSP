#!/usr/bin/env bash
# Q02: `$/cancelRequest` on the synchronous server is safely ignored because
# no request remains in flight when the notification is dispatched. In
# particular, a cancel for an unknown ID must never poison a later request
# that reuses that typed ID.
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
def run(payload):
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=30)
    assert p.returncode == 0, f"exit {p.returncode}"
    out, pos, msgs = p.stdout, 0, []
    while pos < len(out):
        sep = out.find(b"\r\n\r\n", pos)
        ln = int(out[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msgs.append(json.loads(out[start:start+ln]))
        pos = start+ln
    return msgs
def by_id(msgs):
    return {(type(m["id"]).__name__, m["id"]): m for m in msgs if "id" in m}

HOVER = lambda i: {"jsonrpc":"2.0","id":i,"method":"textDocument/hover",
                   "params":{"textDocument":{"uri":"file:///x.elisa"},"position":{"line":0,"character":0}}}
CANCEL = lambda i: {"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":i}}

msgs = [frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}})]
# 1. Cancel numeric 5 before its request; the future request still runs.
msgs += [frame(CANCEL(5)), frame(HOVER(5))]
# 2. A cancellation cannot affect a future request with a different typed ID.
msgs += [frame({"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":7}}), frame(HOVER("7"))]
# 3. Reversed typed IDs also remain harmless.
msgs += [frame(CANCEL("8")), frame(HOVER(8))]
# 4. Unrelated request runs.
msgs += [frame(HOVER(9))]
# 5. Cancel an id that never arrives (harmless), plus many cancels.
for i in range(100, 200):
    msgs.append(frame(CANCEL(i)))
msgs += [frame(HOVER(10))]
msgs += [frame({"jsonrpc":"2.0","id":99,"method":"shutdown"}), frame({"jsonrpc":"2.0","method":"exit"})]

res = by_id(run(b"".join(msgs)))
for key in (("int", 5), ("str", "7"), ("int", 8), ("int", 9), ("int", 10)):
    assert res[key].get("result") is None and "error" not in res[key], \
        f"cancel must not affect future or unrelated request {key}: {res.get(key)}"
assert res[("int", 99)].get("result") is None, "shutdown must complete"

print("cancellation OK: stale and unknown cancellation IDs do not affect future requests")
PY
