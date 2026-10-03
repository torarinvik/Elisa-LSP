#!/usr/bin/env bash
# D04: aggregate accepted open-source bytes have a configurable admission cap.
# Equality is accepted; rejected opens allocate no slot/storage, and rejected
# changes preserve the old source, caches, and version.
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
source_budget = "ELISA_LSP_MAX_OPEN_SOURCE_BYTES"
budget = 64


def source(name):
    base = f"def {name}() -> void:\n    pass\n"
    assert len(base.encode("utf-8")) <= 32
    return base + "#" * (32 - len(base.encode("utf-8")))


def notify_open(client, uri, text, version=1):
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": version,
            "text": text,
        }
    })


def notify_change(client, uri, text, version):
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": version},
        "contentChanges": [{"text": text}],
    })


def stats(client):
    response = client.request("$/elisa/stats", {}, timeout=30)
    assert "result" in response, response
    result = response["result"]
    keys = (
        "documents", "documents_capacity", "open", "storage_bytes",
        "storage_capacity", "live_bytes", "dead_storage_bytes", "open_uri_bytes",
        "open_source_bytes", "derived_cache_bytes", "max_document_cache_bytes",
        "snapshots", "index_keys", "index_used", "index_capacity", "line_index", "analysis",
    )
    assert all(key in result for key in keys), result
    snapshots = result["snapshots"]
    assert result["storage_bytes"] == result["live_bytes"] + result["dead_storage_bytes"], result
    assert result["live_bytes"] == (
        result["open_uri_bytes"] + result["open_source_bytes"]
        + result["derived_cache_bytes"] + result["open"]
    ), result
    assert snapshots["open"] == result["open"], result
    return {key: result[key] for key in keys}


def symbol_names(client, uri):
    response = client.request("textDocument/documentSymbol", {
        "textDocument": {"uri": uri},
    }, timeout=30)
    assert "result" in response, response
    return [item["name"] for item in response["result"]]


uri_a = "file:///budget-a.elisa"
uri_b = "file:///budget-b.elisa"
uri_c = "file:///budget-c.elisa"
text_a = source("alpha")
text_b = source("bravo")
text_beta = source("beta")
text_c = source("charlie")
assert len(text_a.encode("utf-8")) == 32
assert len(text_b.encode("utf-8")) == 32
assert len(text_beta.encode("utf-8")) == 32
assert len(text_c.encode("utf-8")) == 32
assert len(text_a.encode("utf-8")) + len(text_b.encode("utf-8")) == budget

previous = os.environ.get(source_budget)
os.environ[source_budget] = str(budget)
try:
    with LspSession(srv, startup_timeout=30, request_timeout=30, teardown_timeout=15) as client:
        initialized = client.initialize({"capabilities": {}}, timeout=30)
        assert "result" in initialized, initialized

        # Both 32-byte documents fit exactly at the 64-byte aggregate limit.
        notify_open(client, uri_a, text_a)
        notify_open(client, uri_b, text_b)
        exact_limit = stats(client)
        assert (exact_limit["documents"], exact_limit["open"]) == (2, 2), exact_limit
        assert exact_limit["open_source_bytes"] == budget, exact_limit
        assert symbol_names(client, uri_a) == ["alpha"]
        assert symbol_names(client, uri_b) == ["bravo"]

        # A 1-byte third source would cross the cap. Rejection must precede
        # slot creation and storage mutation, including URI bytes.
        before_rejected_open = stats(client)
        notify_open(client, uri_c, "#")
        after_rejected_open = stats(client)
        assert after_rejected_open == before_rejected_open, (
            before_rejected_open, after_rejected_open
        )

        # The new text would exceed the aggregate cap by one byte. It must not
        # replace A or advance its version from 1 to 3.
        before_rejected_change = stats(client)
        notify_change(client, uri_a, text_a + "#", version=3)
        assert stats(client) == before_rejected_change
        assert symbol_names(client, uri_a) == ["alpha"]

        # Version 2 is newer than the still-accepted v1 and fits at equality.
        # Its acceptance proves the rejected v3 did not advance the version.
        notify_change(client, uri_a, text_beta, version=2)
        assert symbol_names(client, uri_a) == ["beta"]
        accepted_v2 = stats(client)
        assert (accepted_v2["documents"], accepted_v2["open"]) == (2, 2), accepted_v2
        assert accepted_v2["open_source_bytes"] == budget, accepted_v2

        # Closing B frees 32 bytes; the previously rejected C can now open at
        # equality while reusing the freed document slot.
        client.notify("textDocument/didClose", {"textDocument": {"uri": uri_b}})
        closed_b = stats(client)
        assert closed_b["open"] == 1, closed_b
        notify_open(client, uri_c, text_c)
        after_reuse = stats(client)
        assert (after_reuse["documents"], after_reuse["open"]) == (2, 2), after_reuse
        assert symbol_names(client, uri_c) == ["charlie"]
        client.finish(timeout=30)
finally:
    if previous is None:
        os.environ.pop(source_budget, None)
    else:
        os.environ[source_budget] = previous

print("open source budget OK: equality accepted, rejected updates transactional, and closed source budget reusable")
PY
