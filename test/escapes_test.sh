#!/usr/bin/env bash
# JSON string-escape decoding: real LSP clients send the document with every
# newline/quote escaped per the JSON spec (`\n`, `\"`, ...). The server must
# DECODE those before handing the text to the frontend — regression for the
# bug where raw `\n` sequences reached the parser (error storms on small docs,
# silent extraction failure on large ones), found wiring up the JetBrains
# client. Frames are built with python3 (json.dumps) so escaping is exactly
# what a spec-compliant client produces, unlike the $'...' shell heredocs in
# the other tests (which embed raw newlines).
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

OUT="$(python3 - "$SRV" <<'PY'
import json, subprocess, sys
def frame(o):
    b = json.dumps(o)
    return f"Content-Length: {len(b)}\r\n\r\n{b}".encode()
m  = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{
    "uri":"file:///esc.elisa","languageId":"Elisa","version":1,
    "text":"def ok() -> void:\n    pass\n"}}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didChange","params":{
    "textDocument":{"uri":"file:///esc.elisa","version":2},
    "contentChanges":[{"text":"def demo() -> void:\n    x: bool = 5\n    s: cstr = \"quoted \\\\ text\"\n    _ = s\n    _ = x\n"}]}})
m += frame({"jsonrpc":"2.0","method":"exit"})
sys.stdout.write(subprocess.run([sys.argv[1]], input=m, capture_output=True, timeout=30).stdout.decode(errors="replace"))
PY
)"

fail=0
# didOpen of the clean doc must publish EMPTY diagnostics (escapes decoded, no
# parse-error storm).
grep -q '"uri":"file:///esc.elisa","diagnostics":\[\]' <<<"$OUT" || { echo "FAIL: clean didOpen not empty (escape decoding broken?)"; fail=1; }
# didChange must yield exactly the type mismatch on 0-based line 1 (and no
# syntax errors).
grep -q "variable 'x' expects bool, got int" <<<"$OUT" || { echo "FAIL: TypeMismatch missing after didChange"; fail=1; }
grep -q '"start":{"line":1,' <<<"$OUT" || { echo "FAIL: diagnostic not on line 1"; fail=1; }
grep -q 'expected a' <<<"$OUT" && { echo "FAIL: syntax-error storm (escapes reached the parser)"; fail=1; }

[[ $fail -eq 0 ]] && echo "escapes OK" || exit 1
