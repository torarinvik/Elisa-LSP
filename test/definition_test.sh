#!/usr/bin/env bash
# F03: exact, resolver-backed definition links for functions and local bindings.
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
uri = "file:///definition.elisa"
source = (
    "def target() -> i64:\n"
    "    return 7\n"
    "def caller(π: i64) -> i64:\n"
    "    return π + target()\n"
    "def shadow(target: i64) -> i64:\n"
    "    return target\n"
    "def overloaded() -> i64:\n"
    "    return 1\n"
    "def overloaded(value: i64) -> i64:\n"
    "    return value\n"
    "def ambiguous_use() -> i64:\n"
    "    return overloaded()\n"
    "def unresolved_use() -> i64:\n"
    "    return missing()\n"
    "def local_defs(p: i64) -> i64:\n"
    "    value: i64 = p\n"
    "    return value + p\n"
    "def nested_defs(p: i64) -> i64:\n"
    "    value: i64 = p\n"
    "    if p > 0:\n"
    "        value: i64 = p + value\n"
    "        return value\n"
    "    return value\n"
)
lines = source.splitlines()


def char_column(line, needle, encoding, inside=2):
    start = line.index(needle)
    prefix = line[:start]
    if encoding == "utf-8":
        return len(prefix.encode("utf-8")) + inside
    return len(prefix.encode("utf-16-le")) // 2 + inside


def expected_location(line_number, needle, encoding):
    start = char_column(lines[line_number], needle, encoding, inside=0)
    width = len(needle.encode("utf-8")) if encoding == "utf-8" else len(needle.encode("utf-16-le")) // 2
    return {"uri": uri, "range": {
        "start": {"line": line_number, "character": start},
        "end": {"line": line_number, "character": start + width},
    }}


def range_for(line_number, needle, encoding):
    start = char_column(lines[line_number], needle, encoding, inside=0)
    width = len(needle.encode("utf-8")) if encoding == "utf-8" else len(needle.encode("utf-16-le")) // 2
    return {
        "start": {"line": line_number, "character": start},
        "end": {"line": line_number, "character": start + width},
    }


def run(encoding):
    caps = {"general": {"positionEncodings": ["utf-8"]}} if encoding == "utf-8" else {}
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        assert initialized["result"]["capabilities"].get("definitionProvider") is True
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": source,
            }
        })

        def definition(line, name, *, inside=2):
            response = client.request("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {
                    "line": line,
                    "character": char_column(lines[line], name, encoding, inside),
                },
            })
            assert "result" in response, response
            return response["result"]

        expected_target = {
            "uri": uri,
            "range": {
                "start": {"line": 0, "character": 4},
                "end": {"line": 0, "character": 10},
            },
        }
        assert definition(3, "target") == expected_target
        # A declaration name is a self-edge with the same exact name span.
        assert definition(0, "target") == expected_target
        assert definition(11, "overloaded") is None, "overloaded names are ambiguous"
        assert definition(13, "missing") is None, "unresolved spellings must not use a name fallback"
        assert definition(5, "target") == expected_location(4, "target", encoding), "a parameter shadow resolves to its own declaration"
        assert definition(16, "p", inside=0) == expected_location(14, "p", encoding), "parameter use resolves by BindingId"
        assert definition(16, "value") == expected_location(15, "value", encoding), "local use resolves by BindingId"
        assert definition(21, "value") == expected_location(20, "value", encoding), "nested local resolves to its own declaration"
        assert definition(22, "value") == expected_location(18, "value", encoding), "outer local remains distinct after shadowing"

        punctuation = client.request("textDocument/definition", {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 3},
        })
        assert punctuation.get("result", "missing") is None, punctuation
        out_of_document = client.request("textDocument/definition", {
            "textDocument": {"uri": uri},
            "position": {"line": 99, "character": 0},
        })
        assert out_of_document.get("result", "missing") is None, out_of_document
        oversized_character = client.request("textDocument/definition", {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 999},
        })
        assert oversized_character.get("result", "missing") is None, oversized_character
        client.finish(timeout=30)
    return char_column(lines[3], "target", encoding)


def run_links(encoding):
    caps = {"textDocument": {"definition": {"linkSupport": True}}}
    if encoding == "utf-8":
        caps["general"] = {"positionEncodings": ["utf-8"]}
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": source}
        })

        def definition_links(source_line, source_name, target_line, target_name, inside=2):
            response = client.request("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {
                    "line": source_line,
                    "character": char_column(lines[source_line], source_name, encoding, inside),
                },
            })
            assert "result" in response, response
            target = range_for(target_line, target_name, encoding)
            expected = [{
                "originSelectionRange": range_for(source_line, source_name, encoding),
                "targetUri": uri,
                "targetRange": target,
                "targetSelectionRange": target,
            }]
            assert response["result"] == expected, response

        definition_links(3, "target", 0, "target")
        definition_links(0, "target", 0, "target")
        definition_links(16, "p", 14, "p", inside=0)
        client.finish(timeout=30)


utf16_start = run("utf-16")
utf8_start = run("utf-8")
assert utf8_start == utf16_start + 1, (utf16_start, utf8_start)
run_links("utf-16")
run_links("utf-8")
print("definition OK: exact function and parameter/local BindingId locations and negotiated LocationLinks, origin/target spans, declaration self-edge, nested shadowing, UTF-16/UTF-8 and ambiguity decline")
PY
