#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ELISAC="${ELISAC:-$HOME/.elisac/elisac}"
mkdir -p "$ROOT/build"
"$ELISAC" -emit obj -O2 -o "$ROOT/build/elisa-lsp.o" "$ROOT/src/main.elisa"
clang -O2 "$ROOT/build/elisa-lsp.o" -o "$ROOT/build/elisa-lsp"
echo "built: $ROOT/build/elisa-lsp"
