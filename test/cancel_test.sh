#!/usr/bin/env bash
# Q02: `$/cancelRequest` handling — a pipelined cancellation completes the
# matching request once with RequestCancelled; numeric and string ids stay
# distinct; uncancelled requests run normally; unknown ids are harmless.
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

msgs = [frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})]
# 1. Cancel numeric 5 before its request.
msgs += [frame(CANCEL(5)), frame(HOVER(5))]
# 2. Typed distinction: cancel numeric 7, request string "7" must run.
msgs += [frame({"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":7}}), frame(HOVER("7"))]
# 3. Cancel string "8" before request 8 (numeric) — must NOT cancel it.
msgs += [frame(CANCEL("8")), frame(HOVER(8))]
# 4. Unrelated request runs.
msgs += [frame(HOVER(9))]
# 5. Cancel an id that never arrives (harmless), plus many cancels.
for i in range(100, 200):
    msgs.append(frame(CANCEL(i)))
msgs += [frame(HOVER(10))]
msgs += [frame({"jsonrpc":"2.0","id":99,"method":"shutdown"}), frame({"jsonrpc":"2.0","method":"exit"})]

res = by_id(run(b"".join(msgs)))
assert res[("int", 5)].get("error", {}).get("code") == -32800, f"numeric 5 must be cancelled: {res.get(('int',5))}"
assert res[("str", "7")].get("result") is None and "error" not in res[("str","7")], \
    f"string '7' must not be cancelled by numeric 7: {res.get(('str','7'))}"
assert res[("int", 8)].get("result") is None and "error" not in res[("int", 8)], \
    f"numeric 8 must not be cancelled by string '8': {res.get(('int',8))}"
assert res[("int", 9)].get("result") is None and "error" not in res[("int", 9)], "unrelated request must run"
assert res[("int", 10)].get("result") is None and "error" not in res[("int", 10)], "post-flood request must run"
assert res[("int", 99)].get("result") is None, "shutdown must complete"

print("cancellation OK: pipelined cancel honored, typed ids distinct, no leakage")
PY
