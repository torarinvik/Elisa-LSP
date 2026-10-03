#!/usr/bin/env bash
# Regression coverage for the session document store. The LSP must keep each
# URI's decoded snapshot independent: a request for B must never tokenize A,
# an edit to A must not change B, and closing A must invalidate only A.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import json
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession, frame_bytes

srv = sys.argv[1]
uri_a = "file:///multi-a.elisa"
uri_b = "file:///multi-b.elisa"
text_a = "def one() -> void:\n    x: i64 = 1\n"
text_b = "def two() -> void:\n    y: i64 = 2\n"
edited_a = "def broken() -> void:\n    z: bool = 3\n"


def open_document(client, uri, text, version=1):
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "elisa",
            "version": version,
            "text": text,
        },
    })


def change_document(client, uri, text, version):
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": version},
        "contentChanges": [{"text": text}],
    })


def tokens(client, uri):
    response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    }, timeout=45)
    assert "result" in response, response
    return response["result"]


def tokens_with_alternate_json_escaping(client, uri):
    # JSON permits equivalent escaping forms. This asks for A with every URI
    # slash escaped, so the cache must compare decoded URI bytes, not the raw
    # representation inside the request message.
    uri_literal = json.dumps(uri).replace("/", "\\/")
    body = (
        '{"jsonrpc":"2.0","id":102,"method":"textDocument/semanticTokens/full",'
        '"params":{"textDocument":{"uri":%s}}}'
    ) % uri_literal
    client.send(frame_bytes(body.encode("utf-8")), timeout=45)
    response = client.wait_response(102, timeout=45)
    assert "result" in response, response
    return response["result"]


with LspSession(srv, request_timeout=45, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized

    open_document(client, uri_a, text_a)
    open_document(client, uri_b, text_b)
    tokens_a = tokens_with_alternate_json_escaping(client, uri_a)
    tokens_b = tokens(client, uri_b)
    change_document(client, uri_a, edited_a, 2)
    tokens_b_after_a_edit = tokens(client, uri_b)
    tokens_a_after_edit = tokens(client, uri_a)
    client.notify("textDocument/didClose", {
        "textDocument": {"uri": uri_a},
    })
    tokens_a_after_close = tokens(client, uri_a)

    # Keep the test's independent semantic assertions on decoded JSON values.
    if not tokens_a.get("data") or not tokens_b.get("data"):
        raise SystemExit("both opened documents must return semantic tokens")
    if tokens_b_after_a_edit != tokens_b:
        raise SystemExit("editing document A changed document B's token result")
    if not tokens_a_after_edit.get("data") or tokens_a_after_edit == tokens_a:
        raise SystemExit("editing document A did not refresh A's token result")
    if tokens_a_after_close != {"data": []}:
        raise SystemExit("closed document A still returned stale semantic tokens")

    client.finish(timeout=45)

print("multi-document OK: isolated snapshots, edits, and close invalidation")
PY
