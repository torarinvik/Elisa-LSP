#!/usr/bin/env bash
# P03: capability negotiation — encoding preference order, hover contentFormat,
# and safe defaults for absent/unknown capabilities.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession, frame_bytes

srv = sys.argv[1]
with open(os.path.join(sys.argv[2], "docs/semantic-token-schema.json"), encoding="utf-8") as source:
    token_schema = json.load(source)
with open(os.path.join(sys.argv[2], "project.json"), encoding="utf-8") as source:
    project = json.load(source)
EXPECTED_SERVER_VERSION = project["version"]
DOC = ('def f(name: i64) -> i64:\n'
       '    x: dstr = "héllo 🌍"\n'
       '    return name\n')
LOOP = ('def f(xs: darray[i64]) -> i64:\n'
        '    r: i64 =\n'
        '        for x in xs |acc = 0| -> acc:\n'
        '            acc <- acc + 1\n'
        '    return acc\n')


def session(caps, uri, text, extra=()):
    """Run one complete client session and return selected response results."""
    results = {}
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        server_info = initialized["result"].get("serverInfo")
        assert server_info == {"name": "elisa-lsp", "version": EXPECTED_SERVER_VERSION}, server_info
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": text,
            }
        })
        tokens = client.request("textDocument/semanticTokens/full", {
            "textDocument": {"uri": uri},
        }, req_id=100)
        assert "result" in tokens, tokens
        results[1] = initialized["result"]
        results[2] = tokens["result"]
        for result_id, request in extra:
            response = client.request(
                request["method"], request.get("params"), req_id=100 + result_id
            )
            assert "result" in response, response
            results[result_id] = response["result"]
        client.finish(timeout=30)
    return results


def session_raw_caps(caps_json, uri, text, extra=()):
    """Send raw initialize JSON to retain escaped capability spellings."""
    results = {}
    init_body = (
        b'{"jsonrpc":"2.0","id":700,"method":"initialize","params":{"capabilities":'
        + caps_json.encode("ascii") + b'}}'
    )
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        client.send(frame_bytes(init_body))
        initialized = client.wait_response(700, timeout=30)
        assert "result" in initialized, initialized
        server_info = initialized["result"].get("serverInfo")
        assert server_info == {"name": "elisa-lsp", "version": EXPECTED_SERVER_VERSION}, server_info
        # Raw initialization uses the same lifecycle ordering as initialize():
        # notify only after the response, then all work, then finish().
        client.notify("initialized", {})
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": text,
            }
        })
        tokens = client.request("textDocument/semanticTokens/full", {
            "textDocument": {"uri": uri},
        }, req_id=100)
        assert "result" in tokens, tokens
        results[1] = initialized["result"]
        results[2] = tokens["result"]
        for result_id, request in extra:
            response = client.request(
                request["method"], request.get("params"), req_id=100 + result_id
            )
            assert "result" in response, response
            results[result_id] = response["result"]
        client.finish(timeout=30)
    return results


def bslice(line, col, ln):
    raw = line.encode("utf-8")
    assert 0 <= col <= len(raw) and 0 <= ln and col + ln <= len(raw)
    return raw[col:col + ln].decode("utf-8")


def u16slice(line, col, ln):
    raw = line.encode("utf-16-le")
    assert 0 <= col <= len(raw) // 2 and 0 <= ln and col + ln <= len(raw) // 2
    return raw[col * 2:(col + ln) * 2].decode("utf-16-le")


def toks(data):
    out, line, col = [], 0, 0
    for i in range(0, len(data), 5):
        dl, dc, ln, tt, _ = data[i:i + 5]
        line += dl
        col = (col + dc) if dl == 0 else dc
        out.append((line, col, ln, tt))
    return out


def test_semantic_token_profiles():
    whole_document = {
        "method": "textDocument/semanticTokens/range",
        "params": {
            "textDocument": {"uri": "file:///profile.elisa"},
            "range": {"start": {"line": 0, "character": 0},
                      "end": {"line": 99, "character": 0}},
        },
    }
    source = ('def profile(arg: i64) -> i64:\n'
              '    local: i64 = 7\n'
              '    return arg\n')

    # Omitted semanticTokens retains the historical custom names and indices.
    legacy = session({}, "file:///profile.elisa", source, [(3, whole_document)])
    assert legacy[1]["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"] == token_schema["legend"]
    assert legacy[3]["data"] == legacy[2]["data"], "legacy whole-range result diverged from full result"

    # An explicitly complete custom list opts into the same stable wire ABI,
    # independent of the order in which the client lists those names.
    custom_caps = {"textDocument": {"semanticTokens": {"tokenTypes": list(reversed(token_schema["legend"]))}}}
    explicit = session(custom_caps, "file:///profile.elisa", source, [(3, whole_document)])
    assert explicit[1]["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"] == token_schema["legend"]
    assert explicit[2]["data"] == legacy[2]["data"], "explicit custom legend changed cached indices"
    assert explicit[3]["data"] == explicit[2]["data"], "custom whole-range result diverged from full result"

    # Standard and partial clients receive only supported standard categories.
    # The schema defines the custom-to-standard mapping; unsupported categories
    # disappear while later token positions and deltas remain correct.
    offered = ["function", "type", "number", "string", "parameter", "variable", "keyword"]
    generic_caps = {"textDocument": {"semanticTokens": {"tokenTypes": offered}}}
    generic = session(generic_caps, "file:///profile.elisa", source, [(3, whole_document)])
    generic_legend = generic[1]["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"]
    assert generic_legend and set(generic_legend) <= set(offered), generic_legend
    custom_decoded = toks(legacy[2]["data"])
    fallback_index = {name: index for index, name in enumerate(generic_legend)}
    expected = []
    for line, col, length, custom_index in custom_decoded:
        custom_name = token_schema["legend"][custom_index]
        standard_name = token_schema["standard_fallback"][custom_name]
        if standard_name in fallback_index:
            expected.append((line, col, length, fallback_index[standard_name]))
    actual = toks(generic[2]["data"])
    assert actual == expected, f"standard fallback mismatch:\nactual={actual}\nexpected={expected}"
    assert all(0 <= token_type < len(generic_legend) for _, _, _, token_type in actual), generic_legend
    assert generic[3]["data"] == generic[2]["data"], "standard whole-range result diverged from full result"

    # A narrow partial legend still maps usable classes and omits every class
    # which the client did not offer.
    partial = session(
        {"textDocument": {"semanticTokens": {"tokenTypes": ["function", "number"]}}},
        "file:///profile.elisa", source, [(3, whole_document)],
    )
    partial_legend = partial[1]["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"]
    assert partial_legend == ["number", "function"], partial_legend
    assert partial[3]["data"] == partial[2]["data"]
    assert all(0 <= token_type < len(partial_legend) for _, _, _, token_type in toks(partial[2]["data"]))


def test_malformed_semantic_token_capabilities():
    malformed = [
        b'{"textDocument":{"semanticTokens":{"tokenTypes":"type"}}}',
        b'{"textDocument":{"semanticTokens":{"tokenTypes":["type",7]}}}',
        b'{"textDocument":{"semanticTokens":{"tokenTypes":["type","type"]}}}',
        b'{"textDocument":{"semanticTokens":{"tokenTypes":["type","ty\\u0070e"]}}}',
        b'{"textDocument":{"semanticTokens":{"tokenTypes":[],"token\\u0054ypes":[]}}}',
    ]
    for capabilities in malformed:
        initialize = (b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":'
                      + capabilities + b'}}')
        wire = frame_bytes(initialize) + frame_bytes(b'{"jsonrpc":"2.0","method":"exit"}')
        process = subprocess.run([srv], input=wire, capture_output=True, timeout=15)
        assert process.returncode == 1, (capabilities, process.returncode, process.stderr)
        separator = process.stdout.find(b"\r\n\r\n")
        assert separator >= 0, (capabilities, process.stdout)
        header = process.stdout[:separator].split(b"\r\n")
        length = int(next(line.split(b":", 1)[1].strip() for line in header
                          if line.lower().startswith(b"content-length:")))
        response = json.loads(process.stdout[separator + 4:separator + 4 + length])
        assert response.get("id") == 1 and response.get("error", {}).get("code") == -32602, response


def test_malformed_workspace_edit_capabilities():
    malformed = [
        b'{"workspace":true}',
        b'{"workspace":{},"work\\u0073pace":{}}',
        b'{"workspace":{"workspaceEdit":[]}}',
        b'{"workspace":{"workspaceEdit":{"documentChanges":"true"}}}',
        b'{"workspace":{"workspaceEdit":{"documentChanges":true,"documentChanges":false}}}',
        b'{"workspace":{"workspaceEdit":{"documentChanges":true,"document\\u0043hanges":false}}}',
    ]
    for capabilities in malformed:
        initialize = (b'{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":'
                      + capabilities + b'}}')
        wire = frame_bytes(initialize) + frame_bytes(b'{"jsonrpc":"2.0","method":"exit"}')
        process = subprocess.run([srv], input=wire, capture_output=True, timeout=15)
        assert process.returncode == 1, (capabilities, process.returncode, process.stderr)
        separator = process.stdout.find(b"\r\n\r\n")
        assert separator >= 0, (capabilities, process.stdout)
        header = process.stdout[:separator].split(b"\r\n")
        length = int(next(line.split(b":", 1)[1].strip() for line in header
                          if line.lower().startswith(b"content-length:")))
        response = json.loads(process.stdout[separator + 4:separator + 4 + length])
        assert response.get("id") == 2 and response.get("error", {}).get("code") == -32602, response


def test_malformed_completion_kind_capabilities():
    malformed = [
        b'{"textDocument":{"completion":true}}',
        b'{"textDocument":{"completion":{"completionItemKind":[]}}}',
        b'{"textDocument":{"completion":{"completionItemKind":{"valueSet":"6"}}}}',
        b'{"textDocument":{"completion":{"completionItemKind":{"valueSet":[0]}}}}',
        b'{"textDocument":{"completion":{"completionItemKind":{"valueSet":[26]}}}}',
        b'{"textDocument":{"completion":{"completionItemKind":{"valueSet":[6.5]}}}}',
        b'{"textDocument":{"completion":{"completionItemKind":{"valueSet":[6,"x"]}}}}',
        b'{"textDocument":{"completion":{"completionItemKind":{"valueSet":[6,6]}}}}',
        b'{"textDocument":{"completion":{"completionItemKind":{"valueSet":[],"value\\u0053et":[6]}}}}',
        b'{"textDocument":{"completion":{"completionItem":true}}}',
        b'{"textDocument":{"completion":{"completionItem":{"snippetSupport":"true"}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"snippetSupport":1}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"snippetSupport":true,"snippetSupport":false}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"snippetSupport":true,"snippet\\u0053upport":false}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"insertReplaceSupport":"true"}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"insertReplaceSupport":true,"insertReplaceSupport":false}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"insertReplaceSupport":true,"insertReplace\\u0053upport":false}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"commitCharactersSupport":"true"}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"commitCharactersSupport":true,"commitCharactersSupport":false}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"commitCharactersSupport":true,"commitCharacters\\u0053upport":false}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"labelDetailsSupport":"true"}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"labelDetailsSupport":true,"labelDetailsSupport":false}}}}',
        b'{"textDocument":{"completion":{"completionItem":{"labelDetailsSupport":true,"labelDetails\\u0053upport":false}}}}',
        b'{"textDocument":{"definition":{"linkSupport":"true"}}}',
        b'{"textDocument":{"definition":{"linkSupport":true,"linkSupport":false}}}',
        b'{"textDocument":{"definition":{"linkSupport":true,"link\\u0053upport":false}}}',
        b'{"textDocument":{"definition":{"linkSupport":true},"definition":{}}}',
        b'{"textDocument":{"definition":{"linkSupport":true},"definitio\\u006e":{}}}',
    ]
    for capabilities in malformed:
        initialize = (b'{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"capabilities":'
                      + capabilities + b'}}')
        wire = frame_bytes(initialize) + frame_bytes(b'{"jsonrpc":"2.0","method":"exit"}')
        process = subprocess.run([srv], input=wire, capture_output=True, timeout=15)
        assert process.returncode == 1, (capabilities, process.returncode, process.stderr)
        separator = process.stdout.find(b"\r\n\r\n")
        assert separator >= 0, (capabilities, process.stdout)
        header = process.stdout[:separator].split(b"\r\n")
        length = int(next(line.split(b":", 1)[1].strip() for line in header
                          if line.lower().startswith(b"content-length:")))
        response = json.loads(process.stdout[separator + 4:separator + 4 + length])
        assert response.get("id") == 3 and response.get("error", {}).get("code") == -32602, response


test_semantic_token_profiles()
test_malformed_semantic_token_capabilities()
test_malformed_workspace_edit_capabilities()
test_malformed_completion_kind_capabilities()


lines = DOC.split("\n")
# 1. utf-8 session: advertised, byte columns/lengths.
r = session({"general": {"positionEncodings": ["utf-8"]}}, "file:///c8.elisa", DOC)
assert r[1]["capabilities"].get("positionEncoding") == "utf-8", r[1]["capabilities"].get("positionEncoding")
strtok = [t for t in toks(r[2]["data"]) if t[0] == 1 and t[3] == 11]
assert len(strtok) == 1, strtok
assert (strtok[0][1], strtok[0][2]) == (14, 13), f"utf-8 bytes expected: {strtok[0]}"
assert bslice(lines[1], 14, 13) == '"héllo 🌍"', "byte slice must decode"

# The client decodes JSON escapes before capability matching. A raw escaped
# spelling must negotiate exactly like its ordinary JSON string value.
r = session_raw_caps(r'{"general":{"positionEncodings":["utf-\u0038"]}}',
                     "file:///c8-escaped.elisa", DOC)
assert r[1]["capabilities"].get("positionEncoding") == "utf-8", r[1]["capabilities"]
strtok = [t for t in toks(r[2]["data"]) if t[0] == 1 and t[3] == 11]
assert len(strtok) == 1 and strtok[0][1:3] == (14, 13), strtok

# 2. default session: no positionEncoding field, UTF-16 units.
r = session({}, "file:///c16.elisa", DOC)
assert "positionEncoding" not in r[1]["capabilities"], r[1]["capabilities"].get("positionEncoding")
assert "renameProvider" not in r[1]["capabilities"], r[1]["capabilities"]
strtok = [t for t in toks(r[2]["data"]) if t[0] == 1 and t[3] == 11]
assert (strtok[0][1], strtok[0][2]) == (14, 10), f"utf-16 units expected: {strtok[0]}"
assert u16slice(lines[1], 14, 10) == '"héllo 🌍"'

# 3. preference order: ["utf-16","utf-8"] stays utf-16; unknown-only falls back.
r = session({"general": {"positionEncodings": ["utf-16", "utf-8"]}}, "file:///c16b.elisa", DOC)
assert "positionEncoding" not in r[1]["capabilities"]
strtok = [t for t in toks(r[2]["data"]) if t[0] == 1 and t[3] == 11]
assert (strtok[0][1], strtok[0][2]) == (14, 10)
r = session({"general": {"positionEncodings": ["utf-32"]}}, "file:///c32.elisa", DOC)
assert "positionEncoding" not in r[1]["capabilities"]
strtok = [t for t in toks(r[2]["data"]) if t[0] == 1 and t[3] == 11]
assert (strtok[0][1], strtok[0][2]) == (14, 10)

# 4. hover kind follows contentFormat; markdown is the default.
hover = {"jsonrpc": "2.0", "method": "textDocument/hover",
         "params": {"textDocument": {"uri": "file:///h.elisa"},
                    "position": {"line": 2, "character": 20}}}
r = session({"textDocument": {"hover": {"contentFormat": ["plaintext"]}}},
            "file:///h.elisa", LOOP, [(3, hover)])
assert r[3]["contents"]["kind"] == "plaintext", r[3]
r = session_raw_caps(r'{"textDocument":{"hover":{"contentFormat":["plaintext","mark\u0064own"]}}}',
                     "file:///h-escaped.elisa", LOOP,
                     [(3, dict(hover, params={**hover["params"], "textDocument": {"uri": "file:///h-escaped.elisa"}}))])
assert r[3]["contents"]["kind"] == "markdown", r[3]
r = session({}, "file:///h2.elisa", LOOP,
            [(3, dict(hover, params={**hover["params"], "textDocument": {"uri": "file:///h2.elisa"}}))])
assert r[3]["contents"]["kind"] == "markdown", r[3]

# 5. diagnostics follow the negotiated units past non-ASCII content.
ERR = 'def f() -> void:\n    z: i64 = "é" + nope_undefined\n'


def diag_session(caps):
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        uri = "file:///e.elisa"
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": ERR,
            }
        })
        notification = client.wait_notification(
            "textDocument/publishDiagnostics",
            predicate=lambda message: message.get("params", {}).get("uri") == uri,
            timeout=30,
        )
        diags = notification["params"]["diagnostics"]
        stderr = client.stderr_text()
        client.finish(timeout=30)
        return diags, stderr


d8 = diag_session({"general": {"positionEncodings": ["utf-8"]}})[0]
d16 = diag_session({})[0]
u8 = [d for d in d8 if "nope_undefined" in d["message"]][0]["range"]
u16 = [d for d in d16 if "nope_undefined" in d["message"]][0]["range"]
# The latest frontend supplies the exact unresolved identifier span. UTF-8
# counts the preceding `é` as two bytes; UTF-16 counts it as one code unit.
assert (u8["start"]["character"], u8["end"]["character"]) == (20, 34), u8
assert (u16["start"]["character"], u16["end"]["character"]) == (19, 33), u16
assert bslice(ERR.split("\n")[1], 0, 34) and u16slice(ERR.split("\n")[1], 0, 33)

rename_caps = {"workspace": {"workspaceEdit": {"documentChanges": True}}}
r = session(rename_caps, "file:///rename-cap.elisa", DOC)
assert r[1]["capabilities"].get("renameProvider") == {"prepareProvider": True}, r[1]["capabilities"]

print("capabilities OK: encoding order, byte/unit columns, hover kinds, semantic-token legends, completion snippet/label-detail and definition link validation, rename gating, safe defaults")
PY
