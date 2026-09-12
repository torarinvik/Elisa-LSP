#!/usr/bin/env bash
# D04: retained storage and the slot table stay bounded. Repeated
# open/grow/close cycles reclaim dead reservations and content; URI churn reuses
# freed slots instead of growing the table. The private `$/elisa/stats` probe
# reports the buffer so the test can assert a plateau.
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
def big(k):
    return "def f() -> void:\n" + ("    # " + "z"*80 + "\n")*k

URIS = ["file:///a.elisa", "file:///b.elisa", "file:///c.elisa"]
msgs = [frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})]

# Phase 1: escalating growth forces a fresh reservation each cycle; the
# abandoned one is dead space until reclamation.
for cycle in range(120):
    u = URIS[cycle % 3]
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                       "params":{"textDocument":{"uri":u,"languageId":"Elisa","version":1,"text":big(100)}}}))
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didChange",
                       "params":{"textDocument":{"uri":u,"version":2},
                                 "contentChanges":[{"text":big(200 + cycle*20)}]}}))
    if cycle % 20 == 19:
        msgs.append(frame({"jsonrpc":"2.0","id":900,"method":"$/elisa/stats","params":{}}))
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didClose",
                       "params":{"textDocument":{"uri":u}}}))
msgs.append(frame({"jsonrpc":"2.0","id":903,"method":"$/elisa/stats","params":{}}))

# Phase 2: URI churn — 300 distinct files opened once each, closed, with a
# stats sample after each open.
for i in range(300):
    u = f"file:///churn-{i}.elisa"
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                       "params":{"textDocument":{"uri":u,"languageId":"Elisa","version":1,
                                                 "text":f"def g{i}() -> void:\n    pass\n"}}}))
    msgs.append(frame({"jsonrpc":"2.0","id":904,"method":"$/elisa/stats","params":{}}))
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didClose",
                       "params":{"textDocument":{"uri":u}}}))
# Reopen an early URI: chain reuse must not corrupt lookup.
msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                   "params":{"textDocument":{"uri":"file:///churn-0.elisa","languageId":"Elisa","version":1,
                                             "text":"def z() -> void:\n    pass\n"}}}))
msgs.append(frame({"jsonrpc":"2.0","id":905,"method":"textDocument/semanticTokens/full",
                   "params":{"textDocument":{"uri":"file:///churn-0.elisa"}}}))
msgs.append(frame({"jsonrpc":"2.0","id":906,"method":"$/elisa/stats","params":{}}))
msgs.append(frame({"jsonrpc":"2.0","id":9,"method":"shutdown"}))
msgs.append(frame({"jsonrpc":"2.0","method":"exit"}))

p = subprocess.run([srv], input=b"".join(msgs), capture_output=True, timeout=300)
assert p.returncode == 0, f"exit {p.returncode}: {p.stderr.decode(errors='replace')[:400]}"
out, pos = p.stdout, 0
growth, churn, tokens, final = [], [], None, None
while pos < len(out):
    sep = out.find(b"\r\n\r\n", pos)
    ln = int(out[pos:sep].split(b":",1)[1].strip())
    start = sep+4
    msg = json.loads(out[start:start+ln])
    if msg.get("id") == 900: growth.append(msg["result"])
    if msg.get("id") == 904: churn.append(msg["result"])
    if msg.get("id") == 905: tokens = msg["result"]
    if msg.get("id") == 903: final = msg["result"]
    pos = start+ln

assert growth, "no growth-phase samples"
for s in growth:
    assert s["documents"] <= 4, f"slot count must stay bounded: {s}"
    assert s["storage_bytes"] <= s["live_bytes"] * 2 + 65536, f"storage unbounded: {s}"

# After every document is closed, dead reservations and content are reclaimed.
assert final["open"] == 0, final
assert final["documents"] <= 4, final
assert final["storage_bytes"] < 4096, f"closed storage should be tiny: {final}"

# URI churn must reuse freed slots, not grow the table.
assert churn, "no churn samples"
churn_peak = max(c["documents"] for c in churn)
assert churn_peak <= 4, f"URI churn grew the slot table: peak {churn_peak}"

# Correctness survives compaction and slot reuse.
assert tokens and tokens.get("data"), f"reopened URI after churn broke: {tokens}"

print(f"storage OK: reclaimed to {final['storage_bytes']}B, churn peak {churn_peak} slots, features intact")
PY
