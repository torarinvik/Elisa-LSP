#!/usr/bin/env bash
# didOpen on a clean document should produce an empty publishDiagnostics notification.
#
# NOTE: a document with >=1 diagnostic currently crashes the server (known bug, see the
# comment atop src/diagnostics.elisa) — not covered here until that's root-caused.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

frame() { local b="$1"; printf 'Content-Length: %d\r\n\r\n%s' "${#b}" "$b"; }

SRC=$'def main() -> int:\n    return 0\n'

req() {
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  frame "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///t.elisa\",\"text\":\"$SRC\"}}}"
  frame '{"jsonrpc":"2.0","method":"exit"}'
}

OUT="$(req | "$SRV")"
printf '%s' "$OUT" | cat -v
echo
echo "---- checks ----"
fail=0
grep -q '"method":"textDocument/publishDiagnostics"' <<<"$OUT" || { echo "FAIL: no publishDiagnostics notification"; fail=1; }
grep -q '"uri":"file:///t.elisa"' <<<"$OUT" || { echo "FAIL: uri not echoed"; fail=1; }
grep -q '"diagnostics":\[\]' <<<"$OUT" || { echo "FAIL: expected empty diagnostics for a clean document"; fail=1; }
[[ $fail -eq 0 ]] && echo "diagnostics OK" || exit 1
