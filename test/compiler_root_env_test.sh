#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/scripts/compiler_root_env.sh"

EXPECTED_ROOT="$(cd -- "$ROOT/../Elisa-compiler" && pwd -P)"

(
  unset ELISA_COMPILER_ROOT
  normalize_elisa_compiler_root "$ROOT"
  [[ "$ELISA_COMPILER_ROOT" == "$EXPECTED_ROOT" ]]
)

(
  export ELISA_COMPILER_ROOT='../Elisa-compiler'
  normalize_elisa_compiler_root "$ROOT"
  [[ "$ELISA_COMPILER_ROOT" == "$EXPECTED_ROOT" ]]
)

(
  export ELISA_COMPILER_ROOT='/path/that/does/not/exist/elisa-compiler'
  normalize_elisa_compiler_root "$ROOT"
  [[ "$ELISA_COMPILER_ROOT" == '/path/that/does/not/exist/elisa-compiler' ]]
)

echo 'compiler_root_env_test: PASS'
