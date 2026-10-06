#!/usr/bin/env bash
# D04: bound live document records and canonical URI bytes before didOpen mutates state.
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
environment = {
    "ELISA_LSP_MAX_OPEN_DOCUMENTS": "2",
    "ELISA_LSP_MAX_OPEN_URI_BYTES": "128",
    "ELISA_LSP_MAX_OPEN_SOURCE_BYTES": "1",
}
previous = {key: os.environ.get(key) for key in environment}
os.environ.update(environment)


def uri(ch, count=23):
    return "untitled:" + ch * count


def notify_open(client, path, version=1):
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": path, "languageId": "Elisa", "version": version, "text": ""},
    })


def stats(client):
    response = client.request("$/elisa/stats", {}, timeout=30)
    assert "result" in response, response
    result = response["result"]
    required = (
        "documents", "documents_capacity", "open", "storage_bytes",
        "storage_capacity", "live_bytes", "index_keys", "index_used",
        "index_capacity", "open_uri_bytes", "open_document_limit",
        "open_source_bytes", "derived_cache_bytes", "max_document_cache_bytes",
        "dead_storage_bytes", "snapshots", "open_uri_bytes_limit",
    )
    assert all(key in result for key in required), result
    snapshots = result["snapshots"]
    assert result["storage_bytes"] == result["live_bytes"] + result["dead_storage_bytes"], result
    assert result["live_bytes"] == (
        result["open_uri_bytes"] + result["open_source_bytes"]
        + result["derived_cache_bytes"] + result["open"]
    ), result
    assert snapshots["open"] == result["open"], result
    return {key: result[key] for key in required}


uri_a = uri("a")
uri_b = uri("b")
uri_c = uri("c")
uri_too_long = uri("x", 24)
assert len(uri_a.encode()) == len(uri_b.encode()) == len(uri_c.encode()) == 32
assert len(uri_too_long.encode()) == 33

try:
    with LspSession(srv, startup_timeout=30, request_timeout=30, teardown_timeout=15) as client:
        initialized = client.initialize({"capabilities": {}}, timeout=30)
        assert "result" in initialized, initialized

        # Empty overlays prove the document and URI caps independently of the
        # source-only cap. Each retained URI has both canonical and original
        # spelling metadata, so two 32-byte URIs consume exactly 128 bytes.
        notify_open(client, uri_a)
        notify_open(client, uri_b)
        exact = stats(client)
        assert (exact["documents"], exact["open"], exact["open_uri_bytes"]) == (2, 2, 128), exact
        assert exact["open_source_bytes"] == 0, exact
        assert exact["open_document_limit"] == 2 and exact["open_uri_bytes_limit"] == 128, exact

        # A same-URI duplicate is a replacement lifetime, not a third open.
        notify_open(client, uri_a, version=2)
        duplicate = stats(client)
        assert (duplicate["documents"], duplicate["open"], duplicate["open_uri_bytes"]) == (2, 2, 128), duplicate
        assert duplicate["index_keys"] == 2, duplicate

        # The document-count rejection occurs before slot/index/storage changes.
        before_count_reject = stats(client)
        notify_open(client, uri_c)
        assert stats(client) == before_count_reject

        # Freeing B creates room for one document, but the 33-byte URI would
        # take the aggregate URI total over the exact 128-byte cap.
        client.notify("textDocument/didClose", {"textDocument": {"uri": uri_b}})
        one_open = stats(client)
        assert (one_open["open"], one_open["open_uri_bytes"]) == (1, 64), one_open
        before_uri_reject = stats(client)
        notify_open(client, uri_too_long)
        assert stats(client) == before_uri_reject

        # Equality is accepted and the closed document slot is reused.
        notify_open(client, uri_c)
        at_uri_limit = stats(client)
        assert (at_uri_limit["documents"], at_uri_limit["open"], at_uri_limit["open_uri_bytes"]) == (2, 2, 128), at_uri_limit
        assert at_uri_limit["documents_capacity"] == duplicate["documents_capacity"], (duplicate, at_uri_limit)

        # Unique-URI churn must not grow the slot array or index past the
        # bounded peak; existing open documents remain independently usable.
        stable_documents_capacity = at_uri_limit["documents_capacity"]
        stable_index_capacity = at_uri_limit["index_capacity"]
        churn_alphabet = "defghijklmnopqrstuvwxyz012345678"
        for i in range(32):
            churn_uri = uri(churn_alphabet[i])
            notify_open(client, churn_uri)
            client.notify("textDocument/didClose", {"textDocument": {"uri": churn_uri}})
        after_churn = stats(client)
        assert after_churn["open"] == 2 and after_churn["open_uri_bytes"] == 128, after_churn
        assert after_churn["documents"] == 2, after_churn
        assert after_churn["documents_capacity"] == stable_documents_capacity, after_churn
        assert after_churn["index_capacity"] == stable_index_capacity, after_churn

        client.notify("textDocument/didClose", {"textDocument": {"uri": uri_a}})
        client.notify("textDocument/didClose", {"textDocument": {"uri": uri_c}})
        drained = stats(client)
        assert (drained["open"], drained["open_uri_bytes"], drained["live_bytes"], drained["index_keys"]) == (0, 0, 0, 0), drained
        client.finish(timeout=30)
finally:
    for key, value in previous.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value

print("document metadata budget OK: open-count and URI equality, transactional rejection, duplicate replacement, slot reuse, and bounded churn")
PY
