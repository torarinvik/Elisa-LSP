#!/usr/bin/env bash
# Pipe a framed initialize+shutdown+exit and check the server's framed responses.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

frame() { local b="$1"; printf 'Content-Length: %d\r\n\r\n%s' "${#b}" "$b"; }

req() {
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  frame '{"jsonrpc":"2.0","id":2,"method":"shutdown"}'
  frame '{"jsonrpc":"2.0","method":"exit"}'
}

OUT="$(req | "$SRV")"
printf '%s' "$OUT" | cat -v
echo
echo "---- checks ----"
fail=0
grep -q 'Content-Length:' <<<"$OUT" || { echo "FAIL: no framing"; fail=1; }
grep -q '"capabilities"' <<<"$OUT" || { echo "FAIL: no capabilities"; fail=1; }
grep -q '"id":1' <<<"$OUT" || { echo "FAIL: initialize id not echoed"; fail=1; }
grep -q '"id":2' <<<"$OUT" || { echo "FAIL: shutdown id not echoed"; fail=1; }
grep -q '"result":null' <<<"$OUT" || { echo "FAIL: shutdown result"; fail=1; }
[[ $fail -eq 0 ]] && echo "handshake OK" || exit 1
