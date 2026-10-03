#!/usr/bin/env bash
# A04: isolated process failures cannot kill or poison the live LSP session.
# The crash/hang/malformed-result seam exists only in this temporary test copy.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
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

# Add one-shot faults only to this copy. Parent-side state consumes the selected
# mode after one fork, so the same server can prove recovery on the next edit.
python3 - "$TEST_ROOT/src/analysis_worker_posix.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
source = source.replace(
    "static int worker_active = 0;\n",
    "static int worker_active = 0;\nstatic int analysis_test_mode_consumed = 0;\n"
    "static int analysis_payload_mode_for_child = 0;\n",
    1,
)
needle = "    pid_t child = fork();\n"
assert source.count(needle) == 1, "expected one worker fork site"
source = source.replace(
    needle,
    "    const char *analysis_test_mode = getenv(\"ELISA_LSP_ANALYSIS_TEST_MODE\");\n"
    "    int inject_test_mode = !analysis_test_mode_consumed && analysis_test_mode != NULL;\n"
    "    int payload_mode = 0;\n"
    "    if (inject_test_mode && strcmp(analysis_test_mode, \"semantic-payload\") == 0) payload_mode = 1;\n"
    "    if (inject_test_mode && strcmp(analysis_test_mode, \"symbols-payload\") == 0) payload_mode = 2;\n"
    "    if (inject_test_mode && strcmp(analysis_test_mode, \"hover-payload\") == 0) payload_mode = 3;\n"
    "    if (inject_test_mode && strcmp(analysis_test_mode, \"signature-payload\") == 0) payload_mode = 4;\n"
    "    if (inject_test_mode && strcmp(analysis_test_mode, \"diagnostics-payload\") == 0) payload_mode = 5;\n"
    + needle,
    1,
)
needle = "    if (child == 0) {\n        if (prepare_worker_child(pipe_fds[0], pipe_fds[1]) != 0) _exit(127);\n"
assert source.count(needle) == 1, "expected one worker child setup site"
source = source.replace(
    needle,
    needle
    + "        analysis_payload_mode_for_child = payload_mode;\n"
    + "        if (inject_test_mode && strcmp(analysis_test_mode, \"crash\") == 0) _exit(86);\n"
    + "        if (inject_test_mode && strcmp(analysis_test_mode, \"hang\") == 0) { for (;;) pause(); }\n"
    + "        if (inject_test_mode && strcmp(analysis_test_mode, \"malformed\") == 0) { const char bad[] = \"bad\\n\"; (void)write(WORKER_PIPE_FD, bad, sizeof(bad) - 1); _exit(0); }\n",
    1,
)
needle = "    if (close(pipe_fds[1]) != 0) {\n"
assert source.count(needle) == 1, "expected one parent close site"
source = source.replace(
    needle,
    "    if (inject_test_mode) analysis_test_mode_consumed = 1;\n" + needle,
    1,
)
source = source.replace("#include <stdlib.h>\n", "#include <stdlib.h>\n#include <string.h>\n", 1)
write_needle = r'''    size_t offset = 0;
    while (offset < count) {
        ssize_t written = write(worker_write_fd,
                               (const unsigned char *)buffer + offset,
                               count - offset);
'''
assert source.count(write_needle) == 1, "expected one worker packet write loop"
write_replacement = r'''    const unsigned char *test_buffer = buffer;
    size_t test_count = count;
    unsigned char *negative_counter_packet = NULL;
    const char *packet_test_mode = getenv("ELISA_LSP_ANALYSIS_TEST_MODE");
    if (!analysis_test_mode_consumed && worker_is_child && packet_test_mode != NULL &&
        strcmp(packet_test_mode, "negative-counter") == 0 && count >= 20 &&
        memcmp(buffer, "ELISA-LSP-WORKER\t3\t", 19) == 0) {
        const unsigned char *bytes = buffer;
        size_t newline = count;
        size_t last_tab = 0;
        for (size_t i = 0; i < count; ++i) {
            if (bytes[i] == '\n') { newline = i; break; }
            if (bytes[i] == '\t') last_tab = i;
        }
        if (newline == count - 1 && last_tab + 2 == newline && bytes[last_tab + 1] == '0') {
            negative_counter_packet = malloc(count + 1);
            if (negative_counter_packet == NULL) return -1;
            memcpy(negative_counter_packet, bytes, last_tab + 1);
            negative_counter_packet[last_tab + 1] = '-';
            negative_counter_packet[last_tab + 2] = '1';
            memcpy(negative_counter_packet + last_tab + 3, bytes + last_tab + 2, count - last_tab - 2);
            test_buffer = negative_counter_packet;
            test_count = count + 1;
        }
    }
    size_t offset = 0;
    while (offset < test_count) {
        ssize_t written = write(worker_write_fd,
                               test_buffer + offset,
                               test_count - offset);
'''
assert source.count(write_needle) == 1, "expected one worker packet write loop"
source = source.replace(write_needle, write_replacement, 1)
return_needle = r'''        if (written == 0) errno = EIO;
        return -1;
    }
    return (ssize_t)offset;
'''
return_replacement = r'''        if (written == 0) errno = EIO;
        free(negative_counter_packet);
        return -1;
    }
    free(negative_counter_packet);
    return (ssize_t)count;
'''
assert source.count(return_needle) == 1, "expected one worker write return block"
source = source.replace(return_needle, return_replacement, 1)
source += "\nint elisa_lsp_analysis_payload_corruption_mode(void) { return worker_is_child ? analysis_payload_mode_for_child : 0; }\n"
path.write_text(source, encoding="utf-8")
PY

# Add a test-only child hook to the copied Elisa source. Mutating one payload
# byte preserves the worker header, declared lengths, and total frame size.
python3 - "$TEST_ROOT/src/main.elisa" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
needle = 'extern elisa_lsp_analysis_timeout_millis() -> i64 can[Console]\n'
assert source.count(needle) == 1
source = source.replace(
    needle,
    needle + 'extern elisa_lsp_analysis_payload_corruption_mode() -> int can[Console]\n',
    1,
)
needle = '        packet_written: bool = analysis_worker_send_packet('
assert source.count(needle) == 1
mutator = '''        test_payload_mode: int = elisa_lsp_analysis_payload_corruption_mode() can Console
        if test_payload_mode == 1 and semantic.count > 0:
            semantic[0] <- 120
        elif test_payload_mode == 2 and symbols.count > 0:
            symbols[0] <- 120
        elif test_payload_mode == 3 and hover.count > 0:
            hover[0] <- 120
        elif test_payload_mode == 4 and signature_index.count > 0:
            signature_index[0] <- 120
        elif test_payload_mode == 5 and diagnostics.count > 0:
            diagnostics[0] <- 120
'''
source = source.replace(needle, mutator + needle, 1)
path.write_text(source, encoding="utf-8")
PY

ELISAC="$ELISAC_BIN" ELISA_COMPILER_ROOT="$COMPILER_ROOT" \
  bash "$TEST_ROOT/build.sh" --release

python3 - "$TEST_ROOT/build/elisa-lsp" "$ROOT" <<'PY'
import os
import sys
import time

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

server = sys.argv[1]
uri = "file:///isolated-analysis.elisa"
td = {"textDocument": {"uri": uri}}
valid = "def recovered() -> i64:\n    return 7\nenum Mode:\n    Ready\n"
bad_mode_key = "ELISA_LSP_ANALYSIS_TEST_MODE"
timeout_key = "ELISA_LSP_ANALYSIS_TIMEOUT_MS"

for mode in ("crash", "hang", "malformed", "negative-counter", "semantic-payload", "symbols-payload", "hover-payload", "signature-payload", "diagnostics-payload"):
    previous_mode = os.environ.get(bad_mode_key)
    previous_timeout = os.environ.get(timeout_key)
    os.environ[bad_mode_key] = mode
    os.environ[timeout_key] = "100" if mode == "hang" else "30000"
    try:
        with LspSession(server, startup_timeout=30, request_timeout=30, teardown_timeout=30) as client:
            initialized = client.initialize({"capabilities": {}})
            assert "result" in initialized, initialized
            started = time.monotonic()
            client.notify("textDocument/didOpen", {
                "textDocument": {
                    "uri": uri,
                    "languageId": "Elisa",
                    "version": 1,
                    "text": valid,
                }
            })
            publication = client.wait_notification(
                "textDocument/publishDiagnostics",
                predicate=lambda message: message.get("params", {}).get("uri") == uri,
                timeout=6,
            )
            elapsed = time.monotonic() - started
            assert publication["params"].get("version") == 1, (mode, publication)
            assert publication["params"].get("diagnostics") == [], (mode, publication)
            if mode == "hang":
                assert 0.08 <= elapsed < 3.0, elapsed

            semantic = client.request("textDocument/semanticTokens/full", td)
            assert semantic.get("error", {}).get("code") == -32603, (mode, semantic)
            folding = client.request("textDocument/foldingRange", td)
            assert folding.get("result"), (mode, folding)
            selection = client.request("textDocument/selectionRange", {
                **td,
                "positions": [{"line": 1, "character": 5}],
            })
            assert selection.get("result") and selection["result"][0] is not None, (mode, selection)

            # The fault is one-shot in the test copy. A subsequent accepted
            # snapshot must produce fresh caches and diagnostics in this same
            # server process.
            client.notify("textDocument/didChange", {
                "textDocument": {"uri": uri, "version": 2},
                "contentChanges": [{"text": valid}],
            })
            recovered_publication = client.wait_notification(
                "textDocument/publishDiagnostics",
                predicate=lambda message: (
                    message.get("params", {}).get("uri") == uri
                    and message.get("params", {}).get("version") == 2
                ),
                timeout=8,
            )
            assert recovered_publication["params"].get("diagnostics") == [], recovered_publication
            symbols = client.request("textDocument/documentSymbol", td)
            assert [symbol["name"] for symbol in symbols.get("result", [])] == ["recovered", "Mode"], (mode, symbols)
            if mode == "crash":
                variants = client.request("textDocument/completion", {
                    "textDocument": td["textDocument"],
                    "position": {"line": 3, "character": 7},
                })
                assert [item["label"] for item in variants.get("result", {}).get("items", [])] == ["Ready"], variants
                assert variants["result"]["items"][0]["kind"] == 20, variants
            tokens = client.request("textDocument/semanticTokens/full", td)
            assert tokens.get("result", {}).get("data"), (mode, tokens)
            client.finish(timeout=30)
    finally:
        if previous_mode is None:
            os.environ.pop(bad_mode_key, None)
        else:
            os.environ[bad_mode_key] = previous_mode
        if previous_timeout is None:
            os.environ.pop(timeout_key, None)
        else:
            os.environ[timeout_key] = previous_timeout

# More than fifteen signatures make serialized symbol rows reach three digits.
# This also verifies that the parent validates the signature stream using the
# same REC-relative field offsets as the signature provider.
many_uri = "file:///many-signatures.elisa"
many_text = "".join(
    f"def generated_{index}() -> i64:\n    return 1\n"
    for index in range(16)
)
with LspSession(server, startup_timeout=30, request_timeout=30, teardown_timeout=30) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": many_uri,
            "languageId": "Elisa",
            "version": 1,
            "text": many_text,
        }
    })
    publication = client.wait_notification(
        "textDocument/publishDiagnostics",
        predicate=lambda message: message.get("params", {}).get("uri") == many_uri,
        timeout=8,
    )
    assert publication["params"].get("diagnostics") == [], publication
    many_td = {"textDocument": {"uri": many_uri}}
    tokens = client.request("textDocument/semanticTokens/full", many_td)
    assert tokens.get("result", {}).get("data"), tokens
    symbols = client.request("textDocument/documentSymbol", many_td)
    assert len(symbols.get("result", [])) == 16, symbols
    client.finish(timeout=30)

print("analysis worker isolation OK: process faults, malformed packet/counter/payloads, source-only access, three-digit signature records, and same-process recovery")
PY
