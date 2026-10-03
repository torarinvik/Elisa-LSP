#!/usr/bin/env bash
# Q04: opt-in stage timings are collected and exposed without an editor host.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

ELISA_LSP_TIMINGS=1 \
ELISA_LSP_LOG_LEVEL=info \
ELISA_LSP_LOG_MAX_BYTES=131072 \
python3 - "$SRV" <<'PY'
import os
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve().parent.parent
sys.path.insert(0, str(root / "test"))
from lsp_client import LspSession


STAGE_KEYS = {
    "decode_ms",
    "edit_ms",
    "line_index_ms",
    "lex_ms",
    "parse_ms",
    "check_ms",
    "index_ms",
    "provider_ms",
    "serialization_ms",
    "queue_wait_ms",
    "transport_ms",
}


def assert_timing_shape(result):
    timings = result["timings"]
    assert timings["enabled"] is True, timings
    assert set(timings) == {"enabled", *STAGE_KEYS}, timings
    assert all(type(timings[key]) is int and timings[key] >= 0 for key in STAGE_KEYS), timings
    return timings


uri = "file:///headless-timing.elisa"
source = "def observed(value: i32) -> i32:\n    return value\n"
with LspSession(
    sys.argv[1], startup_timeout=30, request_timeout=30, teardown_timeout=10
) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": uri,
                "languageId": "elisa",
                "version": 1,
                "text": source,
            }
        },
    )
    client.wait_notification("textDocument/publishDiagnostics", timeout=30)
    open_stats = client.request("$/elisa/stats", {})["result"]
    open_timings = assert_timing_shape(open_stats)
    for key in ("edit_ms", "line_index_ms", "lex_ms", "parse_ms", "check_ms", "index_ms"):
        assert open_timings[key] >= 0, open_timings

    hover = client.request(
        "textDocument/hover",
        {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 4}},
    )
    assert "result" in hover, hover
    hover_stats = client.request("$/elisa/stats", {})["result"]
    hover_timings = assert_timing_shape(hover_stats)
    assert hover_timings["provider_ms"] >= 0, hover_timings
    assert client.finish(timeout=30) == 0
    stderr = client.stderr_text()

assert "event=stages method=textDocument/didOpen" in stderr, stderr
assert "event=stages method=textDocument/hover" in stderr, stderr
for key in STAGE_KEYS:
    assert key.replace("_ms", "_ms=") in stderr, (key, stderr)
assert "vscode" not in stderr.lower(), stderr
print("headless timing probe passed; no VS Code/Electron host launched")
PY
