#!/usr/bin/env bash
# D04: retained derived-result reservations obey the aggregate cost budget.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]
limit = 1024
os.environ["ELISA_LSP_MAX_DERIVED_CACHE_BYTES"] = str(limit)

source = (
    "def cache_eviction_probe(value: i64) -> i64:\n"
    "    return value\n"
)

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized

    for index in range(8):
        client.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": f"file:///cache-eviction-{index}.elisa",
                    "languageId": "elisa",
                    "version": 1,
                    "text": source,
                }
            },
        )

    # Hold each query until its accepted snapshot has been analyzed. The
    # workers are serialized, so checking stats immediately after the opens
    # would inspect only Pending snapshots before any derived cache exists.
    for index in range(8):
        response = client.request("textDocument/semanticTokens/full", {
            "textDocument": {"uri": f"file:///cache-eviction-{index}.elisa"},
        })
        token_result = response.get("result")
        assert isinstance(token_result, dict) and isinstance(token_result.get("data"), list), response

    stats = client.request("$/elisa/stats", {})["result"]
    cache = stats["budgets"]["cache"]
    assert cache["aggregate_limit_bytes"] == limit, cache
    assert cache["eviction"] == "lru_snapshot", cache
    assert cache["retained_bytes"] <= limit, cache
    assert cache["derived_bytes"] <= cache["retained_bytes"], cache
    assert cache["evictions"] > 0, stats

    for index in range(8):
        client.notify(
            "textDocument/didClose",
            {"textDocument": {"uri": f"file:///cache-eviction-{index}.elisa"}},
        )
    closed = client.request("$/elisa/stats", {})["result"]
    assert closed["budgets"]["cache"]["retained_bytes"] == 0, closed
    assert client.finish(timeout=30) == 0

print("cache eviction OK: aggregate retained-cost budget and LRU whole-snapshot policy enforced")
PY
