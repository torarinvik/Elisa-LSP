#!/usr/bin/env bash
# P01/P02: envelope validation + lifecycle state machine.
# - Every valid request gets exactly one response; notifications get none.
# - Unknown methods with id -> MethodNotFound; without id -> silence.
# - Pre-initialize non-init requests -> ServerNotInitialized.
# - Duplicate initialize -> InvalidRequest; shutdown idempotent; exit codes 0/1.
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
def run(msgs, timeout=15):
    payload = b"".join(msgs) if isinstance(msgs, list) else msgs
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=timeout)
    return p

def frames(buf):
    out = []
    pos = 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        assert sep >= 0, "truncated header"
        ln = int(buf[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        out.append(json.loads(buf[start:start+ln]))
        pos = start+ln
    return out

# 1. Unknown request after init -> exactly one MethodNotFound; unknown notification -> silence.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","id":2,"method":"nosuch/method","params":{}})
m += frame({"jsonrpc":"2.0","method":"nosuch/notify","params":{}})
m += frame({"jsonrpc":"2.0","id":3,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 0, f"orderly exit must be 0, got {p.returncode}"
msgs = frames(p.stdout)
by_id = {x["id"]: x for x in msgs if "id" in x}
assert by_id[2].get("error",{}).get("code") == -32601, f"unknown request must be MethodNotFound: {by_id.get(2)}"
assert 3 in by_id and "result" in by_id[3], "shutdown must respond"
assert not any(x.get("method")=="nosuch/notify" for x in msgs), "notifications must not produce responses"
assert len([x for x in msgs if x.get("id")==2]) == 1, "exactly-once for unknown request"

# 2. Pre-initialize tokens request -> ServerNotInitialized, no crash.
m = frame({"jsonrpc":"2.0","id":1,"method":"textDocument/semanticTokens/full",
           "params":{"textDocument":{"uri":"file:///x.elisa"}}})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 1, f"exit-without-shutdown must be 1, got {p.returncode}"
msgs = frames(p.stdout)
assert msgs[0].get("error",{}).get("code") == -32002, f"pre-init must be ServerNotInitialized: {msgs}"

# 3. Duplicate initialize -> InvalidRequest, second response still exactly-once.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","id":2,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","id":3,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 0
by_id = {x["id"]: x for x in frames(p.stdout) if "id" in x}
assert "result" in by_id[1] and by_id[2].get("error",{}).get("code") == -32600, f"duplicate init: {by_id}"

# 4. Post-shutdown normal request -> InvalidRequest, shutdown idempotent.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","id":2,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","id":3,"method":"textDocument/hover",
            "params":{"textDocument":{"uri":"file:///x.elisa"},"position":{"line":0,"character":0}}})
m += frame({"jsonrpc":"2.0","id":4,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 0
by_id = {x["id"]: x for x in frames(p.stdout) if "id" in x}
assert by_id[3].get("error",{}).get("code") == -32600, f"post-shutdown must be InvalidRequest: {by_id.get(3)}"
assert "result" in by_id[4], "duplicate shutdown must still respond"

# 5. String vs numeric IDs are distinct keys (typed IDs).
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","id":"1","method":"nosuch/method","params":{}})
m += frame({"jsonrpc":"2.0","id":1,"method":"nosuch/other","params":{}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
by_id = {(type(x["id"]).__name__, x["id"]): x for x in frames(p.stdout) if "id" in x}
assert ("int",1) in by_id and ("str","1") in by_id, f"typed IDs not distinguished: {list(by_id)}"

print("protocol OK: envelope, lifecycle, exit codes, typed IDs")
PY
