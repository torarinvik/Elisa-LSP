#!/usr/bin/env bash
# P03: validated initialize-time configuration and the inbound settings
# notification. The private stats probe exposes the effective timeout so the
# test checks application, invalid-value atomicity, and response-free
# notification behavior without relying on timing-sensitive analysis work.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRV="${1:-$ROOT/build/elisa-lsp}"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import json
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession, frame_bytes

server = sys.argv[1]


def stats(client):
    response = client.request("$/elisa/stats", {})
    assert "result" in response, response
    result = response["result"]
    timeout = result.get("configuration", {}).get("analysis_timeout_ms")
    assert isinstance(timeout, int), result
    return timeout


with LspSession(server, startup_timeout=10, request_timeout=10, teardown_timeout=5) as client:
    # A valid initialize-time override is applied before the session becomes
    # operational. The namespaced object leaves room for unrelated extensions.
    initialized = client.initialize({
        "capabilities": {},
        "initializationOptions": {
            "elisa": {"analysisTimeoutMs": 123},
            "otherExtension": {"someFlag": True},
        },
    })
    assert "result" in initialized, initialized
    assert stats(client) == 123

    # A valid settings notification updates the next-operation deadline and
    # remains response-free. A request barrier lets the reader observe all
    # preceding notifications without assuming notification ordering.
    before_messages = len(client.all_messages)
    client.notify("workspace/didChangeConfiguration", {
        "settings": {"elisa": {"analysisTimeoutMs": 234}},
    })
    assert stats(client) == 234
    assert len(client.all_messages) == before_messages + 1
    assert not any(message.get("method") == "workspace/didChangeConfiguration"
                   and "id" in message for message in client.all_messages)

    # Unknown settings are valid extension data and must not reset the current
    # effective value.
    client.notify("workspace/didChangeConfiguration", {
        "settings": {"otherExtension": {"analysisTimeoutMs": 999999}},
    })
    assert stats(client) == 234
    client.notify("workspace/didChangeConfiguration", {
        "settings": {"analysisTimeoutMs": 345},
    })
    assert stats(client) == 234

    # Out-of-range recognized values are malformed notifications. They produce
    # no response and leave the previously accepted setting unchanged.
    client.notify("workspace/didChangeConfiguration", {
        "settings": {"elisa": {"analysisTimeoutMs": 99}},
    })
    assert stats(client) == 234

    # Escaped-equivalent duplicate keys are rejected by decoded-key counting,
    # before the update can mutate the session.
    duplicate = (
        b'{"jsonrpc":"2.0","method":"workspace/didChangeConfiguration",'
        b'"params":{"settings":{"elisa":{"analysisTimeoutMs":250,'
        b'"analysisTimeout\\u004ds":260}}}}'
    )
    client.send(frame_bytes(duplicate))
    assert stats(client) == 234

    # The settings member is required by DidChangeConfigurationParams. A
    # malformed notification is logged and ignored, still without a response.
    client.notify("workspace/didChangeConfiguration", {})
    assert stats(client) == 234

    # Notifications must not carry IDs. The central envelope validator returns
    # exactly one InvalidRequest for the malformed request-shaped variant.
    with_id = client.request(
        "workspace/didChangeConfiguration",
        {"settings": {"elisa": {"analysisTimeoutMs": 345}}},
        req_id=700,
    )
    assert with_id.get("error", {}).get("code") == -32600, with_id
    assert stats(client) == 234

    client.finish(timeout=10)

# Invalid initialize options do not consume the one initialize attempt. A
# corrected initialize on the same connection can still complete normally.
with LspSession(server, startup_timeout=10, request_timeout=10, teardown_timeout=5) as client:
    invalid = client.request(
        "initialize",
        {"capabilities": {}, "initializationOptions": {
            "elisa": {"analysisTimeoutMs": 300001},
        }},
    )
    assert invalid.get("error", {}).get("code") == -32602, invalid
    corrected = client.request(
        "initialize",
        {"capabilities": {}, "initializationOptions": {
            "elisa": {"analysisTimeoutMs": 300000},
        }},
    )
    assert "result" in corrected, corrected
    client.notify("initialized", {})
    assert stats(client) == 300000
    client.finish(timeout=10)

print("configuration OK: validated initialize options, settings updates, duplicate-key rejection, and response-free notifications")
PY
