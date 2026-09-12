#!/usr/bin/env bash
# D04: retained flat storage stays bounded. Repeated open/grow/close cycles
# reclaim dead reservations and closed-document content; the private
# `$/elisa/stats` probe reports the buffer so the test can assert a plateau.
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
for cycle in range(120):
    u = URIS[cycle % 3]
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                       "params":{"textDocument":{"uri":u,"languageId":"Elisa","version":1,"text":big(100)}}}))
    # Escalating growth beyond prior capacity forces a fresh reservation each
    # cycle (the abandoned one is dead space until reclamation).
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didChange",
                       "params":{"textDocument":{"uri":u,"version":2},
                                 "contentChanges":[{"text":big(200 + cycle*20)}]}}))
    if cycle % 20 == 19:
        msgs.append(frame({"jsonrpc":"2.0","id":900,"method":"$/elisa/stats","params":{}}))
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didClose",
                       "params":{"textDocument":{"uri":u}}}))
# Reopen one document and prove features still work after compaction.
msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                   "params":{"textDocument":{"uri":URIS[0],"languageId":"Elisa","version":1,
                                             "text":"def ok() -> void:\n    x: i64 = 1\n"}}}))
msgs.append(frame({"jsonrpc":"2.0","id":901,"method":"textDocument/semanticTokens/full",
                   "params":{"textDocument":{"uri":URIS[0]}}}))
msgs.append(frame({"jsonrpc":"2.0","id":902,"method":"textDocument/didClose",
                   "params":{"textDocument":{"uri":URIS[0]}}}))
msgs.append(frame({"jsonrpc":"2.0","id":903,"method":"$/elisa/stats","params":{}}))
msgs.append(frame({"jsonrpc":"2.0","id":9,"method":"shutdown"}))
msgs.append(frame({"jsonrpc":"2.0","method":"exit"}))

p = subprocess.run([srv], input=b"".join(msgs), capture_output=True, timeout=300)
assert p.returncode == 0, f"exit {p.returncode}: {p.stderr.decode(errors='replace')[:400]}"
out, pos, samples, tokens = p.stdout, 0, [], None
while pos < len(out):
    sep = out.find(b"\r\n\r\n", pos)
    ln = int(out[pos:sep].split(b":",1)[1].strip())
    start = sep+4
    msg = json.loads(out[start:start+ln])
    if msg.get("id") == 900:
        samples.append(msg["result"])
    if msg.get("id") == 901:
        tokens = msg["result"]
    if msg.get("id") == 903:
        final = msg["result"]
    pos = start+ln

assert samples, "no stats samples"
for s in samples:
    assert s["documents"] == 3, f"slot count must stay bounded: {s}"
    # Reclamation keeps the buffer within ~2x live bytes plus the compaction floor.
    assert s["storage_bytes"] <= s["live_bytes"] * 2 + 65536, f"storage unbounded: {s}"

# After every document is closed, dead reservations and content are reclaimed:
# only the retained URI slots (plus the compaction floor's slack) remain. The
# point is boundedness — 120 cycles of escalating growth would otherwise leave
# hundreds of KB resident.
assert final["open"] == 0, final
assert final["documents"] == 3, final
assert final["storage_bytes"] < 4096, f"closed storage should be tiny after 120 cycles: {final}"

# Correctness survives compaction.
assert tokens and tokens.get("data"), f"features broke after reclamation: {tokens}"

print(f"storage OK: plateaued, reclaimed to {final['storage_bytes']}B after close, features intact")
PY
