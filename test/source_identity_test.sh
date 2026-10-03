#!/usr/bin/env bash
# D03/U03: an LSP snapshot owns physical buffer coordinates independently of
# compiler display names and logical #line remapping.  The source contains a
# directive with an intentionally unrelated path and line number; every
# position-bearing provider must continue to report the in-memory lines.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]
uri = "file:///physical-snapshot.elisa"
source = (
    "#line 400 /generated/display-name.elisa\n"
    "def physical_name() -> int:\n"
    "    return missing_name\n"
)
physical_lines = source.splitlines()

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": 1,
            "text": source,
        }
    })
    diagnostics = client.wait_notification(
        "textDocument/publishDiagnostics",
        predicate=lambda message: message.get("params", {}).get("uri") == uri,
        timeout=30,
    )["params"]["diagnostics"]
    tokens = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    }, timeout=30)
    symbols = client.request("textDocument/documentSymbol", {
        "textDocument": {"uri": uri},
    }, timeout=30)
    hover = client.request("textDocument/hover", {
        "textDocument": {"uri": uri},
        # `physical_name` starts at character 4 on physical line 1.
        "position": {"line": 1, "character": 5},
    }, timeout=30)
    client.finish(timeout=30)

assert diagnostics, "the undefined identifier must produce a diagnostic"
assert all(item["range"]["start"]["line"] < len(physical_lines) for item in diagnostics), diagnostics
assert any(item["range"]["start"]["line"] == 2 for item in diagnostics), diagnostics
assert all("display-name.elisa" not in item.get("message", "") for item in diagnostics), diagnostics

token_data = tokens.get("result", {}).get("data")
assert isinstance(token_data, list) and len(token_data) % 5 == 0, tokens
decoded = []
line = column = 0
for index in range(0, len(token_data), 5):
    delta_line, delta_column, length, token_type, modifiers = token_data[index:index + 5]
    line += delta_line
    column = column + delta_column if delta_line == 0 else delta_column
    decoded.append((line, column, length, token_type, modifiers))
assert decoded, tokens
assert max(item[0] for item in decoded) < len(physical_lines), decoded
assert any(item[0] == 1 and item[1] == 4 for item in decoded), decoded

symbol_rows = symbols.get("result")
assert isinstance(symbol_rows, list) and len(symbol_rows) == 1, symbols
symbol = symbol_rows[0]
symbol_range = symbol["location"]["range"] if "location" in symbol else symbol["range"]
assert symbol["name"] == "physical_name", symbol
assert symbol_range["start"]["line"] == 1, symbol_range
assert symbol_range["end"]["line"] < len(physical_lines), symbol_range

hover_result = hover.get("result")
assert hover_result and "physical_name" in repr(hover_result), hover

print("source identity OK: #line display path/number cannot replace physical snapshot coordinates")
PY
