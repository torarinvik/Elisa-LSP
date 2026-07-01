#!/usr/bin/env bash
# didOpen diagnostics:
#   1. a clean document -> empty publishDiagnostics notification.
#   2. a document with an error -> publishDiagnostics with >=1 diagnostic (no crash).
#
# Case 2 used to abort the server with an arena "assert failed" (fixed in Elisa-core
# 742c2b4b — see the comment atop src/diagnostics.elisa).
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

frame() { local b="$1"; printf 'Content-Length: %d\r\n\r\n%s' "${#b}" "$b"; }

fail=0

# ---- case 1: clean document -> empty diagnostics ----
CLEAN=$'def main() -> int:\n    return 0\n'
clean_req() {
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  frame "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.elisa\",\"text\":\"$CLEAN\"}}}"
  frame '{"jsonrpc":"2.0","method":"exit"}'
}
OUT="$(clean_req | "$SRV")"
echo "---- case 1: clean document ----"
printf '%s' "$OUT" | cat -v
echo
grep -q '"method":"textDocument/publishDiagnostics"' <<<"$OUT" || { echo "FAIL: no publishDiagnostics notification"; fail=1; }
grep -q '"uri":"file:///t.elisa"' <<<"$OUT" || { echo "FAIL: uri not echoed"; fail=1; }
grep -q '"diagnostics":\[\]' <<<"$OUT" || { echo "FAIL: expected empty diagnostics for a clean document"; fail=1; }

# ---- case 2: document with an error -> >=1 diagnostic, no crash ----
BAD='def main() -> int:\n    return nope_undefined\n'
bad_req() {
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  frame "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///bad.elisa\",\"text\":\"$BAD\"}}}"
  frame '{"jsonrpc":"2.0","method":"exit"}'
}
OUT2="$(bad_req | "$SRV")"
echo "---- case 2: document with an error ----"
printf '%s' "$OUT2" | cat -v
echo
grep -q '"uri":"file:///bad.elisa"' <<<"$OUT2" || { echo "FAIL: uri not echoed for error doc"; fail=1; }
grep -q '"severity":1' <<<"$OUT2" || { echo "FAIL: expected >=1 error-severity diagnostic"; fail=1; }
grep -q '"diagnostics":\[\]' <<<"$OUT2" && { echo "FAIL: expected a non-empty diagnostics array"; fail=1; }
grep -qi 'assert failed' <<<"$OUT2" && { echo "FAIL: server aborted with an arena assert (regressed)"; fail=1; }

echo "---- result ----"
[[ $fail -eq 0 ]] && echo "diagnostics OK" || exit 1
