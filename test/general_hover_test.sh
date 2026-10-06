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
       '    x: i64\n'                      # 4
       'enum Color:\n'                     # 5
       '    Blue\n'                        # 6
       '    Red\n'                         # 7
       'enum Other:\n'                     # 8
       '    Red\n')                        # 9

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

# 1. A uniquely identified top-level function shows its exact source signature,
# including parameter types and its return annotation.
r = hover(0, 5)
assert r and r["contents"]["value"] == "```elisa\ndef alpha(x: i64) -> i64:\n```", r
assert r["contents"]["kind"] == "markdown", r["contents"]["kind"]
rg = r["range"]
assert (rg["start"]["line"], rg["start"]["character"]) == (0, 4), rg
assert (rg["end"]["line"], rg["end"]["character"]) == (0, 9), rg

# 2. A parameter and a local (declaration and reference) win over any symbol,
#    and their explicit annotations follow the exact BindingId.
assert hover(0, 10)["contents"]["value"] == "(parameter) x: i64"
assert hover(1, 5)["contents"]["value"] == "(local) local: i64"
assert hover(2, 11)["contents"]["value"] == "(local) local: i64"
# An oversized character clamps to the valid line end, where the cursor
# boundary rule selects the final identifier.
assert hover(2, 999)["contents"]["value"] == "(local) local: i64"
assert hover(2, 999, {"general": {"positionEncodings": ["utf-8"]}})["contents"]["value"] == "(local) local: i64"

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
    assert local_decl["contents"]["value"] == "(local) p: i64", local_decl
    assert param_read["contents"]["value"] == "(parameter) p: i64", param_read
    assert local_read["contents"]["value"] == "(local) p: i64", local_read
    assert local_decl["range"] != param_read["range"], (local_decl, param_read)
    client.finish(timeout=30)

# 3. A struct name shows its category.
assert hover(4, 8)["contents"]["value"] == "struct Point"

# 4. A compiler-registered enum variant is shown only when its spelling has
# one owner in this analysis. Repeated spellings stay unresolved because the
# current frontend does not retain exact variant occurrence identities.
variant_hover = hover(7, 6)
assert variant_hover and variant_hover["contents"]["value"] == "enum Color.Blue", variant_hover
ambiguous_hover = hover(10, 6)
assert ambiguous_hover is None, ambiguous_hover

# If a unique variant spelling also names an ordinary declaration, neither
# cursor location can be resolved reliably from the current retained metadata.
COLLISION_DOC = "enum Color:\n    Blue\nconst Blue: i64 = 1\nconst Other: i64 = 2\n"
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": "file:///variant-collision.elisa", "languageId": "Elisa", "version": 1, "text": COLLISION_DOC}
    })
    variant_collision = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///variant-collision.elisa"}, "position": {"line": 1, "character": 6}
    }, req_id=13)["result"]
    const_collision = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///variant-collision.elisa"}, "position": {"line": 2, "character": 7}
    }, req_id=14)["result"]
    other_declaration = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///variant-collision.elisa"}, "position": {"line": 3, "character": 7}
    }, req_id=15)["result"]
    assert variant_collision is None, variant_collision
    assert const_collision is None, const_collision
    assert other_declaration["contents"]["value"] == "const Other", other_declaration
    client.finish(timeout=30)

# Overloaded declaration names have no single hover target even when every row
# shares a spelling, so neither declaration selects an arbitrary overload.
OVERLOADED_DOC = (
    "def overloaded() -> i64:\n"
    "    return 1\n"
    "def overloaded(value: i64) -> i64:\n"
    "    return value\n"
)
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": "file:///overloaded-hover.elisa", "languageId": "Elisa", "version": 1, "text": OVERLOADED_DOC}
    })
    first_overload = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///overloaded-hover.elisa"}, "position": {"line": 0, "character": 7}
    }, req_id=16)["result"]
    second_overload = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///overloaded-hover.elisa"}, "position": {"line": 2, "character": 7}
    }, req_id=17)["result"]
    assert first_overload is None, first_overload
    assert second_overload is None, second_overload
    client.finish(timeout=30)

# 5. Unknown identifiers and keywords hover null (the loop-header fallback is
#    separate and not triggered here).
assert hover(0, 0) is None, hover(0, 0)

# 6. Cursor at the END of a token still hovers it (boundary policy).
assert hover(0, 9)["contents"]["value"] == "```elisa\ndef alpha(x: i64) -> i64:\n```", hover(0, 9)

# 7. plaintext clients get plaintext content.
r = hover(0, 5, {"textDocument":{"hover":{"contentFormat":["plaintext"]}}})
assert r["contents"]["kind"] == "plaintext", r["contents"]
assert r["contents"]["value"] == "def alpha(x: i64) -> i64:", r["contents"]
parameter_plaintext = hover(0, 10, {"textDocument":{"hover":{"contentFormat":["plaintext"]}}})
assert parameter_plaintext["contents"]["kind"] == "plaintext", parameter_plaintext
assert parameter_plaintext["contents"]["value"] == "(parameter) x: i64", parameter_plaintext

# Nested declared types are preserved exactly through the compiler's retained
# BindingId rows, for both binder and reference occurrences.
TYPE_DOC = (
    "def typed(value: darray[i64]) -> darray[i64]:\n"
    "    local: darray[i64] = value\n"
    "    return local\n"
)
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": "file:///declared-types.elisa", "languageId": "Elisa", "version": 1, "text": TYPE_DOC}
    })
    def type_hover(line, character, req_id):
        return client.request("textDocument/hover", {
            "textDocument": {"uri": "file:///declared-types.elisa"},
            "position": {"line": line, "character": character},
        }, req_id=req_id)["result"]
    typed_parameter = type_hover(0, 13, 20)
    typed_local = type_hover(1, 5, 21)
    typed_local_read = type_hover(2, 11, 22)
    assert typed_parameter["contents"]["value"] == "(parameter) value: darray[i64]", typed_parameter
    assert typed_local["contents"]["value"] == "(local) local: darray[i64]", typed_local
    assert typed_local_read["contents"]["value"] == "(local) local: darray[i64]", typed_local_read
    client.finish(timeout=30)

# 8. Unknown/closed documents hover null (no cross-URI leakage).
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    response = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///absent.elisa"},
        "position": {"line": 0, "character": 0},
    }, req_id=9)
    assert "result" in response and response["result"] is None, response
    client.finish(timeout=30)

# Exact source headers preserve generics, defaults, and declared effects. A
# dynamic fence length keeps source text containing backticks inside Markdown.
SIGNATURE_DOC = (
    "def identity[T](value: T, count: i64 = 1) -> T can[Abort.Panic]:\n"
    "    return value\n"
    'def render(text: string = "```") -> string:\n'
    "    return text\n"
)
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": "file:///signature-hover.elisa", "languageId": "Elisa", "version": 1, "text": SIGNATURE_DOC}
    })
    identity = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///signature-hover.elisa"}, "position": {"line": 0, "character": 6}
    }, req_id=22)["result"]
    render = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///signature-hover.elisa"}, "position": {"line": 2, "character": 6}
    }, req_id=23)["result"]
    assert identity["contents"]["value"] == "```elisa\ndef identity[T](value: T, count: i64 = 1) -> T can[Abort.Panic]:\n```", identity
    assert render["contents"]["value"] == '````elisa\ndef render(text: string = "```") -> string:\n````', render
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
