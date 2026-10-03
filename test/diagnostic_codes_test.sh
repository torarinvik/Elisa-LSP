#!/usr/bin/env bash
# G01: the generated diagnostic-code adapter must match the pinned frontend enum.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/compiler_root_env.sh"
normalize_elisa_compiler_root "$ROOT"
: "${ELISA_COMPILER_ROOT:?compiler root normalization failed}"
python3 "$ROOT/scripts/generate_diagnostic_codes.py" \
  --compiler-root "$ELISA_COMPILER_ROOT" \
  --output "$ROOT/src/diagnostic_codes.elisa" \
  --check
python3 - "$ROOT/src/diagnostic_codes.elisa" "$ELISA_COMPILER_ROOT/src/semantic/semantic_types_diagnostic_kind.elisa" <<'PY'
import re
import sys
from pathlib import Path
adapter = Path(sys.argv[1]).read_text(encoding="utf-8")
enum = Path(sys.argv[2]).read_text(encoding="utf-8")
variants = re.findall(r"^\s{12}([A-Za-z_][A-Za-z0-9_]*)\s*$", enum[enum.index("const enum DiagnosticKind"):], re.M)
assert len(variants) >= 1, "frontend enum unexpectedly empty"
for name in variants:
    assert f'Semantic::DiagnosticKind.{name}: "ELISA-{name}"' in adapter, name
assert adapter.count("Semantic::DiagnosticKind.") == len(variants), "unexpected adapter arms"
assert adapter.endswith('        _: "ELISA-Unknown"\n'), "missing unknown fallback"
print(f"diagnostic code adapter OK: {len(variants)} compiler kinds")
PY
