#!/usr/bin/env bash
# Canonical test entry (B02): fresh-binary gate + full suite.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"

source "$ROOT/scripts/compiler_root_env.sh"
normalize_elisa_compiler_root "$ROOT"

pass=0; fail=0
run() {
  echo "===== $1 ====="
  if bash "$ROOT/$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAILED: $1" >&2; fi
}
run_py() {
  echo "===== $1 ====="
  if python3 "$ROOT/$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAILED: $1" >&2; fi
}

run test/compiler_root_env_test.sh
run_py test/build_hashes_override_test.py

# Run checks that compile their own C fixtures or exercise only the Python
# client harness before requiring an Elisa server artifact. This keeps useful
# transport/build-script evidence available when the server compiler is
# temporarily incompatible, without ever running protocol tests on a stale
# executable.
run test/build_script_test.sh
run test/output_write_test.sh
run test/output_backpressure_test.sh
run test/termination_signal_test.sh
run test/transport_limits_test.sh
run test/analysis_worker_posix_test.sh
run_py test/lsp_client_selftest.py
run_py test/bench_rss_test.py
run_py test/bench_corpus_test.py
run_py test/platform_validation_test.py
run_py test/compiler_upgrade_gate_test.py

if [[ ! -x "$SRV" ]]; then
  echo "error: $SRV missing — build first: bash build.sh" >&2
  fail=$((fail+1))
  echo "partial suite: pass=$pass fail=$fail; server tests were not run"
  exit 2
fi
if [[ ! -f "$ROOT/build/manifest.json" ]]; then
  echo "error: build/manifest.json missing — rebuild with current build.sh" >&2
  fail=$((fail+1))
  echo "partial suite: pass=$pass fail=$fail; server tests were not run"
  exit 2
fi
if ! python3 "$ROOT/scripts/check_build_freshness.py" \
  --root "$ROOT" --binary "$SRV" --manifest "$ROOT/build/manifest.json"; then
  fail=$((fail+1))
  echo "partial suite: pass=$pass fail=$fail; server tests were not run"
  exit 2
fi

# Tests that build isolated variants must use the exact compiler and frontend
# snapshot that produced the validated server. Falling back to ~/.elisac here
# can make one test silently exercise a different compiler than the artifact.
PINNED_TOOLCHAIN="$(python3 - "$ROOT/build/manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
values = (manifest.get("elisac"), manifest.get("staged_compiler_root"))
if any(not isinstance(value, str) or not value or "\t" in value or "\n" in value for value in values):
    raise SystemExit("error: fresh build manifest lacks usable pinned test toolchain paths")
print("\t".join(values))
PY
)"
IFS=$'\t' read -r ELISAC ELISA_COMPILER_ROOT <<< "$PINNED_TOOLCHAIN"
if [[ ! -x "$ELISAC" || ! -d "$ELISA_COMPILER_ROOT/src/semantic" ]]; then
  echo "error: manifest-pinned test compiler or frontend snapshot is unavailable" >&2
  fail=$((fail+1))
  echo "partial suite: pass=$pass fail=$fail; server tests were not run"
  exit 2
fi
export ELISAC ELISA_COMPILER_ROOT
echo "test compiler pinned from build manifest: $ELISAC"
echo "test frontend snapshot pinned from build manifest: $ELISA_COMPILER_ROOT"

run test/handshake_test.sh
run test/transport_test.sh
run test/protocol_test.sh
run_py test/termination_server_test.py
run_py test/output_stall_server_test.py
run test/cancel_test.sh
run test/json_strict_test.sh
run test/json_differential_test.sh
run test/json_escape_utf8_test.sh
run test/capabilities_test.sh
run test/configuration_test.sh
run test/diagnostic_codes_test.sh
run_py test/diagnostic_span_inventory_test.py
run test/unsupported_constructs_test.sh
run test/diagnostics_test.sh
run test/escapes_test.sh
run test/semtokens_test.sh
run test/semtoken_families_test.sh
run test/semantic_modifiers_test.sh
run test/contextual_tokens_test.sh
run test/provider_range_validation_test.sh
run test/semantic_range_test.sh
run test/precedence_test.sh
run test/fstring_semtokens_test.sh
run test/multiline_tokens_test.sh
run test/hover_test.sh
run test/general_hover_test.sh
run test/hover_escapes_test.sh
run test/completion_test.sh
run test/signature_help_test.sh
run test/definition_test.sh
run test/references_test.sh
run test/rename_test.sh
run test/document_highlight_test.sh
run test/document_symbols_test.sh
run test/folding_test.sh
run test/selection_test.sh
run test/multi_document_test.sh
run test/workspace_roots_test.sh
run test/documents_test.sh
run test/analysis_cache_test.sh
run test/combined_lexer_test.sh
run test/cache_eviction_test.sh
run test/storage_reclaim_test.sh
run test/open_source_budget_test.sh
run test/open_document_metadata_budget_test.sh
run test/resource_budget_test.sh
run test/observability_test.sh
run test/timing_test.sh
run test/storage_metadata_move_test.sh
run test/uri_collision_test.sh
run test/uri_test.sh
run test/uri_path_test.sh
run test/filesystem_identity_test.sh
run test/source_identity_test.sh
run test/numerics_test.sh
run test/sync_test.sh
run test/incremental_sync_test.sh
run test/positions_test.sh
run test/diagnostic_ranges_test.sh
run test/related_info_test.sh
run test/diagnostics_version_test.sh
run test/incomplete_source_test.sh
run test/failed_analysis_request_test.sh
run test/analysis_worker_test.sh
run test/json_smoke.sh
run test/frontend_contract_test.sh
run test/manifest_test.sh

echo "----"
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
