#!/usr/bin/env bash
# R05: opt-in bounded logging and the safe private self-description probe.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json
import os
import subprocess
import sys

from pathlib import Path

server = Path(sys.argv[1]).resolve()
root = server.parent.parent
sys.path.insert(0, str(root / "test"))
from lsp_client import LspSession


def run_info_session() -> None:
    old_level = os.environ.get("ELISA_LSP_LOG_LEVEL")
    old_limit = os.environ.get("ELISA_LSP_LOG_MAX_BYTES")
    os.environ["ELISA_LSP_LOG_LEVEL"] = "debug"
    os.environ["ELISA_LSP_LOG_MAX_BYTES"] = "4096"
    try:
        with LspSession(server, startup_timeout=30, request_timeout=30, teardown_timeout=10) as client:
            initialized = client.initialize({"capabilities": {}})
            assert "result" in initialized, initialized

            status = client.request("$/elisa/status", {})["result"]
            assert status["server"] == {
                "name": "elisa-lsp",
                "version": "0.1.0",
                "status": "running",
            }, status
            assert status["compatibility"] == {
                "jsonrpc": "2.0",
                "lsp": "3.18",
                "manifest_schema": 3,
                "worker_packet_version": 3,
                "diagnostic_code_schema": 1,
            }, status
            assert status["compiler"]["status"] == "embedded", status
            assert status["compiler"]["source"] == "Elisa compiler frontend", status
            assert isinstance(status["compiler"]["contract_version"], int), status
            assert status["compiler"]["provenance"] == "build/manifest.json", status
            assert status["configuration"]["position_encoding"] == "utf-16", status
            assert status["logging"]["level"] == "debug", status
            assert status["logging"]["max_bytes"] == 4096, status
            assert status["logging"]["source_text"] == "excluded", status
            assert status["logging"]["wire_trace"] == "disabled", status

            uri = "file:///observability.elisa"
            client.notify(
                "textDocument/didOpen",
                {
                    "textDocument": {
                        "uri": uri,
                        "languageId": "elisa",
                        "version": 1,
                        "text": "def observed() -> void:\n    pass\n",
                    }
                },
            )
            client.wait_notification("textDocument/publishDiagnostics", timeout=30)
            hover = client.request(
                "textDocument/hover",
                {
                    "textDocument": {"uri": uri},
                    "position": {"line": 0, "character": 4},
                },
            )
            assert "result" in hover, hover
            assert client.finish(timeout=30) == 0
        stderr = client.stderr_text()
    finally:
        if old_level is None:
            os.environ.pop("ELISA_LSP_LOG_LEVEL", None)
        else:
            os.environ["ELISA_LSP_LOG_LEVEL"] = old_level
        if old_limit is None:
            os.environ.pop("ELISA_LSP_LOG_MAX_BYTES", None)
        else:
            os.environ["ELISA_LSP_LOG_MAX_BYTES"] = old_limit

    raw = stderr.encode("utf-8")
    assert len(raw) <= 4096, len(raw)
    assert "event=compiler status=embedded" in stderr, stderr
    assert "event=method method=initialize elapsed_ms=" in stderr, stderr
    assert "event=method method=$/elisa/status elapsed_ms=" in stderr, stderr
    assert "event=document method=textDocument/didOpen generation=" in stderr, stderr
    assert "cache=updated" in stderr, stderr
    assert "event=method method=textDocument/hover elapsed_ms=" in stderr, stderr
    assert "generation=" in stderr, stderr
    assert "observed" not in stderr, stderr
    assert "observability" not in stderr, stderr


def invalid_level_is_rejected() -> None:
    env = os.environ.copy()
    env["ELISA_LSP_LOG_LEVEL"] = "definitely-invalid"
    result = subprocess.run([str(server)], input=b"", capture_output=True, env=env, timeout=5)
    assert result.returncode == 2, (result.returncode, result.stderr)
    assert not result.stdout, result.stdout
    assert len(result.stderr) <= 65536, len(result.stderr)
    assert b"log setting" in result.stderr, result.stderr


run_info_session()
invalid_level_is_rejected()
print("observability logging/status checks passed")
PY
