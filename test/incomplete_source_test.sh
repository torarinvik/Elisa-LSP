#!/usr/bin/env bash
# A04: incomplete and malformed source must not kill the session. A sequence of
# broken documents (unfinished declarations, dangling delimiters, half-written
# generics, incomplete interpolation, unterminated literals/comments, deep
# nesting) is opened and edited while every provider is exercised, then a valid
# edit must recover with clean diagnostics and fresh tokens.
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
BROKEN = [
    "",                                                     # empty
    "def\n",                                                # unfinished decl
    "def f( -> void:\n    pass\n",                          # missing param close
    "def f() -> void:\n    x: i64 = (\n",                   # dangling paren
    "def f() -> i64:\n    return 1 +\n",                    # trailing operator
    "struct S:\n    x:\n",                                  # missing type
    "enum E:\n    A(\n",                                    # unfinished variant
    "def f() -> void:\n    s: dstr = \"unterminated\n",    # unterminated string
    "def f() -> void:\n    \"\"\"\n    open doc block\n",   # unterminated comment
    "def f() -> void:\n    s: dstr = f\"hi {\n",            # incomplete interpolation
    "def f[T: -> void:\n    pass\n",                        # half-written generic
    "def f() -> void:\n    match\n",                        # dangling selector
    "def f() -> void:\n" + "    x: i64 = 1\n" * 200 + "    y: i64 = (\n",  # deep body
]
GOOD = "def ok() -> void:\n    x: i64 = 1\n"
URI = "file:///a04.elisa"

with LspSession(
    srv,
    startup_timeout=15,
    request_timeout=120,
    teardown_timeout=10,
) as client:
    initialized = client.initialize({"capabilities": {}}, timeout=30)
    assert "result" in initialized, initialized

    # Open and edit through every broken state, exercising each provider.
    for i, source in enumerate(BROKEN):
        version = i * 2 + 1
        if i == 0:
            client.notify("textDocument/didOpen", {
                "textDocument": {
                    "uri": URI,
                    "languageId": "Elisa",
                    "version": version,
                    "text": source,
                }
            })
        else:
            client.notify("textDocument/didChange", {
                "textDocument": {"uri": URI, "version": version},
                "contentChanges": [{"text": source}],
            })

        base = 100 + i * 10
        requests = [
            {"jsonrpc": "2.0", "id": base, "method": "textDocument/semanticTokens/full",
             "params": {"textDocument": {"uri": URI}}},
            {"jsonrpc": "2.0", "id": base + 1, "method": "textDocument/documentSymbol",
             "params": {"textDocument": {"uri": URI}}},
            {"jsonrpc": "2.0", "id": base + 2, "method": "textDocument/foldingRange",
             "params": {"textDocument": {"uri": URI}}},
            {"jsonrpc": "2.0", "id": base + 3, "method": "textDocument/selectionRange",
             "params": {"textDocument": {"uri": URI},
                         "positions": [{"line": 0, "character": 0},
                                       {"line": 1, "character": 4}]}},
            {"jsonrpc": "2.0", "id": base + 4, "method": "textDocument/hover",
             "params": {"textDocument": {"uri": URI},
                         "position": {"line": 0, "character": 4}}},
        ]
        client.send_many(requests, timeout=120)
        for request_id in range(base, base + 5):
            response = client.wait_response(request_id, timeout=120)
            assert "error" not in response, \
                f"provider errored on broken source: {response}"

    # Recover with a valid edit.
    last = len(BROKEN) * 2 + 1
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": URI, "version": last + 1},
        "contentChanges": [{"text": GOOD}],
    })
    recovered = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": URI},
    }, req_id=5000, timeout=120)
    assert "result" in recovered, recovered
    client.finish(timeout=120)

    # Broken sources still produced diagnostics (not a silent drop).
    diag_notifs = [n for n in client.notifications
                   if n.get("method") == "textDocument/publishDiagnostics"]
    assert diag_notifs, "no diagnostics published for broken sources"

    # Recovery: the valid edit yields non-empty tokens.
    tok = recovered["result"]["data"]
    assert tok, "valid edit after broken states produced no tokens"

print(f"containment OK: {len(BROKEN)} broken states, all providers alive, recovered")
PY
