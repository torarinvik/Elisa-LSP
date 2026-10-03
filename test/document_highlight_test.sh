#!/usr/bin/env bash
# F04: exact same-document highlights for resolver-backed top-level functions.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession, frame_bytes

srv = sys.argv[1]
uri = "file:///highlights.elisa"
source = (
    "def target() -> i64:\n"
    "    return 7\n"
    "def caller(π: i64) -> i64:\n"
    "    return π + target() + target()\n"
    "def local_refs(p: i64) -> i64:\n"
    "    value: i64 = p\n"
    "    return p + value + p\n"
    "def nested_refs(p: i64) -> i64:\n"
    "    value: i64 = p\n"
    "    if p > 0:\n"
    "        value: i64 = p + value\n"
    "        return value\n"
    "    return value\n"
)
lines = source.splitlines()


def start_column(line_number, needle, encoding, occurrence=0):
    line = lines[line_number]
    start = -1
    offset = 0
    for _ in range(occurrence + 1):
        start = line.index(needle, offset)
        offset = start + len(needle)
    prefix = line[:start]
    if encoding == "utf-8":
        return len(prefix.encode("utf-8"))
    return len(prefix.encode("utf-16-le")) // 2


def expected_location(line_number, needle, encoding, occurrence=0, kind=2):
    start = start_column(line_number, needle, encoding, occurrence)
    width = len(needle.encode("utf-8")) if encoding == "utf-8" else len(needle.encode("utf-16-le")) // 2
    result = {
        "range": {
            "start": {"line": line_number, "character": start},
            "end": {"line": line_number, "character": start + width},
        }
    }
    if kind is not None:
        result["kind"] = kind
    return result


def invalid_raw(client, req_id, params_source):
    raw = (
        '{"jsonrpc":"2.0","id":' + str(req_id)
        + ',"method":"textDocument/documentHighlight","params":'
        + params_source + '}'
    ).encode("utf-8")
    client.send(frame_bytes(raw))
    response = client.wait_response(req_id)
    assert response.get("error", {}).get("code") == -32602, (req_id, response)


def run(encoding):
    capabilities = {"general": {"positionEncodings": ["utf-8"]}} if encoding == "utf-8" else {}
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": capabilities})
        assert "result" in initialized, initialized
        assert initialized["result"]["capabilities"].get("documentHighlightProvider") is True
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": source,
            }
        })

        def highlights(line, needle, occurrence=0, inside=2, selected_uri=uri):
            column = start_column(line, needle, encoding, occurrence) + inside
            return client.request("textDocument/documentHighlight", {
                "textDocument": {"uri": selected_uri},
                "position": {"line": line, "character": column},
            })

        expected = [
            expected_location(0, "target", encoding, kind=1),
            expected_location(3, "target", encoding, occurrence=0),
            expected_location(3, "target", encoding, occurrence=1),
        ]
        from_declaration = highlights(0, "target", inside=2)
        assert from_declaration.get("result") == expected, from_declaration
        from_second_call = highlights(3, "target", occurrence=1)
        assert from_second_call.get("result") == expected, from_second_call

        # Exact BindingIds also drive parameter/local highlights. The current
        # frontend does not classify reads versus writes, so these omit kind.
        parameter_binding = [
            expected_location(4, "p", encoding, kind=None),
            expected_location(5, "p", encoding, kind=None),
            expected_location(6, "p", encoding, occurrence=0, kind=None),
            expected_location(6, "p", encoding, occurrence=1, kind=None),
        ]
        got_parameter_binding = highlights(6, "p", occurrence=1, inside=0)
        assert got_parameter_binding.get("result") == parameter_binding, got_parameter_binding
        local_binding = [
            expected_location(5, "value", encoding, kind=None),
            expected_location(6, "value", encoding, kind=None),
        ]
        assert highlights(6, "value").get("result") == local_binding
        # Same-spelling nested locals remain distinct resolver identities.
        inner_value = [
            expected_location(10, "value", encoding, kind=None),
            expected_location(11, "value", encoding, kind=None),
        ]
        assert highlights(11, "value").get("result") == inner_value
        outer_value = [
            expected_location(8, "value", encoding, kind=None),
            expected_location(10, "value", encoding, occurrence=1, kind=None),
            expected_location(12, "value", encoding, kind=None),
        ]
        assert highlights(12, "value").get("result") == outer_value

        # Other symbols, punctuation, token-end positions, missing documents,
        # and out-of-range positions stay empty; no spelling fallback leaks in.
        assert highlights(2, "i64", inside=0).get("result") == []
        plus_column = len(lines[3][:lines[3].index("+")].encode("utf-16-le")) // 2
        if encoding == "utf-8":
            plus_column = len(lines[3][:lines[3].index("+")].encode("utf-8"))
        assert client.request("textDocument/documentHighlight", {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": plus_column},
        }).get("result") == []
        token_end = start_column(3, "target", encoding) + 6
        assert client.request("textDocument/documentHighlight", {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": token_end},
        }).get("result") == []
        assert highlights(3, "target", selected_uri="file:///missing.elisa").get("result") == []
        assert client.request("textDocument/documentHighlight", {
            "textDocument": {"uri": uri},
            "position": {"line": 99, "character": 0},
        }).get("result") == []
        assert client.request("textDocument/documentHighlight", {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 999},
        }).get("result") == []

        # Work/progress data is ignored safely, while malformed consumed fields
        # receive InvalidParams and never produce a highlight result.
        extended = client.request("textDocument/documentHighlight", {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": start_column(3, "target", encoding) + 2},
            "workDoneToken": "highlight-progress",
            "partialResultToken": 9,
        })
        assert extended.get("result") == expected, extended
        invalid_raw(client, 800, '{"textDocument":{"uri":"file:///highlights.elisa"},"position":{"line":-1,"character":0}}')
        invalid_raw(client, 801, '{"textDocument":{"uri":"file:///highlights.elisa"},"position":{"line":0,"character":4},"position":{"line":0,"character":5}}')

        client.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
        assert highlights(0, "target", inside=2).get("result") == []
        client.finish(timeout=30)
    return start_column(3, "target", encoding)


utf16_start = run("utf-16")
utf8_start = run("utf-8")
assert utf8_start == utf16_start + 1, (utf16_start, utf8_start)
print("document highlights OK: exact resolver spans, Text/Read kinds, UTF-8/UTF-16, validation and unsupported cases")
PY
