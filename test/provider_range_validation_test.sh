#!/usr/bin/env bash
# U02: exercise the opt-in outgoing range validator across every current provider.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }
export ELISA_LSP_VALIDATE_RANGES=1
# These suites cover every provider response arm. Keeping the validation flag
# opt-in means production requests do not pay an additional full-source scan.
for suite in \
  semtokens_test.sh semantic_range_test.sh \
  hover_test.sh general_hover_test.sh signature_help_test.sh \
  definition_test.sh references_test.sh document_highlight_test.sh \
  document_symbols_test.sh folding_test.sh selection_test.sh; do
  bash "$ROOT/test/$suite"
done
printf 'provider range validation OK: %s\n' "$ELISA_LSP_VALIDATE_RANGES"
