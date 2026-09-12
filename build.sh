#!/usr/bin/env bash
# Elisa LSP build — reproducible toolchain with provenance (B01).
#
# Supported compiler: stage0 `elisacore` (full backend). The self-hosted
# stage1 binaries (`Elisa-compiler/bin/elisac-stage1*`) currently decline LSP
# constructs (range match in `push_utf8`, packed-enum matches, etc.) and must
# NOT be used for this target; build.sh rejects them with an actionable error.
#
# Usage:
#   bash build.sh [--debug|--release] [--profile O0|O1|O2|O3]
#   ELISAC=/path/to/elisacore bash build.sh
#   ELISA_COMPILER_ROOT=/path/to/Elisa-compiler bash build.sh
#
# Env:
#   ELISAC                explicit compiler executable (preferred)
#   ELISA_COMPILER_ROOT   adjacent compiler checkout for frontend include + revision
#   BUILD_PROFILE         debug (O0) or release (O2, default)
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PROFILE="release"
OPT="O2"
for arg in "$@"; do
  case "$arg" in
    --debug) PROFILE="debug"; OPT="O0" ;;
    --release) PROFILE="release"; OPT="O2" ;;
    --profile=*) OPT="${arg#--profile=}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "error: unknown arg '$arg' (try --debug|--release)" >&2; exit 2 ;;
  esac
done
if [[ "${BUILD_PROFILE:-}" == "debug" ]]; then PROFILE="debug"; OPT="O0"; fi
if [[ "${BUILD_PROFILE:-}" == "release" ]]; then PROFILE="release"; OPT="O2"; fi

# ---- toolchain discovery ----
CANDIDATES=()
[[ -n "${ELISAC:-}" ]] && CANDIDATES+=("$ELISAC")
CANDIDATES+=("$HOME/.elisac/elisac-stage0" "$HOME/.elisac/elisac")
ELISAC_BIN=""
for c in "${CANDIDATES[@]}"; do
  if [[ -x "$c" ]]; then ELISAC_BIN="$c"; break; fi
  if [[ -f "$c" && -x "$c" ]]; then ELISAC_BIN="$c"; break; fi
done
if [[ -z "$ELISAC_BIN" ]]; then
  echo "error: no Elisa compiler found." >&2
  echo "  Set ELISAC to a stage0 elisacore executable, e.g.:" >&2
  echo "    ELISAC=\$HOME/.elisac/elisac-stage0 bash build.sh" >&2
  echo "  Tried: ${CANDIDATES[*]}" >&2
  echo "  See docs/development.md § toolchain." >&2
  exit 2
fi
# Reject stage1 self-hosted compilers for this target (incomplete backend).
if "$ELISAC_BIN" -emit obj -o /dev/null /dev/null 2>&1 | grep -q "declined" ; then :; fi
BIN_NAME="$(basename "$ELISAC_BIN")"
if [[ "$BIN_NAME" == elisac-stage1* ]]; then
  echo "error: '$ELISAC_BIN' is a stage1 self-hosted compiler." >&2
  echo "  Its backend declines LSP constructs (range match, packed-enum match)." >&2
  echo "  Use a stage0 elisacore instead:" >&2
  echo "    ELISAC=\$HOME/.elisac/elisac-stage0 bash build.sh" >&2
  exit 2
fi
command -v clang >/dev/null 2>&1 || { echo "error: missing clang on PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: missing python3 (needed for manifest)" >&2; exit 2; }

# ---- compiler checkout / frontend include root ----
DEFAULT_COMPILER_ROOT="$(cd -- "$ROOT/../Elisa-compiler" 2>/dev/null && pwd || true)"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-${DEFAULT_COMPILER_ROOT:-}}"
if [[ -z "$COMPILER_ROOT" || ! -d "$COMPILER_ROOT/src/semantic" ]]; then
  echo "error: Elisa compiler checkout not found." >&2
  echo "  Expected \$ELISA_COMPILER_ROOT/src/semantic/semantic.elisa" >&2
  echo "  (default adjacent checkout: $ROOT/../Elisa-compiler)." >&2
  echo "  Set ELISA_COMPILER_ROOT explicitly, e.g.:" >&2
  echo "    ELISA_COMPILER_ROOT=/path/to/Elisa-compiler bash build.sh" >&2
  exit 2
fi
FRONTEND_ENTRY="$COMPILER_ROOT/src/semantic/semantic.elisa"
[[ -f "$FRONTEND_ENTRY" ]] || { echo "error: missing frontend entry $FRONTEND_ENTRY" >&2; exit 2; }

# ---- project settings (single source of truth: project.json) ----
ENTRY="$(python3 -c 'import json;print(json.load(open("project.json"))["targets"]["elisa-lsp"]["entry"])' 2>/dev/null || echo "src/main.elisa")"
PROJECT_OPT="$(python3 -c 'import json;print(json.load(open("project.json"))["targets"]["elisa-lsp"].get("opt","O2"))' 2>/dev/null || echo "O2")"
if [[ "$PROJECT_OPT" != "$OPT" ]]; then
  echo "note: build profile OPT=$OPT overrides project.json opt=$PROJECT_OPT for this invocation" >&2
fi

# ---- platform gate ----
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin|Linux) ;;
  *) echo "warning: untested platform $OS/$ARCH (validated candidates: macOS, Linux)" >&2 ;;
esac

mkdir -p "$ROOT/build"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/elisa-lsp-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP
OBJ="$WORK/elisa-lsp.o"
EXE="$WORK/elisa-lsp"
FALLBACK_C="$WORK/elisa-fallback.c"

cat > "$FALLBACK_C" <<'EOF'
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__) || defined(__clang__)
#define ELISA_WEAK __attribute__((weak))
#else
#define ELISA_WEAK
#endif
ELISA_WEAK uint32_t elisa_profile_allocation_negotiate(uint32_t version) { (void)version; return 0; }
ELISA_WEAK uint32_t elisa_profile_region_layout_negotiate(uint32_t version) { (void)version; return 0; }
ELISA_WEAK void elisa_profile_region_layout_v1(uintptr_t arena, size_t region, uintptr_t header, uintptr_t data, size_t capacity) { (void)arena; (void)region; (void)header; (void)data; (void)capacity; }
ELISA_WEAK void elisa_profile_allocation_event_v1(uint32_t kind, uintptr_t address, size_t size, uintptr_t old_address, size_t old_size, uintptr_t arena, size_t region) { (void)kind; (void)address; (void)size; (void)old_address; (void)old_size; (void)arena; (void)region; }
EOF

echo "elisac: $ELISAC_BIN"
echo "frontend: $FRONTEND_ENTRY"
echo "profile: $PROFILE (-$OPT)  entry: $ENTRY  platform: $OS/$ARCH"

# Compile to temp object (do NOT touch build/ until link succeeds).
"$ELISAC_BIN" -emit obj "-$OPT" -o "$OBJ" "$ROOT/$ENTRY"

# Link with host clang + weak profiling fallback (stage0 objects reference
# these optional host hooks; the runtime itself is already in the object).
clang "-$OPT" -fno-builtin -o "$EXE" "$OBJ" "$FALLBACK_C"

# Provenance manifest (machine-readable).
LSP_REV="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
LSP_DIRTY="$(git -C "$ROOT" status --short 2>/dev/null | head -n 20 || true)"
COMPILER_REV="$(git -C "$COMPILER_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
CLANG_VER="$(clang --version 2>/dev/null | head -n 1)"
TARGET_TRIPLE="$(clang -dumpmachine 2>/dev/null || echo "unknown")"
STAMP="$(date -u +%FT%TZ)"
ELISAC_BIN_EV="$ELISAC_BIN" COMPILER_ROOT_EV="$COMPILER_ROOT" COMPILER_REV_EV="$COMPILER_REV" \
LSP_REV_EV="$LSP_REV" CLANG_VER_EV="$CLANG_VER" TARGET_TRIPLE_EV="$TARGET_TRIPLE" \
STAMP_EV="$STAMP" PROFILE_EV="$PROFILE" OPT_EV="$OPT" ENTRY_EV="$ENTRY" OS_EV="$OS" ARCH_EV="$ARCH" \
python3 - "$ROOT/build/manifest.json" <<'PY'
import json,sys,os
manifest={
  "artifact":"elisa-lsp",
  "built_at_utc":os.environ["STAMP_EV"],
  "profile":os.environ["PROFILE_EV"],
  "opt":os.environ["OPT_EV"],
  "entry":os.environ["ENTRY_EV"],
  "elisac": os.environ["ELISAC_BIN_EV"],
  "compiler_root": os.environ["COMPILER_ROOT_EV"],
  "compiler_rev": os.environ["COMPILER_REV_EV"],
  "lsp_rev": os.environ["LSP_REV_EV"],
  "clang": os.environ["CLANG_VER_EV"],
  "target_triple": os.environ["TARGET_TRIPLE_EV"],
  "os_arch": os.environ["OS_EV"]+"/"+os.environ["ARCH_EV"],
}
open(sys.argv[1],"w").write(json.dumps(manifest,indent=2)+"\n")
PY
if [[ -n "$LSP_DIRTY" ]]; then
  echo "warning: working tree has uncommitted changes; binary includes them (see git status)" >&2
fi

# Atomic replace only on success.
mv -f "$OBJ" "$ROOT/build/elisa-lsp.o"
mv -f "$EXE" "$ROOT/build/elisa-lsp"
chmod +x "$ROOT/build/elisa-lsp"
echo "built: $ROOT/build/elisa-lsp ($PROFILE -$OPT)"
echo "manifest: $ROOT/build/manifest.json"
