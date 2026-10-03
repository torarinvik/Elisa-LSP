#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v clang >/dev/null 2>&1 || { echo "error: missing clang" >&2; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP
clang -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
  -o "$WORK/output-write-test" "$ROOT/test/output_write_test.c"
python3 "$ROOT/test/run_native_fixture.py" "$WORK/output-write-test"
