#!/usr/bin/env bash
# D03: URI identity — percent-decoding, scheme case, localhost authority,
# fragment stripping, malformed escapes, untitled/remote opacity, case policy.
# Responses echo the client's spelling; lookup uses the canonical form.
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
def open_doc(uri, text, version=1):
    return frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                  "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":version,"text":text}}})
def tokens(i, uri):
    return frame({"jsonrpc":"2.0","id":i,"method":"textDocument/semanticTokens/full",
                  "params":{"textDocument":{"uri":uri}}})

GOOD = "def one() -> void:\n    x: i64 = 1\n"

# 1. Equivalent encodings alias; spelling echoed back; distinct stays distinct.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += open_doc("file:///a%20b.elisa", GOOD)
m += tokens(2, "file:///a b.elisa")
m += tokens(3, "FILE:///a%20b.elisa")
m += tokens(4, "file://localhost/a%20b.elisa")
m += tokens(5, "file:///a%20b.elisa#frag")
m += tokens(6, "file:///other.elisa")
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, notifs = parse(run(m))
for i in (2, 3, 4, 5):
    assert res[i] and res[i].get("data"), f"alias form {i} must resolve: {res.get(i)}"
assert res[6] == {"data": []}, "unrelated URI must stay empty"
diags = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics"]
assert diags and diags[0]["params"]["uri"] == "file:///a%20b.elisa", \
    f"responses echo incoming spelling: {diags[0]['params']['uri'] if diags else None}"

# 2. %41 == 'A'; malformed/trailing % stays usable and distinct; close-by-alias works.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += open_doc("file:///x%41y.elisa", GOOD)
m += tokens(2, "file:///xAy.elisa")
m += open_doc("file:///we%2Fird.elisa", GOOD, 1)
m += tokens(3, "file:///we%ZZird.elisa")
m += open_doc("file:///trail%.elisa", GOOD, 1)
m += tokens(4, "file:///trail%.elisa")
m += frame({"jsonrpc":"2.0","method":"textDocument/didClose",
            "params":{"textDocument":{"uri":"file:///x%41y.elisa"}}})
m += tokens(5, "file:///xAy.elisa")
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, notifs = parse(run(m))
assert res[2] and res[2].get("data"), "%41 must equal A"
assert res[3] == {"data": []}, "%2F must not alias %ZZ"
assert res[4] and res[4].get("data"), "trailing % must not break the document"
assert res[5] == {"data": []}, "close-by-alias must invalidate"
clears = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics"
          and n["params"]["uri"] == "file:///x%41y.elisa" and n["params"]["diagnostics"] == []]
assert clears, "close must publish the empty clear"

# 3. Case-distinct paths stay distinct (no lowercasing); untitled + non-ASCII
#    percent forms + unknown schemes behave as opaque overlays.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += open_doc("file:///Case.elisa", GOOD)
m += tokens(2, "file:///case.elisa")
m += open_doc("untitled:Untitled-1", GOOD, 1)
m += tokens(3, "untitled:Untitled-1")
m += open_doc("file:///caf%C3%A9.elisa", GOOD, 1)
m += tokens(4, "file:///caf%C3%A9.elisa")
m += open_doc("https://example.com/x.elisa", GOOD, 1)
m += tokens(5, "https://example.com/x.elisa")
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, _ = parse(run(m))
assert res[2] == {"data": []}, "differing case must not alias"
for i in (3, 4, 5):
    assert res[i] and res[i].get("data"), f"opaque form {i} must work: {res.get(i)}"

print("uri OK: equivalence, spelling echo, malformed safety, case policy, opaque schemes")
PY
