#!/usr/bin/env bash
# Elisa LSP build — stage0-only, profile-driven, and provenance-recorded.
#
# Usage:
#   bash build.sh [--debug|--release|--profile NAME]
#   ELISAC=/path/to/elisacore bash build.sh
#   ELISA_COMPILER_ROOT=/path/to/Elisa-compiler bash build.sh
#
# `project.json` is the source of truth for the entry point, output paths, and
# optimization profiles. The explicit ELISAC path is resolved against the
# caller's working directory before this script changes directories.
set -euo pipefail

CALLER_DIR="${ELISA_LSP_BUILD_CALLER_DIR:-$PWD}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Resolve an explicit path before changing to ROOT. A name without a slash is
# allowed as a PATH lookup for compatibility with shell environments.
EXPLICIT_ELISAC=""
ELISAC_WAS_EXPLICIT=0
if [[ -n "${ELISAC:-}" ]]; then
  ELISAC_WAS_EXPLICIT=1
  EXPLICIT_ELISAC="$ELISAC"
  if [[ "$EXPLICIT_ELISAC" == */* && "$EXPLICIT_ELISAC" != /* ]]; then
    EXPLICIT_ELISAC="$CALLER_DIR/$EXPLICIT_ELISAC"
  elif [[ "$EXPLICIT_ELISAC" != */* ]]; then
    EXPLICIT_ELISAC="$(command -v -- "$EXPLICIT_ELISAC" 2>/dev/null || true)"
  fi
  if [[ -n "$EXPLICIT_ELISAC" && "$EXPLICIT_ELISAC" != /* ]]; then
    EXPLICIT_ELISAC="$CALLER_DIR/$EXPLICIT_ELISAC"
  fi
fi
EXPLICIT_COMPILER_ROOT=""
if [[ -n "${ELISA_COMPILER_ROOT:-}" ]]; then
  EXPLICIT_COMPILER_ROOT="$ELISA_COMPILER_ROOT"
  if [[ "$EXPLICIT_COMPILER_ROOT" != /* ]]; then
    EXPLICIT_COMPILER_ROOT="$CALLER_DIR/$EXPLICIT_COMPILER_ROOT"
  fi
fi
cd "$ROOT"

REQUESTED_PROFILE=""
# Bash 3.2 (the system Bash on macOS) treats expansion of an empty array as
# unbound under `set -u`. A private trailing sentinel keeps forwarding safe for
# the default-profile/no-argument invocation; the Python wrapper strips it.
BUILD_ARGS=("$@" "__ELISA_LSP_BUILD_INTERNAL_SENTINEL__")
while (($#)); do
  case "$1" in
    --debug) REQUESTED_PROFILE="debug" ;;
    --release) REQUESTED_PROFILE="release" ;;
    --profile=*) REQUESTED_PROFILE="${1#--profile=}" ;;
    --profile)
      shift
      if (($# == 0)); then
        echo "error: --profile requires a name from project.json" >&2
        exit 2
      fi
      REQUESTED_PROFILE="$1"
      ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *) echo "error: unknown arg '$1' (try --debug|--release|--profile NAME)" >&2; exit 2 ;;
  esac
  shift
done
if [[ -z "$REQUESTED_PROFILE" && -n "${BUILD_PROFILE:-}" ]]; then
  REQUESTED_PROFILE="$BUILD_PROFILE"
fi

command -v python3 >/dev/null 2>&1 || {
  echo "error: missing python3 (needed to validate project.json and write the manifest)" >&2
  exit 2
}

# Validate configuration once. The project file is intentionally strict: a
# malformed or stale build description must fail, never silently build a
# different source or optimization level.
if ! CONFIG="$(python3 - "$ROOT/project.json" "$REQUESTED_PROFILE" <<'PY'
import json
import pathlib
import sys

project_path = pathlib.Path(sys.argv[1])
requested = sys.argv[2]
try:
    project = json.loads(project_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"error: cannot read valid {project_path}: {exc}")

try:
    target = project["targets"]["elisa-lsp"]
    profiles = target["profiles"]
    default_profile = target["default_profile"]
    entry = target["entry"]
    emit = target["emit"]
    object_output = target["output"]
    executable_output = target["executable"]
except (KeyError, TypeError) as exc:
    raise SystemExit(f"error: project.json is missing required elisa-lsp setting: {exc}")

if not isinstance(profiles, dict) or not profiles:
    raise SystemExit("error: project.json targets.elisa-lsp.profiles must be a non-empty object")
for name, opt in profiles.items():
    if not isinstance(name, str) or not name or opt not in ("O0", "O1", "O2", "O3"):
        raise SystemExit(f"error: invalid build profile {name!r}: expected an opt level O0 through O3")
if default_profile not in profiles:
    raise SystemExit(f"error: default_profile {default_profile!r} is not present in profiles")
profile = requested or default_profile
if profile not in profiles:
    available = ", ".join(sorted(profiles))
    raise SystemExit(f"error: unknown build profile {profile!r}; available profiles: {available}")

if emit != "obj":
    raise SystemExit(f"error: unsupported elisa-lsp emit mode {emit!r}; build.sh requires 'obj'")

def safe_relative(value, label):
    if not isinstance(value, str) or not value or "\n" in value or "\t" in value:
        raise SystemExit(f"error: invalid {label} path in project.json")
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"error: {label} must be a repository-relative path without '..': {value!r}")
    return value

entry = safe_relative(entry, "entry")
object_output = safe_relative(object_output, "object output")
executable_output = safe_relative(executable_output, "executable output")
object_parts = pathlib.PurePosixPath(object_output).parts
executable_parts = pathlib.PurePosixPath(executable_output).parts
if not object_parts or not executable_parts or object_parts[0] != "build" or executable_parts[0] != "build":
    raise SystemExit("error: project outputs must be located below build/")
if object_output == executable_output:
    raise SystemExit("error: object and executable output paths must differ")
if not (project_path.parent / entry).is_file():
    raise SystemExit(f"error: project entry does not exist: {entry}")

print("\t".join((profile, profiles[profile], entry, emit, object_output, executable_output)))
PY
)"; then
  exit 2
fi
IFS=$'\t' read -r PROFILE OPT ENTRY EMIT OBJECT_OUTPUT EXECUTABLE_OUTPUT <<<"$CONFIG"

# A build publishes three related files (object, executable, manifest) using
# individual atomic renames. Serialize builders for this repository so two
# otherwise-successful invocations cannot interleave those promotions or
# contend for the same generated snapshot. The advisory OS lock is released
# automatically after normal exit, failure, or process termination.
if [[ "${ELISA_LSP_BUILD_LOCK_PARENT_PID:-}" != "$PPID" ]]; then
  exec python3 - "$ROOT" "$ROOT/build.sh" "$CALLER_DIR" "${BUILD_ARGS[@]}" <<'PY'
import fcntl
import os
import pathlib
import stat
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
script = pathlib.Path(sys.argv[2]).resolve(strict=True)
build_dir = root / "build"
build_dir.mkdir(parents=True, exist_ok=True)
if build_dir.is_symlink() or build_dir.resolve(strict=True).parent != root:
    raise SystemExit(f"error: build directory must be a real directory below {root}")

lock_path = build_dir / ".elisa-lsp-build.lock"
flags = os.O_CREAT | os.O_RDWR
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
try:
    lock_fd = os.open(lock_path, flags, 0o600)
except OSError as exc:
    raise SystemExit(f"error: cannot open Elisa-LSP build lock {lock_path}: {exc}")

metadata = os.fstat(lock_fd)
if not stat.S_ISREG(metadata.st_mode):
    os.close(lock_fd)
    raise SystemExit(f"error: Elisa-LSP build lock is not a regular file: {lock_path}")
os.fchmod(lock_fd, 0o600)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print(
        "another Elisa-LSP build is active; waiting to keep artifact publication consistent",
        file=sys.stderr,
        flush=True,
    )
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

environment = os.environ.copy()
environment["ELISA_LSP_BUILD_LOCK_PARENT_PID"] = str(os.getpid())
environment["ELISA_LSP_BUILD_CALLER_DIR"] = sys.argv[3]
try:
    result = subprocess.run(
        ["bash", str(script), *sys.argv[4:-1]],
        env=environment,
        pass_fds=(lock_fd,),
        check=False,
    )
except OSError as exc:
    raise SystemExit(f"error: cannot run locked Elisa-LSP build: {exc}")
raise SystemExit(result.returncode)
PY
fi

# ---- stage0 toolchain discovery ----
CANDIDATES=()
if ((ELISAC_WAS_EXPLICIT)); then
  CANDIDATES+=("$EXPLICIT_ELISAC")
else
  CANDIDATES+=("$HOME/.elisac/elisac-stage0" "$HOME/.elisac/elisac")
fi
ELISAC_BIN=""
for candidate in "${CANDIDATES[@]}"; do
  if [[ -f "$candidate" && -x "$candidate" ]]; then
    ELISAC_BIN="$candidate"
    break
  fi
done
if [[ -z "$ELISAC_BIN" ]]; then
  if ((ELISAC_WAS_EXPLICIT)); then
    echo "error: ELISAC='$ELISAC' does not resolve to an executable file." >&2
  else
    echo "error: no Elisa compiler found." >&2
  fi
  echo "  Set ELISAC to a stage0 elisacore executable, for example:" >&2
  echo "    ELISAC=\$HOME/.elisac/elisac-stage0 bash build.sh" >&2
  echo "  Tried: ${CANDIDATES[*]}" >&2
  echo "  See docs/development.md § toolchain." >&2
  exit 2
fi
ELISAC_BIN_DIR="$(cd -- "$(dirname -- "$ELISAC_BIN")" && pwd -P)"
ELISAC_BIN="$ELISAC_BIN_DIR/$(basename -- "$ELISAC_BIN")"

# Stage1 self-hosted compiler binaries have not passed feature-parity checks for
# this target. Preserve the supported stage0 path contract and fail before build.
BIN_NAME="$(basename -- "$ELISAC_BIN")"
if [[ "$BIN_NAME" == elisac-stage1* ]]; then
  if [[ "${ELISA_LSP_ALLOW_STAGE1_GATE:-0}" != "1" ]]; then
    echo "error: '$ELISAC_BIN' is a stage1 self-hosted compiler." >&2
    echo "  Stage1 has not passed the Elisa-LSP feature-parity and optimized test gates." >&2
    echo "  Use the supported stage0 compiler for LSP builds:" >&2
    echo "    ELISAC=\$HOME/.elisac/elisac-stage0 bash build.sh" >&2
    exit 2
  fi
  echo "warning: stage1 compiler admitted only for the disposable upgrade gate; artifact is not a supported release" >&2
fi

command -v clang >/dev/null 2>&1 || { echo "error: missing clang on PATH" >&2; exit 2; }

# ---- compiler checkout / frontend include root ----
DEFAULT_COMPILER_ROOT="$(cd -- "$ROOT/../Elisa-compiler" 2>/dev/null && pwd -P || true)"
if [[ -n "${ELISA_COMPILER_ROOT:-}" ]]; then
  COMPILER_ROOT="$(cd -- "$EXPLICIT_COMPILER_ROOT" 2>/dev/null && pwd -P || true)"
else
  COMPILER_ROOT="$DEFAULT_COMPILER_ROOT"
fi
if [[ -z "$COMPILER_ROOT" || ! -d "$COMPILER_ROOT/src/semantic" ]]; then
  echo "error: Elisa compiler checkout not found or missing src/semantic." >&2
  echo "  Expected \$ELISA_COMPILER_ROOT/src/semantic/semantic.elisa" >&2
  echo "  (default adjacent checkout: $ROOT/../Elisa-compiler)." >&2
  echo "  Set ELISA_COMPILER_ROOT explicitly, e.g.:" >&2
  echo "    ELISA_COMPILER_ROOT=/path/to/Elisa-compiler bash build.sh" >&2
  exit 2
fi
FRONTEND_ENTRY="$COMPILER_ROOT/src/semantic/semantic.elisa"
[[ -f "$FRONTEND_ENTRY" ]] || { echo "error: missing frontend entry $FRONTEND_ENTRY" >&2; exit 2; }

# ---- platform gate and same-filesystem staging ----
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin|Linux) ;;
  *) echo "warning: untested platform $OS/$ARCH (validated candidates: macOS, Linux)" >&2 ;;
esac

mkdir -p "$ROOT/build"
mkdir -p "$ROOT/$(dirname -- "$OBJECT_OUTPUT")" "$ROOT/$(dirname -- "$EXECUTABLE_OUTPUT")"
WORK="$(mktemp -d "$ROOT/build/.elisa-lsp-build.XXXXXX")"
SNAPSHOT_CANDIDATE=""
cleanup_build() {
  rm -rf "$WORK"
  if [[ -n "$SNAPSHOT_CANDIDATE" ]]; then
    # A candidate is made read-only before atomic publication. Restore its
    # owner write bits only on this private mktemp path so a failed or losing
    # concurrent build can clean up its own candidate safely.
    chmod -R u+w "$SNAPSHOT_CANDIDATE" 2>/dev/null || true
    rm -rf "$SNAPSHOT_CANDIDATE"
  fi
}
trap cleanup_build EXIT INT TERM HUP
OBJ="$WORK/elisa-lsp.o"
EXE="$WORK/elisa-lsp"
MANIFEST="$WORK/manifest.json"
FALLBACK_C="$WORK/elisa-fallback.c"
LINK_LOG="$WORK/link.log"

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
/* Match the stage0 driver's weak executable fallbacks without linking its
 * runtime object, which would duplicate the runtime already emitted inline. */
ELISA_WEAK void *elisa_native_callback_ptr(uint8_t *name) { (void)name; return NULL; }
ELISA_WEAK uint32_t elisa_native_callback_call_u32_voidp(uint8_t *name, void *arg, uint32_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK int32_t elisa_native_callback_call_i32_voidp(uint8_t *name, void *arg, int32_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK uintptr_t elisa_native_callback_call_usize_voidp(uint8_t *name, void *arg, uintptr_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK intptr_t elisa_native_callback_call_isize_voidp(uint8_t *name, void *arg, intptr_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK uint32_t elisa_native_callback_spawn_join_u32_voidp(uint8_t *name, void *arg, uint32_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK void *elisa_native_callback_context_new_u32_voidp(uint8_t *name, void *arg, uint32_t fallback) { (void)name; (void)arg; (void)fallback; return NULL; }
ELISA_WEAK void *elisa_native_callback_context_entry_u32_voidp(void) { return NULL; }
ELISA_WEAK int32_t elisa_native_callback_context_start_u32_voidp(void *ctx, uintptr_t *thread) { (void)ctx; (void)thread; return -1; }
ELISA_WEAK uint32_t elisa_native_callback_context_join_u32_voidp(uintptr_t handle, void *ctx, uint32_t fallback) { (void)handle; (void)ctx; return fallback; }
ELISA_WEAK uint32_t elisa_native_callback_context_spawn_join_u32_voidp(void *ctx, uint32_t fallback) { (void)ctx; return fallback; }
ELISA_WEAK uint32_t elisa_native_callback_context_result_u32(void *ctx, uint32_t fallback) { (void)ctx; return fallback; }
ELISA_WEAK void elisa_native_callback_context_free(void *ctx) { (void)ctx; }
ELISA_WEAK void *va_copy(void *source) { return source; }
ELISA_WEAK void va_end(void *argument) { (void)argument; }
EOF

# Capture the live inputs before staging. Compilation must use exactly these
# bytes, even if either checkout changes while the build is running.
INPUT_HASHES="$(python3 "$ROOT/scripts/build_hashes.py" \
  --lsp-root "$ROOT" \
  --compiler-root "$COMPILER_ROOT" \
  --compiler-bin "$ELISAC_BIN")"
IFS=$'\t' read -r LSP_INPUTS_BEFORE COMPILER_SOURCES_BEFORE ELISAC_SHA256_BEFORE BUILD_PIPELINE_BEFORE <<<"$INPUT_HASHES"
if [[ ! "$LSP_INPUTS_BEFORE" =~ ^[0-9a-f]{64}$ || ! "$COMPILER_SOURCES_BEFORE" =~ ^[0-9a-f]{64}$ || ! "$ELISAC_SHA256_BEFORE" =~ ^[0-9a-f]{64}$ || ! "$BUILD_PIPELINE_BEFORE" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: failed to fingerprint build inputs" >&2
  exit 2
fi

# Ask the selected compiler for the exact include closure before staging.  The
# helper prefers the compiler's own `-emit deps-json` resolver and falls back
# to a parser/tree approximation for older stage0 binaries.  The normalized
# logical-path/content records are carried into the manifest and rechecked
# against the immutable staged tree before publication.
INCLUDE_CLOSURE_JSON="$WORK/include-closure.json"
python3 "$ROOT/scripts/build_hashes.py" \
  --lsp-root "$ROOT" \
  --compiler-root "$COMPILER_ROOT" \
  --compiler-bin "$ELISAC_BIN" \
  --entry "$ENTRY" \
  --dependency-closure > "$INCLUDE_CLOSURE_JSON"
python3 - "$INCLUDE_CLOSURE_JSON" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    info = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"error: compiler include-closure report is invalid: {exc}")
if (
    not isinstance(info, dict)
    or info.get("schema_version") != 1
    or not isinstance(info.get("sha256"), str)
    or len(info["sha256"]) != 64
    or not isinstance(info.get("files"), list)
    or not info["files"]
):
    raise SystemExit("error: compiler include-closure report is incomplete")
PY

# The stage0 compiler embeds source filenames in panic reports. A randomized
# source directory therefore made identical builds differ and left a stale
# temporary path in each executable. Key this immutable snapshot by its exact
# LSP/compiler source fingerprints; concurrent builders may race to publish it,
# but only a fully copied and verified directory is ever made visible.
SOURCE_SNAPSHOT="$ROOT/build/.elisa-lsp-source-v1.${LSP_INPUTS_BEFORE}.${COMPILER_SOURCES_BEFORE}"
STAGE_ROOT="$SOURCE_SNAPSHOT/source"
STAGED_LSP="$STAGE_ROOT/Elisa-LSP"
STAGED_COMPILER_ROOT="$STAGE_ROOT/Elisa-compiler"

hash_staged_sources() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" "$1" "$2" <<'PY'
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from scripts.build_hashes import compiler_sources_sha256, lsp_inputs_sha256

print(
    lsp_inputs_sha256(pathlib.Path(sys.argv[2]))
    + "\t"
    + compiler_sources_sha256(pathlib.Path(sys.argv[3]))
)
PY
}

if [[ ! -e "$SOURCE_SNAPSHOT" && ! -L "$SOURCE_SNAPSHOT" ]]; then
  SNAPSHOT_CANDIDATE="$(mktemp -d "$ROOT/build/.elisa-lsp-source-candidate.XXXXXX")"
  CANDIDATE_STAGE_ROOT="$SNAPSHOT_CANDIDATE/source"
  CANDIDATE_LSP="$CANDIDATE_STAGE_ROOT/Elisa-LSP"
  CANDIDATE_COMPILER="$CANDIDATE_STAGE_ROOT/Elisa-compiler"
  mkdir -p "$CANDIDATE_LSP" "$CANDIDATE_COMPILER"
  cp -R "$ROOT/src" "$CANDIDATE_LSP/src"
  cp "$ROOT/project.json" "$CANDIDATE_LSP/project.json"
  cp -R "$COMPILER_ROOT/src" "$CANDIDATE_COMPILER/src"
  cp -R "$COMPILER_ROOT/elisacore_std" "$CANDIDATE_COMPILER/elisacore_std"

  CANDIDATE_HASHES="$(hash_staged_sources "$CANDIDATE_LSP" "$CANDIDATE_COMPILER")"
  IFS=$'\t' read -r CANDIDATE_LSP_INPUTS CANDIDATE_COMPILER_SOURCES <<<"$CANDIDATE_HASHES"
  if [[ "$CANDIDATE_LSP_INPUTS" != "$LSP_INPUTS_BEFORE" || "$CANDIDATE_COMPILER_SOURCES" != "$COMPILER_SOURCES_BEFORE" ]]; then
    echo "error: Elisa-LSP or Elisa-compiler sources changed while the build snapshot was staged; refusing to compile" >&2
    exit 2
  fi

  # The compiler only reads this tree. Make files and directories read-only:
  # protecting files alone still lets a process replace an entry between the
  # pre-build hash and compiler reads. The outer candidate directory becomes
  # the content-addressed snapshot root after rename.
  find "$CANDIDATE_STAGE_ROOT" -type f -exec chmod a-w {} +
  find "$SNAPSHOT_CANDIDATE" -type d -exec chmod a-w {} +
  if ! python3 - "$SNAPSHOT_CANDIDATE" "$SOURCE_SNAPSHOT" <<'PY'
import errno
import os
import pathlib
import sys

candidate = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
try:
    os.rename(candidate, destination)
except OSError as exc:
    # Another builder may have atomically published the same immutable input
    # snapshot after our initial existence check. Any other error is fatal.
    if exc.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not destination.is_dir() or destination.is_symlink():
        raise
PY
  then
    echo "error: could not atomically publish the Elisa build source snapshot" >&2
    exit 2
  fi
fi

# Whether this process published the snapshot or lost a concurrent publication
# race, validate the exact tree that the compiler will read. Never repair or
# overwrite a corrupt content-addressed directory implicitly.
if [[ -L "$SOURCE_SNAPSHOT" || -L "$STAGE_ROOT" || -L "$STAGED_LSP" || -L "$STAGED_COMPILER_ROOT" || \
      ! -d "$STAGED_LSP/src" || ! -f "$STAGED_LSP/project.json" || \
      ! -d "$STAGED_COMPILER_ROOT/src/semantic" || ! -d "$STAGED_COMPILER_ROOT/elisacore_std" ]]; then
  echo "error: cached Elisa build source snapshot is incomplete or contains unexpected symlinks: $SOURCE_SNAPSHOT" >&2
  exit 2
fi
SNAPSHOT_LINKS="$(find "$STAGE_ROOT" -type l -print -quit)"
if [[ -n "$SNAPSHOT_LINKS" ]]; then
  echo "error: cached Elisa build source snapshot contains a symlink: $SNAPSHOT_LINKS" >&2
  exit 2
fi
STAGED_HASHES="$(hash_staged_sources "$STAGED_LSP" "$STAGED_COMPILER_ROOT")"
IFS=$'\t' read -r STAGED_LSP_INPUTS STAGED_COMPILER_SOURCES <<<"$STAGED_HASHES"
if [[ "$STAGED_LSP_INPUTS" != "$LSP_INPUTS_BEFORE" || "$STAGED_COMPILER_SOURCES" != "$COMPILER_SOURCES_BEFORE" ]]; then
  echo "error: cached Elisa build source snapshot does not match its content key; refusing to compile" >&2
  exit 2
fi
python3 - "$ROOT" "$INCLUDE_CLOSURE_JSON" "$STAGED_LSP" "$STAGED_COMPILER_ROOT" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from scripts.build_hashes import dependency_closure_sha256_for_roots

info = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
try:
    actual = dependency_closure_sha256_for_roots(
        pathlib.Path(sys.argv[3]),
        pathlib.Path(sys.argv[4]),
        info["files"],
    )
except (KeyError, TypeError, ValueError, OSError, RuntimeError) as exc:
    raise SystemExit(f"error: cannot validate staged compiler include closure: {exc}")
if actual != info.get("sha256"):
    raise SystemExit("error: staged compiler include closure differs from the pre-build report")
PY

# Older snapshots produced before directory immutability was enforced may
# still have writable directories. Once their contents have been verified,
# normalize permissions before the compiler can read them. Fresh candidates
# are already in this state; this path upgrades a valid existing cache safely.
find "$SOURCE_SNAPSHOT" -type f -exec chmod a-w {} +
find "$SOURCE_SNAPSHOT" -type d -exec chmod a-w {} +

echo "elisac: $ELISAC_BIN"
echo "frontend: $FRONTEND_ENTRY"
echo "profile: $PROFILE (-$OPT)  entry: $ENTRY  platform: $OS/$ARCH"

# Compile and link entirely in WORK. WORK is below build/, so the final moves
# are same-filesystem atomic renames rather than possible cross-device copies.
(
  cd "$STAGED_LSP"
  "$ELISAC_BIN" -emit "$EMIT" "-$OPT" -o "$OBJ" "$ENTRY"
)

if ! clang "-$OPT" -fno-builtin -Wl,-v -o "$EXE" "$OBJ" "$FALLBACK_C" "$STAGED_LSP/src/transport_posix.c" "$STAGED_LSP/src/analysis_worker_posix.c" >"$LINK_LOG" 2>&1; then
  cat "$LINK_LOG" >&2
  exit 1
fi
chmod +x "$EXE"

LSP_REV="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
COMPILER_REV="$(git -C "$COMPILER_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
CLANG_VER="$(clang --version 2>/dev/null | head -n 1)"
TARGET_TRIPLE="$(clang -dumpmachine 2>/dev/null || echo unknown)"
STAMP="$(date -u +%FT%TZ)"
ELISAC_BIN_EV="$ELISAC_BIN" COMPILER_ROOT_EV="$COMPILER_ROOT" COMPILER_REV_EV="$COMPILER_REV" \
LSP_REV_EV="$LSP_REV" CLANG_VER_EV="$CLANG_VER" TARGET_TRIPLE_EV="$TARGET_TRIPLE" \
STAMP_EV="$STAMP" PROFILE_EV="$PROFILE" OPT_EV="$OPT" ENTRY_EV="$ENTRY" EMIT_EV="$EMIT" \
OS_EV="$OS" ARCH_EV="$ARCH" FRONTEND_ENTRY_EV="$FRONTEND_ENTRY" \
ELISAC_VERSION_EV="not-reported-by-stage0-cli" EXE_EV="$EXE" OBJ_EV="$OBJ" LINK_LOG_EV="$LINK_LOG" \
ROOT_EV="$ROOT" COMPILER_ROOT_HASH_EV="$COMPILER_ROOT" STAGED_LSP_EV="$STAGED_LSP" \
STAGED_COMPILER_ROOT_EV="$STAGED_COMPILER_ROOT" STAGE_ROOT_EV="$STAGE_ROOT" \
LSP_INPUTS_BEFORE_EV="$LSP_INPUTS_BEFORE" COMPILER_SOURCES_BEFORE_EV="$COMPILER_SOURCES_BEFORE" \
ELISAC_SHA256_BEFORE_EV="$ELISAC_SHA256_BEFORE" BUILD_PIPELINE_BEFORE_EV="$BUILD_PIPELINE_BEFORE" \
INCLUDE_CLOSURE_JSON_EV="$INCLUDE_CLOSURE_JSON" \
PYTHONDONTWRITEBYTECODE=1 python3 - "$MANIFEST" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, os.environ["ROOT_EV"])
from scripts.build_hashes import (
    build_pipeline_sha256,
    compiler_sources_sha256,
    dependency_closure_sha256_for_roots,
    lsp_inputs_sha256,
    sha256_file,
    stage0_provenance,
)

manifest_path = pathlib.Path(sys.argv[1])
repo_root = pathlib.Path(os.environ["ROOT_EV"])
compiler_root = pathlib.Path(os.environ["COMPILER_ROOT_HASH_EV"])
staged_lsp_root = pathlib.Path(os.environ["STAGED_LSP_EV"])
staged_compiler_root = pathlib.Path(os.environ["STAGED_COMPILER_ROOT_EV"])

def git_output(path, *args):
    try:
        return subprocess.check_output(["git", "-C", str(path), *args], stderr=subprocess.DEVNULL).decode("utf-8", "replace").strip()
    except (OSError, subprocess.CalledProcessError):
        return ""

def git_dirty(path):
    try:
        status = subprocess.check_output(["git", "-C", str(path), "status", "--porcelain", "-z"], stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        status = b""
    return bool(status), hashlib.sha256(status).hexdigest()

link_lines = pathlib.Path(os.environ["LINK_LOG_EV"]).read_text(encoding="utf-8", errors="replace").splitlines()
linker_version_lines = []
for index, line in enumerate(link_lines):
    if "PROGRAM:ld" in line or "GNU ld" in line or "LLD" in line or "gold" in line.lower():
        linker_version_lines = link_lines[index:index + 2]
        break
linker_version = "\n".join(linker_version_lines) if linker_version_lines else "unreported-by-linker"

lsp_dirty, lsp_status_hash = git_dirty(repo_root)
compiler_dirty, compiler_status_hash = git_dirty(compiler_root)
live_lsp_inputs_hash = lsp_inputs_sha256(repo_root)
compiler_sources_hash = compiler_sources_sha256(compiler_root)
lsp_inputs_hash = lsp_inputs_sha256(staged_lsp_root)
staged_compiler_sources_hash = compiler_sources_sha256(staged_compiler_root)
elisac_hash = sha256_file(os.environ["ELISAC_BIN_EV"])
stage0_build_info = stage0_provenance(pathlib.Path(os.environ["ELISAC_BIN_EV"]))
build_pipeline_hash = build_pipeline_sha256(repo_root)
include_closure_info = json.loads(
    pathlib.Path(os.environ["INCLUDE_CLOSURE_JSON_EV"]).read_text(encoding="utf-8")
)
include_closure_records = include_closure_info["files"]

if live_lsp_inputs_hash != os.environ["LSP_INPUTS_BEFORE_EV"]:
    raise SystemExit("error: live Elisa-LSP sources/project.json changed during compilation; refusing to publish")
if lsp_inputs_hash != os.environ["LSP_INPUTS_BEFORE_EV"]:
    raise SystemExit("error: staged LSP input hash changed during compilation; refusing to publish")
if staged_compiler_sources_hash != os.environ["COMPILER_SOURCES_BEFORE_EV"]:
    raise SystemExit("error: staged Elisa-compiler sources changed during compilation; refusing to publish")
if compiler_sources_hash != os.environ["COMPILER_SOURCES_BEFORE_EV"]:
    raise SystemExit("error: Elisa-compiler sources changed during compilation; refusing to publish")
if elisac_hash != os.environ["ELISAC_SHA256_BEFORE_EV"]:
    raise SystemExit("error: stage0 compiler binary changed during compilation; refusing to publish")
if build_pipeline_hash != os.environ["BUILD_PIPELINE_BEFORE_EV"]:
    raise SystemExit("error: LSP build pipeline inputs changed during compilation; refusing to publish")
live_include_closure_hash = dependency_closure_sha256_for_roots(
    repo_root,
    compiler_root,
    include_closure_records,
)
staged_include_closure_hash = dependency_closure_sha256_for_roots(
    staged_lsp_root,
    staged_compiler_root,
    include_closure_records,
)
if live_include_closure_hash != include_closure_info["sha256"]:
    raise SystemExit("error: live compiler include closure changed during compilation; refusing to publish")
if staged_include_closure_hash != include_closure_info["sha256"]:
    raise SystemExit("error: staged compiler include closure changed during compilation; refusing to publish")

data = {
    "schema_version": 3,
    "artifact": "elisa-lsp",
    "built_at_utc": os.environ["STAMP_EV"],
    "profile": os.environ["PROFILE_EV"],
    "opt": os.environ["OPT_EV"],
    "entry": os.environ["ENTRY_EV"],
    "emit": os.environ["EMIT_EV"],
    "build_flags": ["-" + os.environ["OPT_EV"], "-fno-builtin", "-Wl,-v"],
    "artifact_sha256": sha256_file(os.environ["EXE_EV"]),
    "object_sha256": sha256_file(os.environ["OBJ_EV"]),
    "build_pipeline_sha256": build_pipeline_hash,
    "include_closure": include_closure_info,
    "source_snapshot_root": os.environ["STAGE_ROOT_EV"],
    "lsp_inputs_sha256": lsp_inputs_hash,
    "lsp_rev": os.environ["LSP_REV_EV"] or "unknown",
    "lsp_dirty": lsp_dirty,
    "lsp_status_sha256": lsp_status_hash,
    "elisac": os.environ["ELISAC_BIN_EV"],
    "elisac_version": os.environ["ELISAC_VERSION_EV"],
    "elisac_sha256": elisac_hash,
    "stage0_provenance": stage0_build_info,
    "compiler_root": os.environ["COMPILER_ROOT_EV"],
    "staged_compiler_root": os.environ["STAGED_COMPILER_ROOT_EV"],
    "compiler_rev": os.environ["COMPILER_REV_EV"] or "unknown",
    "compiler_dirty": compiler_dirty,
    "compiler_status_sha256": compiler_status_hash,
    "compiler_sources_sha256": compiler_sources_hash,
    "frontend_entry": os.environ["FRONTEND_ENTRY_EV"],
    "frontend_rev": os.environ["COMPILER_REV_EV"] or "unknown",
    "clang": os.environ["CLANG_VER_EV"],
    "native_linker_version": linker_version,
    "target_triple": os.environ["TARGET_TRIPLE_EV"],
    "os_arch": os.environ["OS_EV"] + "/" + os.environ["ARCH_EV"],
    "sanitizers": [],
    "sanitizer_note": "Elisa stage0 object instrumentation is not exposed by this CLI; clang link-time flags alone would not instrument the Elisa object.",
}
with open(manifest_path, "w", encoding="utf-8") as stream:
    stream.write(json.dumps(data, indent=2, sort_keys=True) + "\n")
    stream.flush()
    os.fsync(stream.fileno())
PY

python3 - "$MANIFEST" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
if data["lsp_dirty"]:
    print("warning: LSP working tree contains uncommitted changes; input hashes are recorded in the build manifest", file=sys.stderr)
if data["compiler_dirty"]:
    print("warning: compiler checkout contains uncommitted changes; source fingerprint is recorded in the build manifest", file=sys.stderr)
PY

# Promote only completed outputs. Each rename is atomic: if compilation or
# linking failed above, the previous executable, object, and manifest remain.
mv -f "$OBJ" "$ROOT/$OBJECT_OUTPUT"
mv -f "$EXE" "$ROOT/$EXECUTABLE_OUTPUT"
mv -f "$MANIFEST" "$ROOT/build/manifest.json"
echo "built: $ROOT/$EXECUTABLE_OUTPUT ($PROFILE -$OPT)"
echo "manifest: $ROOT/build/manifest.json"
