#!/usr/bin/env bash
# F01: general hover — declarations and param/local bindings resolve under the
# cursor with the correct precedence, exact range, cursor boundary policy,
# markdown/plaintext kinds, and null for unknown identifiers/keywords.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession, frame_bytes

srv = sys.argv[1]
DOC = ('def alpha(x: i64) -> i64:\n'      # 0
       '    local: i64 = x\n'             # 1
       '    return local\n\n'             # 2
       'struct Point:\n'                   # 3
       '    x: i64\n')                    # 4

def hover(line, ch, caps=None):
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps or {}})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": "file:///g.elisa",
                "languageId": "Elisa",
                "version": 1,
                "text": DOC,
            }
        })
        response = client.request("textDocument/hover", {
            "textDocument": {"uri": "file:///g.elisa"},
            "position": {"line": line, "character": ch},
        }, req_id=9)
        assert "result" in response, response
        result = response["result"]
        client.finish(timeout=30)
        return result

# 1. A top-level function shows its declaration and declared return type.
r = hover(0, 5)
assert r and r["contents"]["value"] == "def alpha -> i64", r
assert r["contents"]["kind"] == "markdown", r["contents"]["kind"]
rg = r["range"]
assert (rg["start"]["line"], rg["start"]["character"]) == (0, 4), rg
assert (rg["end"]["line"], rg["end"]["character"]) == (0, 9), rg

# 2. A parameter and a local (declaration and reference) win over any symbol.
assert hover(0, 10)["contents"]["value"] == "(parameter) x"
assert hover(1, 5)["contents"]["value"] == "(local) local"
assert hover(2, 11)["contents"]["value"] == "(local) local"
# An oversized character clamps to the valid line end, where the cursor
# boundary rule selects the final identifier.
assert hover(2, 999)["contents"]["value"] == "(local) local"
assert hover(2, 999, {"general": {"positionEncodings": ["utf-8"]}})["contents"]["value"] == "(local) local"

# Exact spans distinguish a parameter read from a same-spelling local
# declaration on the same line; a (line, name) lookup cannot do this.
SHADOW_DOC = ('def shadow(p: i64) -> i64:\n'
              '    p: i64 = p\n'
              '    return p\n')
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": "file:///shadow.elisa", "languageId": "Elisa", "version": 1, "text": SHADOW_DOC}
    })
    local_decl = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///shadow.elisa"}, "position": {"line": 1, "character": 4}
    }, req_id=10)["result"]
    param_read = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///shadow.elisa"}, "position": {"line": 1, "character": 13}
    }, req_id=11)["result"]
    local_read = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///shadow.elisa"}, "position": {"line": 2, "character": 11}
    }, req_id=12)["result"]
    assert local_decl["contents"]["value"] == "(local) p", local_decl
    assert param_read["contents"]["value"] == "(parameter) p", param_read
    assert local_read["contents"]["value"] == "(local) p", local_read
    assert local_decl["range"] != param_read["range"], (local_decl, param_read)
    client.finish(timeout=30)

# 3. A struct name shows its category.
assert hover(4, 8)["contents"]["value"] == "struct Point"

# 4. Unknown identifiers and keywords hover null (the loop-header fallback is
#    separate and not triggered here).
assert hover(0, 0) is None, hover(0, 0)

# 5. Cursor at the END of a token still hovers it (boundary policy).
assert hover(0, 9)["contents"]["value"] == "def alpha -> i64", hover(0, 9)

# 6. plaintext clients get plaintext content.
r = hover(0, 5, {"textDocument":{"hover":{"contentFormat":["plaintext"]}}})
assert r["contents"]["kind"] == "plaintext", r["contents"]

# 7. Unknown/closed documents hover null (no cross-URI leakage).
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    response = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///absent.elisa"},
        "position": {"line": 0, "character": 0},
    }, req_id=9)
    assert "result" in response and response["result"] is None, response
    client.finish(timeout=30)

# Hover uses the same strict LSP Position validator as the other point
# providers. Malformed positions must fail as InvalidParams; a well-formed
# position on a nonexistent line is a valid query with no result.
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": "file:///g.elisa",
            "languageId": "Elisa",
            "version": 1,
            "text": DOC,
        }
    })

    malformed = [
        None,  # params omitted entirely
        {"textDocument": {"uri": "file:///g.elisa"}},  # missing position
        {"textDocument": {"uri": "file:///g.elisa"}, "position": None},
        {"textDocument": {"uri": "file:///g.elisa"}, "position": []},
        {"textDocument": {"uri": "file:///g.elisa"}, "position": {"character": 0}},
        {"textDocument": {"uri": "file:///g.elisa"}, "position": {"line": 0}},
        {"textDocument": {"uri": "file:///g.elisa"}, "position": {"line": -1, "character": 0}},
        {"textDocument": {"uri": "file:///g.elisa"}, "position": {"line": 0, "character": -1}},
        {"textDocument": {"uri": "file:///g.elisa"}, "position": {"line": 0.5, "character": 0}},
        {"textDocument": {"uri": "file:///g.elisa"}, "position": {"line": 0, "character": 1.5}},
        {"textDocument": {"uri": "file:///g.elisa"}, "position": {"line": True, "character": 0}},
    ]
    for req_id, params in enumerate(malformed, start=100):
        response = client.request("textDocument/hover", params, req_id=req_id)
        assert response.get("error", {}).get("code") == -32602, (req_id, response)

    # The object parser preserves duplicate keys so the validator can reject
    # them rather than silently choosing one coordinate.
    duplicate_bodies = [
        b'{"jsonrpc":"2.0","id":120,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///g.elisa"},"position":{"line":0,"line":0,"character":5}}}',
        b'{"jsonrpc":"2.0","id":121,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///g.elisa"},"position":{"line":0,"character":5},"position":{"line":0,"character":9}}}',
    ]
    for req_id, body in zip((120, 121), duplicate_bodies):
        client.send(frame_bytes(body))
        response = client.wait_response(req_id)
        assert response.get("error", {}).get("code") == -32602, (req_id, response)

    response = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///g.elisa"},
        "position": {"line": 99, "character": 0},
    }, req_id=122)
    assert response.get("result", "missing") is None, response
    client.finish(timeout=30)

print("general hover OK: declaration, precedence, range, boundary, malformed positions, kinds, null")
PY
