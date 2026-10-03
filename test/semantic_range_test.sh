#!/usr/bin/env bash
# H05: semanticTokens/range — decode the cached full result, keep entries
# intersecting the requested range, and re-encode from document zero (not the
# range start). Whole-document range equals the full result; empty/unknown yield
# empty; structurally malformed ranges yield InvalidParams.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import json, os, sys
srv = sys.argv[1]
root = sys.argv[2]
sys.path.insert(0, os.path.join(root, "test"))
from lsp_client import LspSession
DOC = ('def f() -> void:\n'      # 0
       '    x: i64 = 1\n'        # 1
       '    y: i64 = 2\n'        # 2
       '    return\n')           # 3
schema = json.load(open(root + "/docs/semantic-token-schema.json", encoding="utf-8"))
legacy_caps = {"capabilities": {}}
standard_caps = {"capabilities": {"textDocument": {"semanticTokens": {"tokenTypes": ["function", "type", "number"]}}}}
def decode(data):
    line = col = 0
    out = []
    for i in range(0, len(data), 5):
        dl, dc, ln, tt, mods = data[i:i+5]
        assert mods == 0
        line += dl
        col = (col + dc) if dl == 0 else dc
        out.append((line, col, ln, tt))
    return out

with LspSession(srv, startup_timeout=5, request_timeout=10) as client:
    initialized = client.initialize(legacy_caps)
    assert "result" in initialized, f"initialize failed: {initialized}"
    client.notify("textDocument/didOpen", {"textDocument": {
        "uri": "file:///rng.elisa", "languageId": "Elisa", "version": 1, "text": DOC
    }})
    full_response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": "file:///rng.elisa"}
    })
    assert "result" in full_response, full_response
    full_data = full_response["result"]["data"]

    def rng(sline, schar, eline, echar, uri="file:///rng.elisa"):
        return client.request("textDocument/semanticTokens/range", {
            "textDocument": {"uri": uri},
            "range": {"start": {"line": sline, "character": schar},
                      "end": {"line": eline, "character": echar}},
        })

    line1_response = rng(1, 0, 1, 99)  # line 1 only
    whole_response = rng(0, 0, 99, 0)  # valid range extending past the document
    beyond_document_response = rng(99, 0, 99, 0)  # past-EOF start is empty
    empty_response = rng(3, 0, 3, 0)   # empty range
    boundary_response = rng(1, 8, 2, 6)  # spans the line 1/2 boundary
    malformed_response = rng(-5, -5, 999, 999)  # malformed -> InvalidParams
    reversed_response = rng(2, 0, 1, 0)  # reversed -> InvalidParams
    absent_response = rng(0, 0, 0, 0, uri="file:///absent.elisa")
    for response in (line1_response, whole_response, beyond_document_response, empty_response,
                     boundary_response, absent_response):
        assert "result" in response, response
    assert beyond_document_response["result"]["data"] == [], beyond_document_response
    for invalid_response in (malformed_response, reversed_response):
        assert invalid_response.get("error", {}).get("code") == -32602, (
            f"malformed or reversed range must be InvalidParams: {invalid_response}"
        )
    assert client.finish() == 0

res = {
    2: full_data,
    3: line1_response["result"]["data"],
    4: whole_response["result"]["data"],
    5: empty_response["result"]["data"],
    6: boundary_response["result"]["data"],
    8: absent_response["result"]["data"],
}
full = decode(res[2])
line1 = decode(res[3])
assert line1 == [(l,c,n,t) for (l,c,n,t) in full if l == 1], f"line range wrong: {line1}"
# Re-encoded from document zero: first entry carries its absolute line.
assert line1 and line1[0][0] == 1, f"range must use document-zero baseline: {line1}"

# Whole-document range equals the full result exactly.
assert res[4] == res[2], "whole-document range must equal full"
# Empty range -> empty.
assert res[5] == [], res[5]
# Boundary-spanning range keeps tokens from both lines.
bound = decode(res[6])
lines = {l for (l,_,_,_) in bound}
assert lines == {1, 2}, f"boundary range lines: {lines}"
# Negative coordinates are malformed protocol params, not a valid out-of-range
# query; they receive InvalidParams.
# Unknown URI -> empty, no crash.
assert res[8] == [], res[8]

# A standard-only client uses the same cached source analysis but receives the
# negotiated subset in both full and range responses.
standard_uri = "file:///rng-standard.elisa"
with LspSession(srv, startup_timeout=5, request_timeout=10) as client:
    standard_initialize = client.initialize(standard_caps)
    assert "result" in standard_initialize, standard_initialize
    client.notify("textDocument/didOpen", {"textDocument": {
        "uri": standard_uri, "languageId": "Elisa", "version": 1, "text": DOC
    }})
    standard_full_response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": standard_uri}
    })
    standard_line_response = client.request("textDocument/semanticTokens/range", {
        "textDocument": {"uri": standard_uri},
        "range": {"start": {"line": 1, "character": 0},
                  "end": {"line": 1, "character": 99}},
    })
    standard_whole_response = client.request("textDocument/semanticTokens/range", {
        "textDocument": {"uri": standard_uri},
        "range": {"start": {"line": 0, "character": 0},
                  "end": {"line": 99, "character": 0}},
    })
    assert all("result" in response for response in (
        standard_full_response, standard_line_response, standard_whole_response
    )), (standard_full_response, standard_line_response, standard_whole_response)
    assert client.finish() == 0

standard_result = standard_initialize["result"]
standard_legend = standard_result["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"]
assert standard_legend == ["type", "number", "function"], standard_legend
offered = set(standard_caps["capabilities"]["textDocument"]["semanticTokens"]["tokenTypes"])
assert set(standard_legend) <= offered
standard_full = standard_full_response["result"]["data"]
assert standard_whole_response["result"]["data"] == standard_full, "standard whole-range result differs from full"
fallback_indices = {name: index for index, name in enumerate(standard_legend)}
expected_standard = []
for line, col, length, custom_index in full:
    standard_name = schema["standard_fallback"][schema["legend"][custom_index]]
    if standard_name in fallback_indices:
        expected_standard.append((line, col, length, fallback_indices[standard_name]))
assert decode(standard_full) == expected_standard, "standard full result did not match the schema mapping"
assert decode(standard_line_response["result"]["data"]) == [
    token for token in expected_standard if token[0] == 1
], "standard range result diverged from the mapped cached full result"
assert all(0 <= token[3] < len(standard_legend) for token in decode(standard_full))

print(f"semantic range OK: {len(line1)} legacy tokens on line 1; standard legend/full/range mapping is consistent")
PY
