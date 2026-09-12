#!/usr/bin/env bash
# D02: full-sync correctness — multi-change application order, CRLF/trailing
# fidelity, ranged-change rejection, empty/malformed change safety.
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
    assert p.returncode == 0, f"exit {p.returncode}: {p.stderr.decode(errors='replace')[:500]}"
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
uri = "file:///sync.elisa"

# 1. Multi-change full replacements apply in order: last entry wins.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":GOOD}}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didChange",
            "params":{"textDocument":{"uri":uri,"version":2},
                      "contentChanges":[{"text":BAD},{"text":GOOD}]}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, notifs = parse(run(m))
assert res[2] and res[2].get("data"), "last full replacement must win"
diags = [n for n in notifs if n.get("method")=="textDocument/publishDiagnostics" and n["params"]["uri"]==uri]
assert diags and diags[-1]["params"]["diagnostics"] == [], f"GOOD tail must be clean: {diags[-1] if diags else None}"

# 2. Ranged change while only full sync is advertised: rejected, no mutation.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":GOOD}}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didChange",
            "params":{"textDocument":{"uri":uri,"version":2},
                      "contentChanges":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"text":BAD}]}})
m += frame({"jsonrpc":"2.0","id":3,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, _ = parse(run(m))
assert res[3] == res[2] and res[2].get("data"), "ranged change must not mutate full-sync document"

# 3. CRLF fidelity: bytes preserved exactly (the frontend itself reports the
# CR as a token, which proves the \r reached analysis intact, not normalized).
crlf_doc = "def cr() -> void:\r\n    pass\r\n"
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":crlf_doc}}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, notifs = parse(run(m))
assert res[2] and res[2].get("data"), "CRLF doc must tokenize"
diags = [n for n in notifs if n.get("method")=="textDocument/publishDiagnostics" and n["params"]["uri"]==uri]
assert diags, "CRLF doc must publish diagnostics"
found_cr = any("\\r" in json.dumps(d) for d in diags[-1]["params"]["diagnostics"])
assert found_cr, f"CR bytes must survive to analysis intact: {diags[-1]}"
for d in diags[-1]["params"]["diagnostics"]:
    assert d["range"]["start"]["character"] != 999 and d["range"]["end"]["character"] != 999

# 4. Empty change list / missing text: malformed, no mutation, no crash.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":GOOD}}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didChange",
            "params":{"textDocument":{"uri":uri,"version":2},"contentChanges":[]}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didChange",
            "params":{"textDocument":{"uri":uri,"version":3},"contentChanges":[{}]}})
m += frame({"jsonrpc":"2.0","id":3,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
res, _ = parse(run(m))
assert res[3] == res[2], "malformed changes must not mutate"

print("sync OK: order, ranged rejection, CRLF fidelity, malformed safety")
PY
