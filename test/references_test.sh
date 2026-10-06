#!/usr/bin/env bash
# F04/A02: exact resolver-backed same-document references for globals and
# parameter/local BindingIds, including shadowing and repeated source spellings.
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
uri = "file:///references.elisa"
stress_uri = "file:///references-stress.elisa"
source = (
    "def target() -> i64:\n"
    "    return 1\n"
    "def caller(π: i64) -> i64:\n"
    "    return π + target()\n"
    "def another() -> i64:\n"
    "    return target()\n"
    "def shadow(target: i64) -> i64:\n"
    "    return target\n"
    "def overloaded() -> i64:\n"
    "    return 0\n"
    "def overloaded(value: i64) -> i64:\n"
    "    return value\n"
    "def ambiguous() -> i64:\n"
    "    return overloaded()\n"
    "def unresolved() -> i64:\n"
    "    return missing()\n"
    "def local_refs(p: i64) -> i64:\n"
    "    value: i64 = p\n"
    "    return p + p + value + value\n"
    "def shadow_refs(p: i64) -> i64:\n"
    "    value: i64 = p\n"
    "    if p > 0:\n"
    "        value: i64 = p + value\n"
    "        return value\n"
    "    return value\n"
)
lines = source.splitlines()
stress_count = 1800
stress_source = "def shared() -> i64:\n    return 1\n" + "".join(
    f"def caller_{index}() -> i64:\n    return shared()\n"
    for index in range(stress_count)
)


def char_column(line_no, needle, encoding, inside=0, occurrence=0):
    line = lines[line_no]
    offset = -1
    cursor = 0
    for _ in range(occurrence + 1):
        offset = line.index(needle, cursor)
        cursor = offset + len(needle)
    prefix = line[:offset]
    if encoding == "utf-8":
        return len(prefix.encode("utf-8")) + inside
    return len(prefix.encode("utf-16-le")) // 2 + inside


def location(line_no, needle, encoding, occurrence=0):
    start = char_column(line_no, needle, encoding, occurrence=occurrence)
    if encoding == "utf-8":
        width = len(needle.encode("utf-8"))
    else:
        width = len(needle.encode("utf-16-le")) // 2
    return {
        "uri": uri,
        "range": {
            "start": {"line": line_no, "character": start},
            "end": {"line": line_no, "character": start + width},
        },
    }


def invalid_raw(client, req_id, params_source):
    raw = (
        '{"jsonrpc":"2.0","id":' + str(req_id)
        + ',"method":"textDocument/references","params":' + params_source + '}'
    ).encode("utf-8")
    client.send(frame_bytes(raw))
    response = client.wait_response(req_id)
    assert response.get("error", {}).get("code") == -32602, (req_id, response)


def run(encoding):
    caps = {"general": {"positionEncodings": ["utf-8"]}} if encoding == "utf-8" else {}
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        assert initialized["result"]["capabilities"].get("referencesProvider") is True
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": source,
            }
        })

        def references(line, needle, include, *, inside=2, occurrence=0):
            return client.request("textDocument/references", {
                "textDocument": {"uri": uri},
                "position": {
                    "line": line,
                    "character": char_column(line, needle, encoding, inside, occurrence),
                },
                "context": {"includeDeclaration": include},
            })

        expected_all = [
            location(0, "target", encoding),
            location(3, "target", encoding),
            location(5, "target", encoding),
        ]
        from_declaration = references(0, "target", True)
        assert from_declaration.get("result") == expected_all, from_declaration
        from_use = references(3, "target", True)
        assert from_use.get("result") == expected_all, from_use
        excluding_decl = references(3, "target", False)
        assert excluding_decl.get("result") == expected_all[1:], excluding_decl

        # Parameter declaration/use rows share a resolver BindingId. Repeated
        # same-line spellings remain distinct ranges but are returned together.
        expected_parameter = [
            location(16, "p", encoding),
            location(17, "p", encoding),
            location(18, "p", encoding, occurrence=0),
            location(18, "p", encoding, occurrence=1),
        ]
        from_parameter_use = references(18, "p", True, inside=0, occurrence=1)
        assert from_parameter_use.get("result") == expected_parameter, from_parameter_use
        without_parameter_declaration = references(17, "p", False, inside=0)
        assert without_parameter_declaration.get("result") == expected_parameter[1:], without_parameter_declaration

        # The inner initializer repeats the outer name on the same line as its
        # declaration; exact resolver identities must survive that ordering.
        expected_outer_value = [
            location(20, "value", encoding),
            location(22, "value", encoding, occurrence=1),
            location(24, "value", encoding),
        ]
        outer_value = references(22, "value", True, occurrence=1)
        assert outer_value.get("result") == expected_outer_value, outer_value
        expected_inner_value = [
            location(22, "value", encoding, occurrence=0),
            location(23, "value", encoding),
        ]
        inner_value = references(23, "value", True)
        assert inner_value.get("result") == expected_inner_value, inner_value
        outer_without_declaration = references(24, "value", False)
        assert outer_without_declaration.get("result") == expected_outer_value[1:], outer_without_declaration

        # Ranges are exact identifier spans and already use negotiated units.
        assert expected_all[1]["range"]["start"]["character"] == char_column(3, "target", encoding)
        assert expected_all[1]["range"]["end"]["character"] - expected_all[1]["range"]["start"]["character"] == 6

        # Ambiguous/unsupported targets, punctuation, and positions outside the
        # source return an empty array without lexical fallback.
        assert references(13, "overloaded", True).get("result") == []
        assert references(15, "missing", True).get("result") == []
        punctuation = client.request("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 3},
            "context": {"includeDeclaration": True},
        })
        assert punctuation.get("result") == [], punctuation
        out_of_document = client.request("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": 99, "character": 0},
            "context": {"includeDeclaration": True},
        })
        assert out_of_document.get("result") == [], out_of_document
        oversized_character = client.request("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 999},
            "context": {"includeDeclaration": True},
        })
        assert oversized_character.get("result") == [], oversized_character

        # Unknown / closed URI has no current analysis and must be a valid empty result.
        no_open = client.request("textDocument/references", {
            "textDocument": {"uri": "file:///never-opened.elisa"},
            "position": {"line": 0, "character": 0},
            "context": {"includeDeclaration": False},
        })
        assert no_open.get("result") == [], no_open

        # Standard work/partial-result fields and unknown context members are
        # tolerated, while every consumed field remains unique and well-typed.
        extended = client.request("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": 0, "character": 5},
            "context": {"includeDeclaration": True, "extension": "ignored"},
            "workDoneToken": "progress-1",
            "partialResultToken": 8,
        })
        assert extended.get("result") == expected_all, extended

        # A popular symbol exercises the response path that formerly scanned
        # every accumulated span for duplicates and insertion-sorted results.
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": stress_uri,
                "languageId": "Elisa",
                "version": 1,
                "text": stress_source,
            }
        })
        stress_result = client.request("textDocument/references", {
            "textDocument": {"uri": stress_uri},
            "position": {"line": 0, "character": 5},
            "context": {"includeDeclaration": True},
        })
        stress_locations = stress_result.get("result")
        assert isinstance(stress_locations, list), stress_result
        assert len(stress_locations) == stress_count + 1, (len(stress_locations), stress_count + 1)
        assert stress_locations[0] == {
            "uri": stress_uri,
            "range": {
                "start": {"line": 0, "character": 4},
                "end": {"line": 0, "character": 10},
            },
        }, stress_locations[:1]
        previous_position = (-1, -1)
        for item in stress_locations:
            assert item.get("uri") == stress_uri, item
            start = item.get("range", {}).get("start", {})
            position = (start.get("line", -1), start.get("character", -1))
            assert position > previous_position, (previous_position, position)
            previous_position = position
        stress_without_declaration = client.request("textDocument/references", {
            "textDocument": {"uri": stress_uri},
            "position": {"line": 0, "character": 5},
            "context": {"includeDeclaration": False},
        })
        assert len(stress_without_declaration.get("result", [])) == stress_count, stress_without_declaration

        invalid_raw(client, 800, '{"textDocument":{"uri":"file:///references.elisa"},"position":{"line":0,"character":4},"context":{}}')
        invalid_raw(client, 801, '{"textDocument":{"uri":"file:///references.elisa"},"position":{"line":0,"character":4},"context":{"includeDeclaration":"true"}}')
        invalid_raw(client, 802, '{"textDocument":{"uri":"file:///references.elisa"},"position":{"line":0,"character":4},"context":{"includeDeclaration":true,"includeDeclaration":false}}')
        invalid_raw(client, 803, '{"textDocument":{"uri":"file:///references.elisa"},"position":{"line":0,"character":4},"p\u006fsition":{"line":0,"character":5},"context":{"includeDeclaration":true}}')
        invalid_raw(client, 804, '{"textDocument":{"uri":"file:///references.elisa"},"textDocument":{"uri":"file:///other.elisa"},"position":{"line":0,"character":4},"context":{"includeDeclaration":true}}')
        invalid_raw(client, 805, '{"textDocument":{"uri":"file:///references.elisa","u\u0072i":"file:///other.elisa"},"position":{"line":0,"character":4},"context":{"includeDeclaration":true}}')
        invalid_raw(client, 806, '{"textDocument":{"uri":"file:///references.elisa"},"position":{"line":0,"character":4},"context":{"includeDeclaration":true},"context":{"includeDeclaration":false}}')
        invalid_raw(client, 807, '{"textDocument":{"uri":"file:///references.elisa"},"position":{"line":0,"character":4}}')
        client.finish(timeout=30)
    return expected_all[1]["range"]["start"]["character"]


utf16_call_start = run("utf-16")
utf8_call_start = run("utf-8")
assert utf8_call_start == utf16_call_start + 1, (utf16_call_start, utf8_call_start)
print("references OK: exact same-file resolver results, sorted and deduped; declaration policy, validation, UTF-8/UTF-16, unsupported cases empty")
PY
