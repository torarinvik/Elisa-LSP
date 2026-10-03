#!/usr/bin/env bash
# D04/U01: retained storage, document slots, URI index, and line indexes stay bounded.
# Repeated open/grow/close cycles reclaim dead reservations and content; URI
# churn reuses freed slots and does not retain one hash bucket per historical
# URI. The private `$/elisa/stats` probe exposes logical counts and darray
# backing capacities, which may retain high-water allocations after compaction.
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


def big(k):
    return "def f() -> void:\n" + ("    # " + "z" * 80 + "\n") * k


def notify_open(client, uri, text):
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": 1,
            "text": text,
        }
    })


def notify_change(client, uri, text, version=2):
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": version},
        "contentChanges": [{"text": text}],
    })


def notify_close(client, uri):
    client.notify("textDocument/didClose", {
        "textDocument": {"uri": uri},
    })


def stats(client):
    response = client.request("$/elisa/stats", {}, timeout=30)
    assert "result" in response, response
    result = response["result"]
    snapshots = result["snapshots"]
    assert result["storage_bytes"] == result["live_bytes"] + result["dead_storage_bytes"], result
    assert result["derived_cache_bytes"] <= result["live_bytes"], result
    assert result["max_document_cache_bytes"] <= result["derived_cache_bytes"], result
    assert result["snapshots"]["open"] == result["open"], result
    assert snapshots["pending"] + snapshots["ready"] + snapshots["failed"] == result["open"], result
    assert result["live_bytes"] == (
        result["open_uri_bytes"] + result["open_source_bytes"]
        + result["derived_cache_bytes"] + result["open"]
    ), result
    return result


URIS = ["file:///a.elisa", "file:///b.elisa", "file:///c.elisa"]
growth, churn = [], []
final = tokens = None

with LspSession(srv, startup_timeout=15, request_timeout=30, teardown_timeout=10) as client:
    initialized = client.initialize({"capabilities": {}}, timeout=30)
    assert "result" in initialized, initialized

    # Phase 1: escalating growth forces a fresh reservation each cycle; the
    # abandoned one is dead space until reclamation.
    for cycle in range(120):
        uri = URIS[cycle % 3]
        notify_open(client, uri, big(100))
        notify_change(client, uri, big(200 + cycle * 20))
        if cycle % 20 == 19:
            growth.append(stats(client))
        notify_close(client, uri)
    final = stats(client)

    # Phase 1b: repeatedly grow and shrink the same live snapshot. This is the
    # allocator pattern that used to strand one append-only reservation per
    # edit. The current flat-store compactor should keep post-message dead
    # bytes bounded and the backing reservation at its warmed high-water mark.
    alternating_uri = "file:///alternating-size.elisa"
    notify_open(client, alternating_uri, "def small() -> void:\n    pass\n")
    warmed_storage_capacity = final["storage_capacity"]
    alternating = []
    for cycle in range(24):
        is_large = cycle % 2 == 0
        text = big(1200) if is_large else "def small() -> void:\n    pass\n"
        notify_change(client, alternating_uri, text, version=cycle + 2)
        sample = stats(client)
        alternating.append(sample)
        assert sample["storage_bytes"] <= sample["live_bytes"] * 2 + 65536, \
            f"alternating edits retained dead flat-store bytes: {sample}"
        if is_large:
            assert sample["open_source_bytes"] > 65536, sample
    notify_close(client, alternating_uri)
    final = stats(client)

    # Phase 2: keep one document live while 2,000 distinct URIs churn through
    # the index. Sampling after close catches tombstones retained by old hashes
    # even when the slot table and flat storage are already compact.
    # A larger earlier span is closed before the sentinel remains live. The
    # line-index compactor must copy and rebase the sentinel's later span.
    prefix_uri = "file:///line-index-prefix.elisa"
    notify_open(client, prefix_uri, "# first\n# second\n# third\n# fourth\n# fifth\n")
    sentinel_uri = "file:///sentinel.elisa"
    notify_open(client, sentinel_uri, "def keep() -> void:\n    pass\n")
    notify_close(client, prefix_uri)
    sentinel_open = stats(client)
    assert sentinel_open["line_index"]["entries"] == 3, sentinel_open
    assert sentinel_open["line_index"]["cached_documents"] == 1, sentinel_open
    assert sentinel_open["line_index"]["stored_entries"] == 3, sentinel_open
    for i in range(2000):
        uri = f"file:///churn-{i}.elisa"
        notify_open(client, uri, f"def g{i}() -> void:\n    pass\n")
        notify_close(client, uri)
        churn.append(stats(client))
        if i % 250 == 0:
            keep_response = client.request("textDocument/semanticTokens/full", {
                "textDocument": {"uri": sentinel_uri},
            }, timeout=30)
            assert "result" in keep_response and keep_response["result"].get("data"), keep_response
            keep_selection = client.request("textDocument/selectionRange", {
                "textDocument": {"uri": sentinel_uri},
                "positions": [{"line": 1, "character": 5}],
            }, timeout=30)
            assert keep_selection.get("result"), keep_selection
            assert keep_selection["result"][0]["range"]["start"]["line"] == 1, keep_selection

    # Reopen an early URI while the sentinel remains open: compaction must keep
    # both collision chains and normal lookups intact.
    reopened_uri = "file:///churn-0.elisa"
    notify_open(client, reopened_uri, "def z() -> void:\n    pass\n")
    token_response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": reopened_uri},
    }, timeout=30)
    assert "result" in token_response, token_response
    tokens = token_response["result"]
    keep_selection = client.request("textDocument/selectionRange", {
        "textDocument": {"uri": sentinel_uri},
        "positions": [{"line": 1, "character": 5}],
    }, timeout=30)
    assert keep_selection.get("result"), keep_selection
    assert keep_selection["result"][0]["range"]["start"]["line"] == 1, keep_selection
    notify_close(client, sentinel_uri)
    notify_close(client, reopened_uri)
    all_closed = stats(client)
    assert all_closed["line_index"]["entries"] == 0, all_closed
    assert all_closed["line_index"]["cached_documents"] == 0, all_closed
    assert all_closed["line_index"]["stored_entries"] == 0, all_closed
    # A one-shot analysis worker adds a process boundary to each accepted
    # snapshot. Give the final shutdown request room to pass behind a full
    # 2,000-URI churn run on slower/debug hosts.
    client.finish(timeout=120)

assert growth, "no growth-phase samples"
for sample in growth:
    assert sample["documents"] <= 4, f"slot count must stay bounded: {sample}"
    assert sample["storage_capacity"] >= sample["storage_bytes"], sample
    assert sample["documents_capacity"] >= sample["documents"], sample
    assert sample["line_index"]["capacity_entries"] >= sample["line_index"]["stored_entries"], sample
    assert sample["line_index"]["stored_entries"] <= 1048576, sample
    assert sample["storage_bytes"] <= sample["live_bytes"] * 2 + 65536, \
        f"storage unbounded: {sample}"

assert len(alternating) == 24, alternating
assert all(sample["storage_capacity"] == warmed_storage_capacity for sample in alternating), \
    "alternating edits grew the warmed backing reservation: " + repr([
        sample["storage_capacity"] for sample in alternating
    ])

# After every document is closed, dead reservations and content are reclaimed.
assert final["open"] == 0, final
assert final["documents"] <= 4, final
assert final["storage_bytes"] < 4096, f"closed storage should be tiny: {final}"
assert final["storage_capacity"] >= final["storage_bytes"], final
assert final["documents_capacity"] >= final["documents"], final
assert final["line_index"]["entries"] == 0 and final["line_index"]["stored_entries"] == 0, final

# URI churn must reuse freed slots, not grow the table.
assert churn, "no churn samples"
churn_peak = max(sample["documents"] for sample in churn)
assert churn_peak <= 4, f"URI churn grew the slot table: peak {churn_peak}"
for sample in churn:
    assert sample["storage_capacity"] >= sample["storage_bytes"], sample
    assert sample["documents_capacity"] >= sample["documents"], sample
    assert sample["index_keys"] == 1, f"closed URI hashes remain indexed: {sample}"
    assert sample["index_used"] <= 16, f"URI churn accumulated dictionary tombstones: {sample}"
    assert sample["index_capacity"] <= 64, f"URI churn grew the index without live documents: {sample}"
    assert sample["line_index"]["capacity_entries"] >= sample["line_index"]["stored_entries"], sample
    assert sample["line_index"]["stored_entries"] <= 1048576, sample
assert sentinel_open["index_keys"] == 1, sentinel_open
assert all_closed["line_index"]["entries"] == 0, all_closed

# Correctness survives compaction and slot reuse.
assert tokens and tokens.get("data"), f"reopened URI after churn broke: {tokens}"

print(f"storage OK: logical buffer reclaimed to {final['storage_bytes']}B (backing capacity {final['storage_capacity']}B), URI and line-index churn stayed bounded, features survived compaction and rebasing")
PY
