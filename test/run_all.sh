#!/usr/bin/env bash
# Canonical test entry (B02): fresh-binary gate + full suite.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"

if [[ ! -x "$SRV" ]]; then
  echo "error: $SRV missing — build first: bash build.sh" >&2
  exit 2
fi
# Refuse to test a stale binary: any src/ newer than the executable fails fast.
if [[ -n "$(find "$ROOT/src" -newer "$SRV" -print -quit)" ]]; then
  echo "error: $SRV is older than src/ — rebuild: bash build.sh" >&2
  exit 2
fi
if [[ ! -f "$ROOT/build/manifest.json" ]]; then
  echo "error: build/manifest.json missing — rebuild with current build.sh" >&2
  exit 2
fi

pass=0; fail=0
run() {
  echo "===== $1 ====="
  if bash "$ROOT/$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAILED: $1" >&2; fi
}

run test/handshake_test.sh
run test/transport_test.sh
run test/protocol_test.sh
run test/capabilities_test.sh
run test/diagnostics_test.sh
run test/escapes_test.sh
run test/semtokens_test.sh
run test/fstring_semtokens_test.sh
run test/hover_test.sh
run test/hover_escapes_test.sh
run test/document_symbols_test.sh
run test/multi_document_test.sh
run test/documents_test.sh
run test/uri_test.sh
run test/numerics_test.sh
run test/sync_test.sh
run test/positions_test.sh
run test/diagnostic_ranges_test.sh
run test/related_info_test.sh
run test/diagnostics_version_test.sh
run test/json_smoke.sh
run test/manifest_test.sh

echo "----"
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
