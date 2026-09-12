#!/usr/bin/env bash
# didOpen diagnostics (valid JSON fixtures via python json.dumps — B02):
#   1. a clean document -> empty publishDiagnostics notification.
#   2. a document with an error -> publishDiagnostics with >=1 diagnostic (no crash).
#
# Case 2 used to abort the server with an arena "assert failed" (fixed in Elisa-core
# 742c2b4b — see the comment atop src/diagnostics.elisa).
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

run_case() {
  python3 - "$SRV" "$1" "$2" <<'PY'
import json, subprocess, sys
_, srv, uri, text = sys.argv
def frame(o):
    b = json.dumps(o).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":text}}})
m += frame({"jsonrpc":"2.0","method":"exit"})
sys.stdout.write(subprocess.run([srv], input=m, capture_output=True, timeout=30).stdout.decode(errors="replace"))
PY
}

fail=0

# ---- case 1: clean document -> empty diagnostics ----
OUT="$(run_case "file:///t.elisa" 'def main() -> int:
    return 0
')"
echo "---- case 1: clean document ----"
printf '%s' "$OUT" | cat -v
echo
grep -q '"method":"textDocument/publishDiagnostics"' <<<"$OUT" || { echo "FAIL: no publishDiagnostics notification"; fail=1; }
grep -q '"uri":"file:///t.elisa"' <<<"$OUT" || { echo "FAIL: uri not echoed"; fail=1; }
grep -q '"diagnostics":\[\]' <<<"$OUT" || { echo "FAIL: expected empty diagnostics for a clean document"; fail=1; }

# ---- case 2: document with an error -> >=1 diagnostic, no crash ----
OUT2="$(run_case "file:///bad.elisa" 'def main() -> int:
    return nope_undefined
')"
echo "---- case 2: document with an error ----"
printf '%s' "$OUT2" | cat -v
echo
grep -q '"uri":"file:///bad.elisa"' <<<"$OUT2" || { echo "FAIL: uri not echoed for error doc"; fail=1; }
grep -q '"severity":1' <<<"$OUT2" || { echo "FAIL: expected >=1 error-severity diagnostic"; fail=1; }
grep -q '"diagnostics":\[\]' <<<"$OUT2" && { echo "FAIL: expected a non-empty diagnostics array"; fail=1; }
grep -qi 'assert failed' <<<"$OUT2" && { echo "FAIL: server aborted with an arena assert (regressed)"; fail=1; }

# ---- case 3: document with a syntax error -> parser diagnostic surfaced ----
# Parse errors come from the frontend (Ast::File.errors, folded into the diagnostic
# stream by Semantic::check) — the LSP must surface them, not just semantic findings.
OUT3="$(run_case "file:///syn.elisa" 'def main( -> int:
    return 0
')"
echo "---- case 3: document with a syntax error ----"
printf '%s' "$OUT3" | cat -v
echo
grep -q '"uri":"file:///syn.elisa"' <<<"$OUT3" || { echo "FAIL: uri not echoed for syntax-error doc"; fail=1; }
grep -q '"severity":1' <<<"$OUT3" || { echo "FAIL: expected >=1 error-severity diagnostic"; fail=1; }
grep -q '"diagnostics":\[\]' <<<"$OUT3" && { echo "FAIL: expected a non-empty diagnostics array for a syntax error"; fail=1; }
grep -qE 'expected a token|unexpected token|expected a declaration|expected an expression' <<<"$OUT3" || { echo "FAIL: expected a parser (syntax) diagnostic message"; fail=1; }
grep -qi 'assert failed' <<<"$OUT3" && { echo "FAIL: server aborted"; fail=1; }

echo "---- result ----"
[[ $fail -eq 0 ]] && echo "diagnostics OK" || exit 1
