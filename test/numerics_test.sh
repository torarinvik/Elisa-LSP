#!/usr/bin/env bash
# J02 strict protocol numerics: fractional, overflowing, or wrong-typed
# version/position fields are rejected, never coerced (1.5 must not become 15).
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
    return p.stdout
def parse(buf):
    res, notifs = {}, []
    pos = 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        ln = int(buf[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(buf[start:start+ln])
        if "id" in msg: res[msg["id"]] = msg.get("result")
        else: notifs.append(msg)
        pos = start+ln
    return res, notifs

GOOD = "def one() -> void:\n    x: i64 = 1\n"
BAD = "def broken() -> void:\n    z: bool = 3\n"
uri = "file:///num.elisa"

# 1. Malformed versions never mutate: fractional, huge, and string versions
#    are all dropped while the good text stays authoritative.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":GOOD}}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
# Hand-built frames: json.dumps cannot emit fractional versions.
for bad_version in ('1.5', '99999999999999999999999', '"2"'):
    body = ('{"jsonrpc":"2.0","method":"textDocument/didChange",'
            '"params":{"textDocument":{"uri":"%s","version":%s},'
            '"contentChanges":[{"text":%s}]}}' % (uri, bad_version, json.dumps(BAD))).encode()
    m += b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
m += frame({"jsonrpc":"2.0","id":3,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, _ = parse(run(m))
assert res[3] == res[2] and res[2].get("data"), f"malformed versions mutated: {res.get(3)} vs {res.get(2)}"

# 2. A later valid version still applies (no poisoning from the rejects above).
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":GOOD}}})
body = ('{"jsonrpc":"2.0","method":"textDocument/didChange",'
        '"params":{"textDocument":{"uri":"%s","version":1.5},'
        '"contentChanges":[{"text":%s}]}}' % (uri, json.dumps(BAD))).encode()
m += b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
m += frame({"jsonrpc":"2.0","method":"textDocument/didChange",
            "params":{"textDocument":{"uri":uri,"version":2},"contentChanges":[{"text":BAD}]}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, notifs = parse(run(m))
assert res[2] and res[2].get("data"), "valid version after rejects must apply"
diags = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["uri"] == uri]
assert diags and len(diags[-1]["params"]["diagnostics"]) > 0, "BAD text must surface diagnostics"

# 3. Non-integer hover lines yield null, never a coerced line.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":GOOD}}})
for i, bad_line in enumerate(('2.5', '"1"', '99999999999999999999999')):
    body = ('{"jsonrpc":"2.0","id":%d,"method":"textDocument/hover",'
            '"params":{"textDocument":{"uri":"%s"},"position":{"line":%s,"character":0}}}' % (10+i, uri, bad_line)).encode()
    m += b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, _ = parse(run(m))
for i in (10, 11, 12):
    assert res[i] is None, f"non-integer line must hover null: id {i} -> {res.get(i)}"

print("numerics OK: fractional/overflowing/wrong-typed fields rejected, never coerced")
PY
