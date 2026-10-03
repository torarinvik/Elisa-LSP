#!/usr/bin/env bash
# F06: narrow resolver-backed signature help and token-nesting argument counts.
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
uri = "file:///signature-help.elisa"
incomplete_uri = "file:///signature-help-incomplete.elisa"
source = (
    "def add3(first: i64, second: i64, third: i64) -> i64:\n"
    "    return first + second + third\n"
    "def add2(first: i64, second: i64) -> i64:\n"
    "    return first + second\n"
    "def pair_text(first: sview, second: sview) -> i64:\n"
    "    return 1\n"
    "struct Box:\n"
    "    value: i64\n"
    "def Box(value: i64) -> Box:\n"
    "    return Box{value: value}\n"
    "def overloaded(value: i64) -> i64:\n"
    "    return value\n"
    "def overloaded(value: sview) -> i64:\n"
    "    return 1\n"
    "def caller() -> i64:\n"
    "    π: i64 = 1\n"
    "    return add3(π, add2(2, 3), 4)\n"
    "def multiline() -> i64:\n"
    "    return add3(\n"
    "        1,\n"
    "        add2(\n"
    "            2,\n"
    "            3\n"
    "        ),\n"
    "        4\n"
    "    )\n"
    "def string_caller() -> i64:\n"
    "    return pair_text(\"a,b\", \"c,d\")\n"
    "def named_caller() -> i64:\n"
    "    return add3(first: 1, second: 2, third: 3)\n"
    "def shadowed(add3: i64) -> i64:\n"
    "    return add3(1, 2, 3)\n"
    "def ambiguous() -> i64:\n"
    "    return overloaded(1)\n"
    "def construct() -> Box:\n"
    "    return Box(1)\n"
)
lines = source.splitlines()


def char_column(line_index, marker, encoding, after=0):
    line = lines[line_index]
    prefix = line[: line.index(marker)]
    units = len(prefix.encode("utf-8")) if encoding == "utf-8" else len(prefix.encode("utf-16-le")) // 2
    marker_units = len(marker.encode("utf-8")) if encoding == "utf-8" else len(marker.encode("utf-16-le")) // 2
    return units + marker_units + after


def request(client, line, marker, encoding, after=0, context=None, target_uri=uri):
    params = {
        "textDocument": {"uri": target_uri},
        "position": {"line": line, "character": char_column(line, marker, encoding, after)},
    }
    if context is not None:
        params["context"] = context
    return client.request("textDocument/signatureHelp", params)


def assert_help(response, name, parameters, active):
    assert "result" in response, response
    help_value = response["result"]
    assert help_value["activeSignature"] == 0, help_value
    signature = help_value["signatures"][0]
    assert signature["label"] == name + "(" + ", ".join(parameters) + ")", signature
    assert [parameter["label"] for parameter in signature["parameters"]] == parameters, signature
    if parameters:
        assert help_value["activeParameter"] == active, help_value
    else:
        assert "activeParameter" not in help_value, help_value


for encoding in ("utf-16", "utf-8"):
    caps = {"general": {"positionEncodings": ["utf-8"]}} if encoding == "utf-8" else {}
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        server_caps = initialized["result"]["capabilities"]
        assert server_caps["signatureHelpProvider"]["triggerCharacters"] == ["(", ","]
        client.notify("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": source}
        })

        # A comma in the first outer argument advances to parameter 1 even
        # though a nested call has its own comma before this cursor.
        response = request(client, 16, "add3(π,", encoding, after=0)
        assert_help(response, "add3", ["first", "second", "third"], 1)

        # The innermost open call owns the cursor and its own comma sequence.
        response = request(client, 16, "add2(2,", encoding, after=0)
        assert_help(response, "add2", ["first", "second"], 1)
        response = request(client, 16, "4", encoding, after=0)
        assert_help(response, "add3", ["first", "second", "third"], 2)

        # Multiline calls use the same exact nesting; commas in string tokens
        # do not become separators for the surrounding call.
        response = request(client, 21, "2,", encoding, after=0)
        assert_help(response, "add2", ["first", "second"], 1)
        response = request(client, 24, "4", encoding, after=0)
        assert_help(response, "add3", ["first", "second", "third"], 2)
        response = request(client, 27, "pair_text(", encoding, after=len('"a,b", '))
        assert_help(response, "pair_text", ["first", "second"], 1)

        # Resolver ambiguity, a local shadow, constructor syntax, qualified or
        # member calls, and named-argument lists intentionally have no result.
        for line, marker in ((29, "add3(first:"), (31, "add3(1,"), (33, "overloaded(1"), (35, "Box(1")):
            result = request(client, line, marker, encoding, after=0)
            assert result.get("result", "missing") is None, (line, marker, result)

        assert_help(request(client, 16, "add3(π,", encoding, context={"triggerKind": 1, "isRetrigger": False}), "add3", ["first", "second", "third"], 1)
        assert_help(request(client, 16, "add3(π,", encoding, context={"triggerKind": 2, "triggerCharacter": ",", "isRetrigger": False}), "add3", ["first", "second", "third"], 1)
        assert_help(request(client, 16, "add3(π,", encoding, context={"triggerKind": 3, "isRetrigger": True}), "add3", ["first", "second", "third"], 1)

        invalid_contexts = (
            {"triggerKind": 1},
            {"triggerKind": 2, "isRetrigger": False},
            {"triggerKind": 3, "isRetrigger": 1},
            {"triggerKind": 4, "isRetrigger": False},
        )
        for context in invalid_contexts:
            invalid = request(client, 16, "add3(π,", encoding, context=context)
            assert invalid.get("error", {}).get("code") == -32602, (context, invalid)

        out_of_document = client.request("textDocument/signatureHelp", {
            "textDocument": {"uri": uri}, "position": {"line": 999, "character": 0}
        })
        assert out_of_document.get("result", "missing") is None, out_of_document
        oversized_character = client.request("textDocument/signatureHelp", {
            "textDocument": {"uri": uri}, "position": {"line": 16, "character": 999}
        })
        assert oversized_character.get("result", "missing") is None, oversized_character
        unknown = client.request("textDocument/signatureHelp", {
            "textDocument": {"uri": "file:///missing.elisa"}, "position": {"line": 0, "character": 0}
        })
        assert unknown.get("result", "missing") is None, unknown

        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": incomplete_uri,
                "languageId": "Elisa",
                "version": 1,
                "text": "def target(first: i64, second: i64) -> i64:\n    return first\ndef caller() -> i64:\n    return target(1,",
            }
        })
        incomplete = client.request("textDocument/signatureHelp", {
            "textDocument": {"uri": incomplete_uri}, "position": {"line": 3, "character": 20}
        })
        assert_help(incomplete, "target", ["first", "second"], 1)
        incomplete_overlong = client.request("textDocument/signatureHelp", {
            "textDocument": {"uri": incomplete_uri}, "position": {"line": 3, "character": 999}
        })
        assert_help(incomplete_overlong, "target", ["first", "second"], 1)

        shadowed_uri = "file:///signature-help-shadowed-incomplete.elisa"
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": shadowed_uri,
                "languageId": "Elisa",
                "version": 1,
                "text": "def target(first: i64, second: i64) -> i64:\n    return first\ndef caller(target: i64) -> i64:\n    return target(1,",
            }
        })
        shadowed_incomplete = client.request("textDocument/signatureHelp", {
            "textDocument": {"uri": shadowed_uri}, "position": {"line": 3, "character": 20}
        })
        assert shadowed_incomplete.get("result", "missing") is None, shadowed_incomplete
        client.finish(timeout=30)

    # The same marked byte position in a line with π must be shifted in bytes,
    # but not in UTF-16 units.
    assert char_column(16, "add3(π,", "utf-8") == char_column(16, "add3(π,", "utf-16") + 1

print("signature help OK: exact resolver targets, nested/multiline token commas, strings, incomplete calls, context validation, UTF-16/UTF-8")
PY
