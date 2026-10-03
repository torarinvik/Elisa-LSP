#!/usr/bin/env bash
# J02 strict protocol numerics: fractional, overflowing, or wrong-typed
# version/position fields are rejected, never coerced (1.5 must not become 15).
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
GOOD = "def one() -> void:\n    x: i64 = 1\n"
BAD = "def broken() -> void:\n    z: bool = 3\n"
uri = "file:///num.elisa"


def open_good(client):
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": 1,
            "text": GOOD,
        }
    })


def tokens(client):
    response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    }, timeout=30)
    assert "result" in response, response
    return response["result"]


def invalid_change_frame(version_spelling):
    # Deliberately retain raw JSON number/string spellings that ordinary Python
    # object serialization would otherwise normalize or would not expose.
    body = ('{"jsonrpc":"2.0","method":"textDocument/didChange",'
            '"params":{"textDocument":{"uri":"%s","version":%s},'
            '"contentChanges":[{"text":%s}]}}' % (uri, version_spelling, json.dumps(BAD))).encode()
    return frame_bytes(body)


# 1. Malformed versions never mutate: fractional, huge, and wrong-typed
#    versions are dropped while the good text stays authoritative.
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    open_good(client)
    before = tokens(client)
    for bad_version in ("1.5", "99999999999999999999999", '"2"', "2147483648", "-2147483649"):
        client.send(invalid_change_frame(bad_version))
    after = tokens(client)
    client.finish(timeout=30)
assert after == before and before.get("data"), \
    f"malformed versions mutated: {after} vs {before}"

# 2. A later valid version still applies (no poisoning from the rejects above).
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    open_good(client)
    client.send(invalid_change_frame("1.5"))
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{"text": BAD}],
    })
    result = tokens(client)
    client.finish(timeout=30)
    notifs = list(client.notifications)
assert result and result.get("data"), "valid version after rejects must apply"
diags = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics"
         and n["params"]["uri"] == uri]
assert diags and len(diags[-1]["params"]["diagnostics"]) > 0, \
    "BAD text must surface diagnostics"

# 3. Invalid LSP positions are rejected, never coerced. A valid line beyond the
#    document remains a well-formed request and returns null.
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    open_good(client)
    for i, bad_line in enumerate(("2.5", '"1"', "99999999999999999999999", "2147483648", "-1")):
        body = ('{"jsonrpc":"2.0","id":%d,"method":"textDocument/hover",'
                '"params":{"textDocument":{"uri":"%s"},"position":{"line":%s,"character":0}}}'
                % (10 + i, uri, bad_line)).encode()
        client.send(frame_bytes(body))
    for request_id in (10, 11, 12, 13, 14):
        response = client.wait_response(request_id, timeout=30)
        assert response.get("error", {}).get("code") == -32602, \
            f"invalid position must be rejected, not coerced: id {request_id} -> {response}"
    out_of_document = client.request("textDocument/hover", {
        "textDocument": {"uri": uri},
        "position": {"line": 99, "character": 0},
    }, timeout=30)
    assert "result" in out_of_document and out_of_document["result"] is None, \
        f"valid line outside the document should return null: {out_of_document}"
    client.finish(timeout=30)

print("numerics OK: malformed integers rejected, never coerced; valid out-of-document hover is null")
PY
