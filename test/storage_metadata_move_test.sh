#!/usr/bin/env bash
# D04: live document metadata may move when the slot darray grows. Previously
# analyzed documents must retain valid source and analysis spans afterwards.
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
uri_for = lambda i: f"file:///metadata-move-{i}.elisa"


def source(i):
    return f"def keep{i}() -> void:\n    local{i}: i64 = {i}\n    pass\n"


def notify_open(client, i, version=1):
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri_for(i),
            "languageId": "Elisa",
            "version": version,
            "text": source(i),
        }
    })


def stats(client):
    response = client.request("$/elisa/stats", {}, timeout=30)
    assert "result" in response, response
    return response["result"]


def check_document(client, i, expected_name=None):
    expected_name = expected_name or f"keep{i}"
    uri = uri_for(i)

    symbols = client.request("textDocument/documentSymbol", {
        "textDocument": {"uri": uri},
    }, timeout=30)
    assert "result" in symbols, symbols
    names = [item["name"] for item in symbols["result"]]
    assert expected_name in names, (uri, expected_name, names)

    hover = client.request("textDocument/hover", {
        "textDocument": {"uri": uri},
        "position": {"line": 0, "character": 5},
    }, timeout=30)
    assert "result" in hover and hover["result"], (uri, hover)
    assert hover["result"]["contents"]["value"] == f"```elisa\ndef {expected_name}() -> void:\n```", hover

    selection = client.request("textDocument/selectionRange", {
        "textDocument": {"uri": uri},
        "positions": [{"line": 1, "character": 5}],
    }, timeout=30)
    assert "result" in selection and len(selection["result"]) == 1, (uri, selection)
    outer = selection["result"][0]
    assert outer["range"]["start"]["line"] == 1, (uri, outer)
    assert outer["parent"]["range"]["start"]["line"] == 1, (uri, outer)
    assert outer["parent"]["parent"]["range"]["start"]["line"] == 0, (uri, outer)


with LspSession(srv, startup_timeout=15, request_timeout=30, teardown_timeout=10) as client:
    initialized = client.initialize({"capabilities": {}}, timeout=30)
    assert "result" in initialized, initialized

    notify_open(client, 0)
    first = stats(client)
    initial_capacity = first["documents_capacity"]
    assert first["open"] == 1 and first["documents"] == 1, first
    assert initial_capacity > 0, first

    # Keep every analyzed document alive while appending until the slot array
    # demonstrably grows. The generous ceiling catches accidental inability to
    # trigger movement without making the test depend on a particular growth
    # factor.
    opened = 1
    grown = first
    while grown["documents_capacity"] == initial_capacity and opened < 129:
        notify_open(client, opened)
        opened += 1
        grown = stats(client)
    assert grown["documents_capacity"] > initial_capacity, {
        "initial": first, "after_opening": opened, "latest": grown,
    }
    assert opened > initial_capacity, (first, grown)
    assert grown["open"] == opened and grown["documents"] == opened, grown

    # Exercise old, middle, and newest slots after reallocation. These providers
    # read the retained source, symbols, hover summary, and line-index spans.
    indices = sorted({0, opened // 2, opened - 1})
    for i in indices:
        check_document(client, i)

    # Free an interior slot and reuse it while other moved entries stay live.
    recycled = opened // 2
    client.notify("textDocument/didClose", {"textDocument": {"uri": uri_for(recycled)}})
    replacement = f"def replaced{recycled}() -> void:\n    pass\n"
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri_for(recycled),
            "languageId": "Elisa",
            "version": 1,
            "text": replacement,
        }
    })
    check_document(client, recycled, f"replaced{recycled}")
    for i in sorted({0, opened - 1}):
        check_document(client, i)

    final = stats(client)
    assert final["documents_capacity"] == grown["documents_capacity"], (grown, final)
    assert final["open"] == opened and final["documents"] == opened, final
    client.finish(timeout=30)

print(f"metadata move OK: live slot capacity grew {initial_capacity}->{grown['documents_capacity']} with {opened} open documents; cached providers and slot reuse remained valid")
PY
