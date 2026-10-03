#!/usr/bin/env bash
# Isolated contract test for build.sh configuration, provenance, and promotion.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/elisa-lsp-build-test.XXXXXX")"
cleanup_test() {
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup_test EXIT INT TERM HUP

REPO="$TMP/repo"
CALLER="$TMP/caller"
HOME_TEST="$TMP/home"
FAKE_BIN="$TMP/fake-bin"
COMPILER_ROOT="$TMP/compiler checkout"
mkdir -p "$REPO" "$CALLER" "$HOME_TEST/.elisac" "$FAKE_BIN" "$COMPILER_ROOT/src/semantic"
mkdir -p "$COMPILER_ROOT/elisacore_std"
cp "$ROOT/build.sh" "$ROOT/project.json" "$REPO/"
cp -R "$ROOT/src" "$REPO/src"
mkdir -p "$REPO/scripts"
cp "$ROOT/scripts/build_hashes.py" "$REPO/scripts/build_hashes.py"
cp "$ROOT/scripts/generate_diagnostic_codes.py" "$REPO/scripts/generate_diagnostic_codes.py"
cp "$ROOT/scripts/check_build_freshness.py" "$REPO/scripts/check_build_freshness.py"
printf '# fake frontend entry\n' > "$COMPILER_ROOT/src/semantic/semantic.elisa"
printf '# fake standard library input\n' > "$COMPILER_ROOT/elisacore_std/runtime_probe.elisa"
printf '# unrelated compiler source\n' > "$COMPILER_ROOT/src/unrelated.elisa"

cat > "$CALLER/fake-stage0" <<'FAKE_COMPILER'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "-emit" && "${2:-}" == "deps-json" ]]; then
  source_path="${@: -1}"
  python3 - "$source_path" "$FAKE_COMPILER_ROOT" <<'PY'
import json
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).resolve()
compiler = pathlib.Path(sys.argv[2]).resolve()
files = [
    source,
    compiler / "src/semantic/semantic.elisa",
    compiler / "elisacore_std/runtime_probe.elisa",
]
print(json.dumps({"root": str(source), "files": [str(path) for path in files]}))
PY
  exit 0
fi
printf '%s\n' "$*" >> "$FAKE_COMPILER_LOG"
printf 'PWD=%s\n' "$PWD" >> "$FAKE_COMPILER_LOG"
if [[ -n "${FAKE_COMPILER_ACTIVITY:-}" ]]; then
  printf 'start\n' >> "$FAKE_COMPILER_ACTIVITY"
  sleep "${FAKE_COMPILER_DELAY_SECONDS:-0.4}"
  printf 'end\n' >> "$FAKE_COMPILER_ACTIVITY"
fi
if [[ "${FAKE_COMPILER_FAIL:-0}" == 1 ]]; then
  echo "fake compile failure" >&2
  exit 17
fi
if [[ "${FAKE_MUTATE_LSP:-0}" == 1 ]]; then
  printf '\n# changed during fake compilation\n' >> "$FAKE_LSP_ROOT/src/main.elisa"
fi
if [[ "${FAKE_MUTATE_BUILD_PIPELINE:-0}" == 1 ]]; then
  printf '\n# changed during fake compilation\n' >> "$FAKE_LSP_ROOT/build.sh"
fi
if [[ ! -f src/../../Elisa-compiler/src/semantic/semantic.elisa ]]; then
  echo "selected frontend is not mounted at the source include path" >&2
  exit 18
fi
out=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == -o ]]; then out="$arg"; fi
  previous="$arg"
done
[[ -n "$out" ]] || { echo "missing -o" >&2; exit 19; }
printf 'fake object: %s\n' "$*" > "$out"
FAKE_COMPILER
chmod +x "$CALLER/fake-stage0"
cp "$CALLER/fake-stage0" "$CALLER/elisac-stage1-test"

cat > "$FAKE_BIN/clang" <<'FAKE_CLANG'
#!/usr/bin/env python3
import os
import pathlib
import sys

args = sys.argv[1:]
if "--version" in args:
    print("fake clang 1.2.3")
    raise SystemExit(0)
if "-dumpmachine" in args:
    print("fake-target-unknown")
    raise SystemExit(0)
with open(os.environ["FAKE_CLANG_LOG"], "a", encoding="utf-8") as stream:
    stream.write("\n".join(args) + "\n---\n")
    for argument in args:
        source = pathlib.Path(argument)
        if source.suffix == ".c" and source.is_file():
            stream.write(source.read_text(encoding="utf-8") + "\n---SOURCE---\n")
if os.environ.get("FAKE_LINK_FAIL") == "1":
    print("fake link failure", file=sys.stderr)
    raise SystemExit(23)
output = pathlib.Path(args[args.index("-o") + 1])
output.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
output.chmod(0o755)
print("PROGRAM:ld PROJECT:fake-ld", file=sys.stderr)
print("BUILD fake-linker 9", file=sys.stderr)
FAKE_CLANG
chmod +x "$FAKE_BIN/clang"

export FAKE_COMPILER_LOG="$TMP/compiler.log"
export FAKE_CLANG_LOG="$TMP/clang.log"
export FAKE_COMPILER_ROOT="$COMPILER_ROOT"
ELISAC_TEST="$CALLER/fake-stage0"

run_build() {
  (
    cd "$CALLER"
    env HOME="$HOME_TEST" PATH="$FAKE_BIN:$PATH" \
      ELISAC="$ELISAC_TEST" ELISA_COMPILER_ROOT="$COMPILER_ROOT" \
      FAKE_COMPILER_LOG="$FAKE_COMPILER_LOG" FAKE_CLANG_LOG="$FAKE_CLANG_LOG" \
      FAKE_LSP_ROOT="$REPO" FAKE_MUTATE_LSP="${FAKE_MUTATE_LSP:-0}" \
      FAKE_MUTATE_BUILD_PIPELINE="${FAKE_MUTATE_BUILD_PIPELINE:-0}" \
      FAKE_COMPILER_FAIL="${FAKE_COMPILER_FAIL:-0}" FAKE_LINK_FAIL="${FAKE_LINK_FAIL:-0}" \
      FAKE_COMPILER_ACTIVITY="${FAKE_COMPILER_ACTIVITY:-}" \
      FAKE_COMPILER_DELAY_SECONDS="${FAKE_COMPILER_DELAY_SECONDS:-0.4}" \
      BUILD_PROFILE="${BUILD_PROFILE_TEST:-}" \
      bash "$REPO/build.sh" "$@"
  )
}

fail() { echo "build_script_test: $*" >&2; exit 1; }

# Relative explicit compiler paths resolve from the invocation directory; the
# selected compiler root is mounted at the source's documented include path.
ELISAC_TEST="./fake-stage0"
BUILD_PROFILE_TEST="debug" run_build --release

python3 - "$REPO" "$FAKE_CLANG_LOG" <<'PY'
import hashlib
import json
import pathlib
import stat
import subprocess
import sys

repo = pathlib.Path(sys.argv[1])
clang_log = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
manifest = json.loads((repo / "build/manifest.json").read_text(encoding="utf-8"))
binary = repo / "build/elisa-lsp"
obj = repo / "build/elisa-lsp.o"
assert manifest["schema_version"] == 3, manifest
assert len(manifest["build_pipeline_sha256"]) == 64, manifest
assert manifest["profile"] == "release" and manifest["opt"] == "O2", manifest
closure = manifest["include_closure"]
assert closure["schema_version"] == 1, closure
assert closure["mode"] == "compiler-emitted-deps-json", closure
assert closure["root"] == "lsp/src/main.elisa", closure
assert closure["file_count"] == len(closure["files"]) == 3, closure
assert {item["path"] for item in closure["files"]} == {
    "lsp/src/main.elisa",
    "compiler/src/semantic/semantic.elisa",
    "compiler/elisacore_std/runtime_probe.elisa",
}, closure
assert len(closure["sha256"]) == 64, closure
assert manifest["elisac"].endswith("/caller/fake-stage0"), manifest["elisac"]
assert manifest["compiler_root"].endswith("/compiler checkout"), manifest["compiler_root"]
assert manifest["frontend_rev"] == manifest["compiler_rev"]
stage0 = manifest["stage0_provenance"]
assert stage0["metadata_available"] is False, stage0
assert stage0["metadata_source"] == "go version -m", stage0
assert stage0["source_module"] is None and stage0["source_revision"] is None, stage0
assert stage0["source_commit_time_utc"] is None and stage0["source_dirty_at_build"] is None, stage0
assert stage0["go_version"] is None and stage0["goos"] is None and stage0["goarch"] is None, stage0
assert stage0["rebuild_recipe"] == (
    "go build -C <stage0-source-root>/compiler "
    "-o <stage0-output>/elisac-stage0 ./src"
), stage0
assert manifest["clang"] == "fake clang 1.2.3", manifest["clang"]
assert manifest["native_linker_version"] == "PROGRAM:ld PROJECT:fake-ld\nBUILD fake-linker 9", manifest
assert manifest["sanitizers"] == [] and "not exposed" in manifest["sanitizer_note"]
assert manifest["artifact_sha256"] == hashlib.sha256(binary.read_bytes()).hexdigest()
assert manifest["object_sha256"] == hashlib.sha256(obj.read_bytes()).hexdigest()
snapshot_root = pathlib.Path(manifest["source_snapshot_root"])
staged_compiler_root = pathlib.Path(manifest["staged_compiler_root"])
assert snapshot_root.name == "source", manifest["source_snapshot_root"]
assert snapshot_root.parent.name == (
    ".elisa-lsp-source-v1."
    + manifest["lsp_inputs_sha256"]
    + "."
    + manifest["compiler_sources_sha256"]
), manifest["source_snapshot_root"]
assert staged_compiler_root == snapshot_root / "Elisa-compiler", manifest["staged_compiler_root"]
assert (staged_compiler_root / "src/semantic/semantic.elisa").is_file()
assert (staged_compiler_root / "elisacore_std/runtime_probe.elisa").is_file()
for path in snapshot_root.rglob("*"):
    assert not path.is_symlink(), path
    if path.is_file():
        assert path.stat().st_mode & 0o222 == 0, path
    else:
        assert path.stat().st_mode & 0o222 == 0, path
assert snapshot_root.stat().st_mode & 0o222 == 0, snapshot_root
assert "transport_posix.c" in clang_log, "POSIX transport source missing from final link"
assert "analysis_worker_posix.c" in clang_log, "analysis worker source missing from final link"
assert "elisa_native_callback_context_free" in clang_log, "stage0 weak callback fallbacks missing"
assert "va_copy(void *source)" in clang_log and "va_end(void *argument)" in clang_log, \
    "stage0 variadic fallback symbols missing"
assert binary.stat().st_mode & 0o111, "executable output is not executable"

# Parse embedded Go build metadata independently of the installed Go tool. A
# clean and dirty build must preserve the source state from the binary; missing
# build information is represented explicitly instead of failing the LSP build.
sys.path.insert(0, str(repo))
from scripts.build_hashes import parse_go_build_info

clean_info = parse_go_build_info(
    "/tmp/elisac-stage0: go1.27.1\n"
    "\tpath\telisacore/src\n"
    "\tbuild\tGOOS=darwin\n"
    "\tbuild\tGOARCH=arm64\n"
    "\tbuild\tvcs.revision=601f7bcd3de62877723ab7f5c5f9a502fb6ef9ae\n"
    "\tbuild\tvcs.time=2026-09-14T17:37:00Z\n"
    "\tbuild\tvcs.modified=false\n"
)
assert clean_info["metadata_available"] is True, clean_info
assert clean_info["source_module"] == "elisacore/src", clean_info
assert clean_info["source_revision"] == "601f7bcd3de62877723ab7f5c5f9a502fb6ef9ae", clean_info
assert clean_info["source_commit_time_utc"] == "2026-09-14T17:37:00Z", clean_info
assert clean_info["source_dirty_at_build"] is False, clean_info
assert clean_info["go_version"] == "go1.27.1", clean_info
assert clean_info["goos"] == "darwin" and clean_info["goarch"] == "arm64", clean_info

dirty_info = parse_go_build_info(
    "/tmp/elisac-stage0: go1.27.1\n"
    "\tpath\telisacore/src\n"
    "\tbuild\tvcs.revision=601f7bcd3de62877723ab7f5c5f9a502fb6ef9ae\n"
    "\tbuild\tvcs.modified=true\n"
)
assert dirty_info["metadata_available"] is True, dirty_info
assert dirty_info["source_dirty_at_build"] is True, dirty_info
assert dirty_info["source_revision"] == clean_info["source_revision"], dirty_info

missing_info = parse_go_build_info("")
assert missing_info["metadata_available"] is False, missing_info
assert missing_info["source_revision"] is None and missing_info["source_dirty_at_build"] is None, missing_info

validator = repo / "scripts/check_build_freshness.py"
manifest_path = repo / "build/manifest.json"

def check_validity(expected_valid, failure_text=None):
    result = subprocess.run(
        [sys.executable, str(validator), "--root", str(repo), "--binary", str(binary), "--manifest", str(manifest_path)],
        capture_output=True,
        text=True,
    )
    if expected_valid:
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    else:
        assert result.returncode == 2, (result.returncode, result.stdout, result.stderr)
        assert failure_text in result.stderr, result.stderr

check_validity(True)

# Snapshot directories are read-only too; otherwise a file could be replaced
# between freshness verification and the compiler's read.
snapshot_dir = pathlib.Path(manifest["staged_compiler_root"])
snapshot_dir_mode = stat.S_IMODE(snapshot_dir.stat().st_mode)
snapshot_dir.chmod(snapshot_dir_mode | stat.S_IWUSR)
check_validity(False, "build source snapshot directory is writable")
snapshot_dir.chmod(snapshot_dir_mode)
check_validity(True)

source_path = repo / "src/main.elisa"
source_bytes = source_path.read_bytes()
source_path.write_bytes(source_bytes + b"\n# source changed after build\n")
check_validity(False, "LSP source/project inputs differ")
source_path.write_bytes(source_bytes)

project_path = repo / "project.json"
project_bytes = project_path.read_bytes()
project_path.write_bytes(project_bytes + b"\n")
check_validity(False, "LSP source/project inputs differ")
project_path.write_bytes(project_bytes)

binary_bytes = binary.read_bytes()
binary.write_bytes(binary_bytes + b"tampered")
check_validity(False, "does not match artifact_sha256")
binary.write_bytes(binary_bytes)
binary.chmod(0o755)

frontend_path = pathlib.Path(manifest["frontend_entry"])
frontend_bytes = frontend_path.read_bytes()
frontend_path.write_bytes(frontend_bytes + b"\n# compiler source changed after build\n")
check_validity(False, "Elisa compiler include closure differs")
frontend_path.write_bytes(frontend_bytes)

runtime_path = pathlib.Path(manifest["compiler_root"]) / "elisacore_std/runtime_probe.elisa"
runtime_bytes = runtime_path.read_bytes()
runtime_path.write_bytes(runtime_bytes + b"\n# standard library source changed after build\n")
check_validity(False, "Elisa compiler include closure differs")
runtime_path.write_bytes(runtime_bytes)

# The compiler consumes a read-only content-addressed copy, not the live tree.
# Mutating that cached input must be detected even while its path still exists.
snapshot_runtime_path = pathlib.Path(manifest["staged_compiler_root"]) / "elisacore_std/runtime_probe.elisa"
snapshot_runtime_mode = stat.S_IMODE(snapshot_runtime_path.stat().st_mode)
snapshot_runtime_bytes = snapshot_runtime_path.read_bytes()
snapshot_runtime_path.chmod(snapshot_runtime_mode | stat.S_IWUSR)
snapshot_runtime_path.write_bytes(snapshot_runtime_bytes + b"\n# staged compiler source changed\n")
snapshot_runtime_path.chmod(snapshot_runtime_mode)
check_validity(False, "staged Elisa-compiler source snapshot differs")
snapshot_runtime_path.chmod(snapshot_runtime_mode | stat.S_IWUSR)
snapshot_runtime_path.write_bytes(snapshot_runtime_bytes)
snapshot_runtime_path.chmod(snapshot_runtime_mode)
check_validity(True)

# The compiler's emitted closure excludes unrelated frontend files.  Editing
# one must remain a valid artifact while the conservative whole-tree hash kept
# for the immutable snapshot still describes the bytes staged at build time.
unrelated_path = pathlib.Path(manifest["compiler_root"]) / "src/unrelated.elisa"
unrelated_bytes = unrelated_path.read_bytes()
unrelated_path.write_bytes(unrelated_bytes + b"\n# unrelated source changed after build\n")
check_validity(True)
unrelated_path.write_bytes(unrelated_bytes)

compiler_path = pathlib.Path(manifest["elisac"])
compiler_bytes = compiler_path.read_bytes()
compiler_path.write_bytes(compiler_bytes + b"\n# compiler binary changed after build\n")
check_validity(False, "stage0 compiler binary differs")
compiler_path.write_bytes(compiler_bytes)

pipeline_path = repo / "build.sh"
pipeline_bytes = pipeline_path.read_bytes()
pipeline_path.write_bytes(pipeline_bytes + b"\n# build pipeline changed after build\n")
check_validity(False, "build-pipeline inputs differ")
pipeline_path.write_bytes(pipeline_bytes)

hash_helper_path = repo / "scripts/build_hashes.py"
hash_helper_bytes = hash_helper_path.read_bytes()
hash_helper_path.write_bytes(hash_helper_bytes + b"\n# hash helper changed after build\n")
check_validity(False, "build-pipeline inputs differ")
hash_helper_path.write_bytes(hash_helper_bytes)
PY

# A verified cached snapshot may come from an older build implementation with
# writable directories. The next build must normalize it before compiling.
python3 - "$REPO/build/manifest.json" <<'PY'
import json
import pathlib
import stat
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
cached_directory = pathlib.Path(manifest["staged_compiler_root"])
cached_directory.chmod(stat.S_IMODE(cached_directory.stat().st_mode) | stat.S_IWUSR)
PY

# BUILD_PROFILE is honored when the command line does not select a profile.
BUILD_PROFILE_TEST="debug" run_build
python3 - "$REPO" "$REPO/build/manifest.json" <<'PY'
import json
import pathlib
import stat
import subprocess
import sys
repo = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
assert manifest["profile"] == "debug" and manifest["opt"] == "O0", manifest
snapshot = pathlib.Path(manifest["source_snapshot_root"])
assert all(path.stat().st_mode & 0o222 == 0 for path in [snapshot, *snapshot.rglob("*")]), snapshot
result = subprocess.run(
    [sys.executable, str(repo / "scripts/check_build_freshness.py"),
     "--root", str(repo), "--binary", str(repo / "build/elisa-lsp"),
     "--manifest", str(manifest_path)],
    capture_output=True,
    text=True,
)
assert result.returncode == 0, (result.stdout, result.stderr)
PY
python3 - "$FAKE_COMPILER_LOG" <<'PY'
import pathlib
import sys

workdirs = [
    line.removeprefix("PWD=")
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.startswith("PWD=")
]
assert len(workdirs) >= 2, workdirs
assert workdirs[0] == workdirs[1], workdirs[:2]
assert ".elisa-lsp-source-v1." in workdirs[0], workdirs[0]
assert ".elisa-lsp-build." not in workdirs[0], workdirs[0]
PY

# Per-repository locks serialize the object/executable/manifest promotion.
# Prove that two simultaneous release/debug invocations do not overlap inside
# the compiler, and that the final published pair still passes freshness.
BUILD_PROFILE_TEST=""
FAKE_COMPILER_ACTIVITY="$TMP/compiler-activity.log"
FAKE_COMPILER_DELAY_SECONDS="0.4" run_build --debug > "$TMP/concurrent-debug.log" 2>&1 &
first_build_pid=$!
sleep 0.05
FAKE_COMPILER_ACTIVITY="$TMP/compiler-activity.log" \
  FAKE_COMPILER_DELAY_SECONDS="0.4" run_build --release > "$TMP/concurrent-release.log" 2>&1 &
second_build_pid=$!
wait "$first_build_pid" || fail "first serialized build failed"
wait "$second_build_pid" || fail "second serialized build failed"
python3 - "$FAKE_COMPILER_ACTIVITY" "$REPO" <<'PY'
import pathlib
import subprocess
import sys

events = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
active = peak = starts = ends = 0
for event in events:
    if event == "start":
        active += 1
        starts += 1
        peak = max(peak, active)
    elif event == "end":
        active -= 1
        ends += 1
        assert active >= 0, events
    else:
        raise AssertionError(events)
assert (starts, ends, active, peak) == (2, 2, 0, 1), (events, peak)
repo = pathlib.Path(sys.argv[2])
result = subprocess.run(
    [sys.executable, str(repo / "scripts/check_build_freshness.py"),
     "--root", str(repo), "--binary", str(repo / "build/elisa-lsp"),
     "--manifest", str(repo / "build/manifest.json")],
    capture_output=True,
    text=True,
)
assert result.returncode == 0, (result.stdout, result.stderr)
PY

before_binary="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$REPO/build/elisa-lsp")"
before_object="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$REPO/build/elisa-lsp.o")"
before_manifest="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$REPO/build/manifest.json")"

# A compile failure and a link failure leave the prior successful artifact set
# and manifest byte-for-byte intact.
if output="$(FAKE_MUTATE_LSP=1 run_build --debug 2>&1)"; then fail "live LSP source race unexpectedly succeeded"; fi
[[ "$output" == *"live Elisa-LSP sources/project.json changed during compilation"* ]] || \
  fail "live LSP source race did not fail closed: $output"
cp -p "$REPO/build.sh" "$TMP/build.sh.before-race"
if output="$(FAKE_MUTATE_BUILD_PIPELINE=1 run_build --debug 2>&1)"; then fail "build-pipeline source race unexpectedly succeeded"; fi
[[ "$output" == *"LSP build pipeline inputs changed during compilation"* ]] || \
  fail "build-pipeline source race did not fail closed: $output"
cp -p "$TMP/build.sh.before-race" "$REPO/build.sh"
if FAKE_COMPILER_FAIL=1 run_build --debug >/dev/null 2>&1; then fail "compiler failure unexpectedly succeeded"; fi
if FAKE_LINK_FAIL=1 run_build --debug >/dev/null 2>&1; then fail "link failure unexpectedly succeeded"; fi
after_binary="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$REPO/build/elisa-lsp")"
after_object="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$REPO/build/elisa-lsp.o")"
after_manifest="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$REPO/build/manifest.json")"
[[ "$before_binary" == "$after_binary" && "$before_object" == "$after_object" && "$before_manifest" == "$after_manifest" ]] || fail "failed build changed a published artifact"

# An invalid explicit ELISAC path must not silently fall back to a discoverable
# HOME installation, and a stage1-named compiler is rejected before compiling.
cp "$CALLER/fake-stage0" "$HOME_TEST/.elisac/elisac-stage0"
ELISAC_TEST="$CALLER/missing-compiler"
if output="$(run_build --release 2>&1)"; then fail "invalid explicit ELISAC path unexpectedly succeeded"; fi
[[ "$output" == *"ELISAC='"*"does not resolve"* ]] || fail "explicit compiler failure was not actionable: $output"
ELISAC_TEST="./elisac-stage1-test"
if output="$(run_build --release 2>&1)"; then fail "stage1 compiler unexpectedly succeeded"; fi
[[ "$output" == *"stage1 self-hosted compiler"* ]] || fail "stage1 rejection was not actionable: $output"

# Invalid profile/configuration is rejected before invoking the compiler.
ELISAC_TEST="./fake-stage0"
calls_before="$(wc -l < "$FAKE_COMPILER_LOG")"
if output="$(run_build --profile=O9 2>&1)"; then fail "unknown profile unexpectedly succeeded"; fi
[[ "$output" == *"unknown build profile"* ]] || fail "unknown profile error missing: $output"
calls_after="$(wc -l < "$FAKE_COMPILER_LOG")"
[[ "$calls_before" == "$calls_after" ]] || fail "compiler ran after invalid profile"

cp "$REPO/project.json" "$TMP/project.json.good"
printf '{ malformed json\n' > "$REPO/project.json"
if output="$(run_build --release 2>&1)"; then fail "malformed project.json unexpectedly succeeded"; fi
[[ "$output" == *"cannot read valid"* ]] || fail "malformed project.json error missing: $output"
mv "$TMP/project.json.good" "$REPO/project.json"
calls_final="$(wc -l < "$FAKE_COMPILER_LOG")"
[[ "$calls_after" == "$calls_final" ]] || fail "compiler ran after malformed project.json"

echo "build_script_test: configuration, staging, provenance, freshness hashes, stage0 guard, and atomic failure behavior passed"
