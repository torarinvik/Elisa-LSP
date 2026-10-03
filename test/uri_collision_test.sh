#!/usr/bin/env bash
# D04: force every URI into one hash chain in an isolated source copy, then
# exercise equality, head/middle/tail removal, and freed-slot reuse over LSP.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ELISAC_BIN="${ELISAC:-$HOME/.elisac/elisac-stage0}"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-$ROOT/../Elisa-compiler}"
[[ -x "$ELISAC_BIN" ]] || { echo "error: no compiler at $ELISAC_BIN (set ELISAC)" >&2; exit 2; }
[[ -d "$COMPILER_ROOT/src/semantic" ]] || { echo "error: compiler checkout not found at $COMPILER_ROOT" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "error: missing clang" >&2; exit 2; }

WORK="$(mktemp -d)"
cleanup_test_work() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ -n "${WORK:-}" && -e "$WORK" ]]; then
    # build.sh leaves content-addressed source snapshots immutable. Restore
    # owner write permission only inside this private test directory so rm can
    # remove nested snapshot directories. Cleanup diagnostics must not replace
    # the protocol test's actual exit status.
    chmod -R u+w "$WORK" 2>/dev/null || true
    if ! rm -rf "$WORK"; then
      printf 'warning: could not remove temporary test directory %s (test exit status %s)\n' \
        "$WORK" "$status" >&2
    fi
  fi
  exit "$status"
}
trap cleanup_test_work EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
TEST_ROOT="$WORK/Elisa-LSP"
mkdir -p "$TEST_ROOT/scripts"
cp -R "$ROOT/src" "$TEST_ROOT/src"
cp "$ROOT/build.sh" "$ROOT/project.json" "$TEST_ROOT/"
cp "$ROOT/scripts/build_hashes.py" "$TEST_ROOT/scripts/"
cp "$ROOT/scripts/generate_diagnostic_codes.py" "$TEST_ROOT/scripts/"

# Rewrite exactly the copied hash function. There is no environment or
# protocol-controlled collision mode in the real server binary.
python3 - "$TEST_ROOT/src/documents.elisa" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
start_marker = "def document_hash(uri: sview) -> u64:"
end_marker = "\n\n# Return the cached document index"
assert source.count(start_marker) == 1, "expected one document_hash definition"
start = source.index(start_marker)
end = source.index(end_marker, start)
source = source[:start] + start_marker + "\n    return 1" + source[end:]
path.write_text(source, encoding="utf-8")
PY

ELISAC="$ELISAC_BIN" ELISA_COMPILER_ROOT="$COMPILER_ROOT" \
  bash "$TEST_ROOT/build.sh" --release

cat > "$WORK/startup_canary.c" <<'EOF'
int main(void) { return 0; }
EOF
clang -O2 -fno-builtin -o "$WORK/startup_canary" "$WORK/startup_canary.c"

python3 - "$WORK/startup_canary" "$TEST_ROOT/build/elisa-lsp" "$ROOT" <<'PY'
import os
import signal
import subprocess
import sys

try:
    canary = subprocess.Popen(
        [sys.argv[1]],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=(sys.platform != "win32"),
    )
    try:
        _, _ = canary.communicate(timeout=5)
        canary_started = canary.returncode == 0
    except subprocess.TimeoutExpired:
        if sys.platform != "win32":
            try:
                os.killpg(canary.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        else:
            canary.kill()
        canary.communicate()
        canary_started = False
except OSError:
    canary_started = False

if not canary_started:
    print("URI collision SKIP: host cannot start linked executables")
    raise SystemExit(0)

sys.path.insert(0, os.path.join(sys.argv[3], "test"))
from lsp_client import LspSession

srv = sys.argv[2]
uris = {name: f"file:///collision/{name}.elisa" for name in "abcd"}


def source(name):
    return f"def {name}() -> i64:\n    return 1\n"


def open_doc(client, name, function=None):
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uris[name],
            "languageId": "Elisa",
            "version": 1,
            "text": source(function or name),
        }
    })


def close_doc(client, name):
    client.notify("textDocument/didClose", {
        "textDocument": {"uri": uris[name]},
    })


def symbols(client, name):
    response = client.request("textDocument/documentSymbol", {
        "textDocument": {"uri": uris[name]},
    })
    assert "result" in response, response
    return [item["name"] for item in response["result"]]


with LspSession(srv, startup_timeout=30, request_timeout=30, teardown_timeout=30) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    open_doc(client, "a")
    open_doc(client, "b")
    open_doc(client, "c")
    assert symbols(client, "a") == ["a"]
    assert symbols(client, "b") == ["b"]
    assert symbols(client, "c") == ["c"]
    assert symbols(client, "d") == []  # Equal hash must not imply equal URI.

    close_doc(client, "b")  # Remove a middle chain node.
    assert symbols(client, "a") == ["a"]
    assert symbols(client, "b") == []
    assert symbols(client, "c") == ["c"]

    open_doc(client, "d")  # Reuse the freed slot and prepend a new head.
    assert symbols(client, "d") == ["d"]
    assert symbols(client, "c") == ["c"]
    assert symbols(client, "a") == ["a"]
    close_doc(client, "d")  # Remove the head.
    assert symbols(client, "d") == []
    assert symbols(client, "c") == ["c"]
    close_doc(client, "a")  # Remove the tail.
    assert symbols(client, "a") == []
    assert symbols(client, "c") == ["c"]
    close_doc(client, "c")
    assert symbols(client, "c") == []

    open_doc(client, "b", "beta_reopened")
    assert symbols(client, "b") == ["beta_reopened"]
    assert symbols(client, "a") == []
    client.finish(timeout=30)

print("URI collision chain OK: URI equality, head/middle/tail unlink, slot reuse and reinsertion")
PY
