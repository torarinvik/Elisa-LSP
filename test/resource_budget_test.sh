#!/usr/bin/env bash
# Q03/D04: private stats expose configured resource budgets and the current
# one-shot worker/cache policy, including retained-cost cache eviction.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

srv, root = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "test"))
from lsp_client import LspSession


os.environ.update(
    {
        "ELISA_LSP_MAX_HEADER_BYTES": "4096",
        "ELISA_LSP_MAX_HEADER_LINES": "8",
        "ELISA_LSP_MAX_BODY_BYTES": "32768",
        "ELISA_LSP_MAX_OPEN_SOURCE_BYTES": "2048",
        "ELISA_LSP_MAX_OPEN_DOCUMENTS": "4",
        "ELISA_LSP_MAX_OPEN_URI_BYTES": "512",
        "ELISA_LSP_MAX_DERIVED_CACHE_BYTES": "8192",
        "ELISA_LSP_WRITE_TIMEOUT_MS": "500",
        "ELISA_LSP_ANALYSIS_TIMEOUT_MS": "1000",
    }
)


def assert_budget_shape(stats, *, open_count, source_bytes, uri_bytes, cache_bytes=None):
    budgets = stats.get("budgets")
    assert isinstance(budgets, dict), stats
    assert set(budgets) == {"transport", "documents", "analysis", "cache"}, budgets

    transport = budgets["transport"]
    assert transport == {
        "max_header_bytes": 4096,
        "max_header_lines": 8,
        "max_body_bytes": 32768,
        "write_timeout_ms": 500,
    }, transport

    documents = budgets["documents"]
    assert documents["open"] == open_count, documents
    assert documents["open_limit"] == 4, documents
    assert documents["open_uri_bytes"] == uri_bytes, documents
    assert documents["open_uri_bytes_limit"] == 512, documents
    assert documents["open_source_bytes"] == source_bytes, documents
    assert documents["open_source_bytes_limit"] == 2048, documents

    analysis = budgets["analysis"]
    assert analysis == {
        "mode": "one_shot_worker",
        "queued": 0,
        "queue_capacity": 4,
        "in_flight": 0,
        "timeout_ms": 1000,
        "worker_packet_limit_bytes": 67108864,
    }, analysis

    cache = budgets["cache"]
    assert cache["aggregate_limit_bytes"] == 8192, cache
    assert cache["eviction"] == "lru_snapshot", cache
    assert cache["retained_bytes"] <= 8192, cache
    assert cache["evictions"] >= 0, cache
    assert cache["derived_bytes"] >= 0, cache
    if cache_bytes is not None:
        assert cache["derived_bytes"] == cache_bytes, (cache, cache_bytes)


uri = "file:///q03-budget.elisa"
text = "def budget_probe(x: i64) -> i64:\n    return x\n"
source_bytes = len(text.encode("utf-8"))
uri_bytes = len(uri.encode("utf-8"))

with LspSession(srv, startup_timeout=30, request_timeout=30, teardown_timeout=10) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized

    initial_stats = client.request("$/elisa/stats", {})["result"]
    assert_budget_shape(initial_stats, open_count=0, source_bytes=0, uri_bytes=0, cache_bytes=0)

    client.notify(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": uri,
                "languageId": "elisa",
                "version": 1,
                "text": text,
            }
        },
    )
    client.wait_notification(
        "textDocument/publishDiagnostics",
        predicate=lambda message: (
            message.get("params", {}).get("uri") == uri
            and message.get("params", {}).get("version") == 1
        ),
        timeout=30,
    )
    # Sample after the worker has committed the accepted snapshot.
    opened_stats = client.request("$/elisa/stats", {})["result"]
    assert_budget_shape(
        opened_stats,
        open_count=1,
        source_bytes=source_bytes,
        uri_bytes=uri_bytes * 2,
        cache_bytes=opened_stats["derived_cache_bytes"],
    )
    assert opened_stats["derived_cache_bytes"] > 0, opened_stats
    assert opened_stats["snapshots"]["ready"] == 1, opened_stats

    client.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
    closed_stats = client.request("$/elisa/stats", {})["result"]
    assert_budget_shape(closed_stats, open_count=0, source_bytes=0, uri_bytes=0, cache_bytes=0)
    assert closed_stats["snapshots"] == {
        "open": 0,
        "pending": 0,
        "ready": 0,
        "failed": 0,
    }, closed_stats

    assert client.finish(timeout=30) == 0

print("resource budgets OK: configured transport/document/worker limits and asynchronous queue/cache policy are observable")
PY
