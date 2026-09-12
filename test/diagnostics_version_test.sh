#!/usr/bin/env bash
# G02: versioned publication lifecycle — versions on pushes, identical-repeat
# suppression, error clearing on clean edits, bounded output with a visible cap.
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
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=60)
    assert p.returncode == 0, f"exit {p.returncode}"
    return p.stdout
def pubs(buf, uri=None):
    out = []
    pos = 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        ln = int(buf[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(buf[start:start+ln])
        if msg.get("method") == "textDocument/publishDiagnostics" and (uri is None or msg["params"]["uri"] == uri):
            out.append(msg["params"])
        pos = start+ln
    return out

GOOD = "def one() -> void:\n    x: i64 = 1\n"
BAD = "def broken() -> void:\n    z: bool = 3\n"

# 1. Versions ride on pushes; duplicate didOpen is suppressed; clean edit
#    after an error clears it with a new version.
uri = "file:///ver.elisa"
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":BAD}}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":BAD}}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didChange",
            "params":{"textDocument":{"uri":uri,"version":2},"contentChanges":[{"text":GOOD}]}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
ps = pubs(run(m), uri)
assert len(ps) == 2, f"duplicate open must suppress repeat publish: {[(p.get('version'),len(p['diagnostics'])) for p in ps]}"
assert ps[0].get("version") == 1 and len(ps[0]["diagnostics"]) == 1, f"v1 must carry the error: {ps[0]}"
assert ps[1].get("version") == 2 and ps[1]["diagnostics"] == [], f"clean v2 must clear: {ps[1]}"

# 2. Flood control: 300 findings cap at 200 with a visible hint, no dupes.
big_lines = ["def f() -> void:"] + [f"    _ = undef{n}" for n in range(300)]
big_text = "\n".join(big_lines) + "\n"
curi = "file:///cap.elisa"
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":curi,"languageId":"Elisa","version":1,"text":big_text}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
ps = pubs(run(m), curi)
assert len(ps) == 1
ds = ps[0]["diagnostics"]
assert ps[0].get("version") == 1
assert len(ds) == 201, f"expected 200 + hint, got {len(ds)}"
assert ds[-1].get("severity") == 4 and "omitted" in ds[-1].get("message",""), f"hint must be visible: {ds[-1]}"
keys = [json.dumps(d, sort_keys=True) for d in ds]
assert len(set(keys)) == len(keys), "published findings must not contain duplicates"
for d in ds:
    assert d["range"]["start"]["character"] != 999 and d["range"]["end"]["character"] != 999

print("versioned diagnostics OK: versions, suppression, clearing, cap+hint, no dupes")
PY
