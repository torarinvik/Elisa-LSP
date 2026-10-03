#!/usr/bin/env bash
# JSON string-escape decoding: real LSP clients send the document with every
# newline/quote escaped per the JSON spec (`\\n`, `\\"`, ...). The server must
# DECODE those before handing the text to the frontend — regression for the
# bug where raw `\\n` sequences reached the parser (error storms on small docs,
# silent extraction failure on large ones), found wiring up the JetBrains
# client.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

uri = "file:///esc.elisa"
with LspSession(sys.argv[1], request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized

    # didOpen's newline-bearing source is JSON-serialized by LspSession.frame.
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": 1,
            "text": "def ok() -> void:\n    pass\n",
        }
    })
    opened = client.wait_notification(
        "textDocument/publishDiagnostics",
        predicate=lambda message: message.get("params", {}).get("uri") == uri,
        timeout=30,
    )
    assert opened["params"]["uri"] == uri, opened
    assert opened["params"]["diagnostics"] == [], \
        "clean didOpen must publish empty diagnostics (escapes decoded, no parse-error storm)"

    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{
            "text": ('def demo() -> void:\n'
                     '    x: bool = 5\n'
                     '    s: cstr = "quoted \\\\ text"\n'
                     '    _ = s\n'
                     '    _ = x\n'),
        }],
    })
    changed = client.wait_notification(
        "textDocument/publishDiagnostics",
        predicate=lambda message: message.get("params", {}).get("uri") == uri,
        timeout=30,
    )
    diagnostics = changed["params"]["diagnostics"]
    assert any('expects bool, got int' in item.get("message", "") for item in diagnostics), \
        "didChange must yield the expected type mismatch"
    assert any(item["range"]["start"]["line"] == 1 for item in diagnostics), \
        "diagnostic must be on 0-based line 1"
    assert not any("expected a" in item.get("message", "") for item in diagnostics), \
        "escape decoding must not cause a syntax-error storm"

    client.finish(timeout=30)

print("escapes OK")
PY
