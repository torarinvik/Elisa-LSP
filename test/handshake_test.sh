#!/usr/bin/env bash
# Shared-client initialize -> initialized -> shutdown -> exit lifecycle smoke test.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

with LspSession(sys.argv[1], request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert initialized.get("id") == 1, initialized
    assert "result" in initialized, initialized
    assert "capabilities" in initialized["result"], initialized

    # finish() performs shutdown, sends exit, drains stdout, and reaps the
    # process. Its strict decoder also validates every Content-Length frame.
    client.finish(timeout=30)

    shutdown = client.responses.get(("int", 2))
    assert shutdown is not None, client.all_messages
    assert shutdown.get("result", object()) is None, shutdown
    assert len(client.raw_bodies) >= 2, client.all_messages
    client.assert_no_stderr_errors()

print("handshake OK: initialize, initialized, shutdown, exit; valid framed responses")
PY
