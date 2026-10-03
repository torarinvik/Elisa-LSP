#!/usr/bin/env bash
# J02 writer invariant: source-derived hover text must not corrupt the response
# frame. A capture name holding `"` and `\` bytes (legal header text, hostile
# JSON) still yields parseable responses with the exact decoded value.
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
doc = (
    'def f(xs: darray[i64]) -> i64:\n'
    '    r: i64 =\n'
    '        for x in xs |a"b, c=d\\e| -> a:\n'
    '            r <- r + 1\n'
    '    return r\n'
)

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": "file:///esc-hover.elisa",
            "languageId": "Elisa",
            "version": 1,
            "text": doc,
        }
    })
    response = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///esc-hover.elisa"},
        "position": {"line": 2, "character": 20},
    }, req_id=9)
    assert "result" in response and response["result"] is not None, response
    value = response["result"]["contents"]["value"]
    assert 'a"b' in value, f"quote must survive escaped: {value!r}"
    assert "c" in value.split("accumulators:")[1], f"accumulator missing: {value!r}"
    client.finish(timeout=30)
    client.assert_no_stderr_errors()

print("hover escapes OK: hostile header text stays valid JSON with exact value")
PY
