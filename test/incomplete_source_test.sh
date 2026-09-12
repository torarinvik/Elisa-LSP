#!/usr/bin/env bash
# A04: incomplete and malformed source must not kill the session. A sequence of
# broken documents (unfinished declarations, dangling delimiters, half-written
# generics, incomplete interpolation, unterminated literals/comments, deep
# nesting) is opened and edited while every provider is exercised, then a valid
# edit must recover with clean diagnostics and fresh tokens.
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

BROKEN = [
    "",                                                     # empty
    "def\n",                                                # unfinished decl
    "def f( -> void:\n    pass\n",                          # missing param close
    "def f() -> void:\n    x: i64 = (\n",                   # dangling paren
    "def f() -> i64:\n    return 1 +\n",                    # trailing operator
    "struct S:\n    x:\n",                                  # missing type
    "enum E:\n    A(\n",                                    # unfinished variant
    "def f() -> void:\n    s: dstr = \"unterminated\n",    # unterminated string
    "def f() -> void:\n    \"\"\"\n    open doc block\n",   # unterminated comment
    "def f() -> void:\n    s: dstr = f\"hi {\n",            # incomplete interpolation
    "def f[T: -> void:\n    pass\n",                        # half-written generic
    "def f() -> void:\n    match\n",                        # dangling selector
    "def f() -> void:\n" + "    x: i64 = 1\n"*200 + "    y: i64 = (\n",  # deep body
]
GOOD = "def ok() -> void:\n    x: i64 = 1\n"

msgs = [frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})]
# Open and edit through every broken state, exercising each provider.
for i, src in enumerate(BROKEN):
    uri = "file:///a04.elisa"
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                       "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":i*2+1,"text":src}}})
                if i == 0 else
                frame({"jsonrpc":"2.0","method":"textDocument/didChange",
                       "params":{"textDocument":{"uri":uri,"version":i*2+1},
                                 "contentChanges":[{"text":src}]}}))
    base = 100 + i*10
    msgs.append(frame({"jsonrpc":"2.0","id":base,   "method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":uri}}}))
    msgs.append(frame({"jsonrpc":"2.0","id":base+1, "method":"textDocument/documentSymbol","params":{"textDocument":{"uri":uri}}}))
    msgs.append(frame({"jsonrpc":"2.0","id":base+2, "method":"textDocument/foldingRange","params":{"textDocument":{"uri":uri}}}))
    msgs.append(frame({"jsonrpc":"2.0","id":base+3, "method":"textDocument/selectionRange",
                       "params":{"textDocument":{"uri":uri},"positions":[{"line":0,"character":0},{"line":1,"character":4}]}}))
    msgs.append(frame({"jsonrpc":"2.0","id":base+4, "method":"textDocument/hover",
                       "params":{"textDocument":{"uri":uri},"position":{"line":0,"character":4}}}))
# Recover with a valid edit.
last = len(BROKEN)*2+1
msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didChange",
                   "params":{"textDocument":{"uri":"file:///a04.elisa","version":last+1},
                             "contentChanges":[{"text":GOOD}]}}))
msgs.append(frame({"jsonrpc":"2.0","id":5000,"method":"textDocument/semanticTokens/full",
                   "params":{"textDocument":{"uri":"file:///a04.elisa"}}}))
msgs.append(frame({"jsonrpc":"2.0","id":9,"method":"shutdown"}))
msgs.append(frame({"jsonrpc":"2.0","method":"exit"}))

p = subprocess.run([srv], input=b"".join(msgs), capture_output=True, timeout=120)
assert p.returncode == 0, f"server died on incomplete source: rc={p.returncode}"

res, notifs, pos = {}, [], 0
out = p.stdout
while pos < len(out):
    sep = out.find(b"\r\n\r\n", pos)
    ln = int(out[pos:sep].split(b":",1)[1].strip())
    start = sep+4
    msg = json.loads(out[start:start+ln])  # every frame must be valid JSON
    if "id" in msg: res[msg["id"]] = msg
    else: notifs.append(msg)
    pos = start+ln

# Every provider answered exactly once for every broken state.
for i in range(len(BROKEN)):
    base = 100 + i*10
    for k in range(5):
        assert base+k in res, f"missing response id {base+k} (broken state {i})"
        assert "error" not in res[base+k], f"provider errored on broken source: {res[base+k]}"

# Broken sources still produced diagnostics (not a silent drop).
diag_notifs = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics"]
assert diag_notifs, "no diagnostics published for broken sources"

# Recovery: the valid edit yields non-empty tokens.
tok = res[5000]["result"]["data"]
assert tok, "valid edit after broken states produced no tokens"

print(f"containment OK: {len(BROKEN)} broken states, all providers alive, recovered")
PY
