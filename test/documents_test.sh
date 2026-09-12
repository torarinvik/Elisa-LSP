#!/usr/bin/env bash
# D01: versioned document lifecycle — stale rejection, close clearing, reopen.
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
def open_doc(uri, text, version=1):
    return frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                  "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":version,"text":text}}})
def change_doc(uri, text, version):
    return frame({"jsonrpc":"2.0","method":"textDocument/didChange",
                  "params":{"textDocument":{"uri":uri,"version":version},"contentChanges":[{"text":text}]}})
def close_doc(uri):
    return frame({"jsonrpc":"2.0","method":"textDocument/didClose",
                  "params":{"textDocument":{"uri":uri}}})
def tokens(i, uri):
    return frame({"jsonrpc":"2.0","id":i,"method":"textDocument/semanticTokens/full",
                  "params":{"textDocument":{"uri":uri}}})
def run(payload):
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=30)
    assert p.returncode == 0, f"exit {p.returncode}: {p.stderr.decode(errors='replace')[:500]}"
    return p.stdout
def parse(buf):
    out = {}
    notifs = []
    pos = 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        ln = int(buf[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(buf[start:start+ln])
        if "id" in msg:
            out[msg["id"]] = msg.get("result")
        else:
            notifs.append(msg)
        pos = start+ln
    return out, notifs

GOOD = "def one() -> void:\n    x: i64 = 1\n"
BAD = "def broken() -> void:\n    z: bool = 3\n"
uri = "file:///doc-version.elisa"

# 1. Stale/equal versions never mutate: open v2, change v1 (stale) + v2 (equal) are ignored.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += open_doc(uri, GOOD, 2)
m += tokens(2, uri)
m += change_doc(uri, BAD, 1)   # stale
m += tokens(3, uri)
m += change_doc(uri, BAD, 2)   # equal
m += tokens(4, uri)
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, _ = parse(run(m))
assert res[3] == res[2], "stale version mutated the document"
assert res[4] == res[2], "equal version mutated the document"

# 2. Newer version applies; close publishes empty diagnostics and invalidates tokens.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += open_doc(uri, GOOD, 1)
m += change_doc(uri, BAD, 2)
m += tokens(2, uri)
m += close_doc(uri)
m += tokens(3, uri)
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, notifs = parse(run(m))
assert res[2] and res[2].get("data"), "updated doc must have tokens"
assert res[3] == {"data": []}, "closed doc must not serve stale tokens"
diags = [n for n in notifs if n.get("method")=="textDocument/publishDiagnostics" and n["params"]["uri"]==uri]
assert diags and diags[-1]["params"]["diagnostics"] == [], "close must publish empty diagnostics"

# 3. Reopen after close works (new generation) even with a reused client version.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += open_doc(uri, GOOD, 1)
m += close_doc(uri)
m += open_doc(uri, GOOD, 1)
m += tokens(2, uri)
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, _ = parse(run(m))
assert res[2] and res[2].get("data"), "reopened doc must serve fresh tokens"

# 4. Empty document is valid: no crash, empty tokens.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += open_doc("file:///empty.elisa", "", 1)
m += tokens(2, "file:///empty.elisa")
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, _ = parse(run(m))
assert res[2] == {"data": []}, f"empty doc must yield empty tokens: {res.get(2)}"

print("documents OK: versions, stale rejection, close clearing, reopen, empty")
PY
