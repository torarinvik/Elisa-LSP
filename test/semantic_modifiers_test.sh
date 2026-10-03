#!/usr/bin/env bash
# H01: negotiated standard semantic-token modifiers. The cache uses canonical
# bits while full/range responses use the client's negotiated modifier legend.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import json
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv, root = sys.argv[1], sys.argv[2]
schema = json.load(open(os.path.join(root, "docs/semantic-token-schema.json"), encoding="utf-8"))
modifier_names = schema["modifiers"]["legend"]
modifier_bits = schema["modifiers"]["canonical_bits"]
assert modifier_names == ["declaration", "definition", "readonly", "modification"]
assert modifier_bits == {"declaration": 1, "definition": 2, "readonly": 4, "modification": 8}

source = (
    "const LIMIT: i64 = 3\n"
    "extern ext(value: i64) -> i64\n"
    "def modify(input: i64) -> i64:\n"
    "    local: i64 = input\n"
    "    local <- local + 1\n"
    "    return LIMIT + local\n"
)
uri = "file:///semantic-modifiers.elisa"


def decode(data):
    assert len(data) % 5 == 0, data
    line = col = 0
    out = []
    for i in range(0, len(data), 5):
        dline, dcol, length, token_type, modifiers = data[i:i + 5]
        line += dline
        col = col + dcol if dline == 0 else dcol
        out.append((line, col, length, token_type, modifiers))
    return out


def token_at(tokens, line, col, text):
    matches = [
        token for token in tokens
        if token[0] == line and token[1] == col and token[2] == len(text)
    ]
    assert len(matches) == 1, (line, col, text, matches, tokens)
    return matches[0]


caps_with_modifiers = {
    "textDocument": {
        "semanticTokens": {
            "tokenTypes": list(schema["legend"]),
            # Deliberately reverse the order and include an unknown name: the
            # server should return its canonical supported subset and remap
            # bits accordingly.
            "tokenModifiers": ["modification", "unknown-client-modifier", "readonly", "definition", "declaration"],
        }
    }
}

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": caps_with_modifiers})
    assert "result" in initialized, initialized
    provider = initialized["result"]["capabilities"]["semanticTokensProvider"]
    assert provider["legend"]["tokenModifiers"] == modifier_names, provider
    client.notify("textDocument/didOpen", {"textDocument": {
        "uri": uri, "languageId": "Elisa", "version": 1, "text": source,
    }})
    full = client.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri}})
    ranged = client.request("textDocument/semanticTokens/range", {
        "textDocument": {"uri": uri},
        "range": {"start": {"line": 4, "character": 0}, "end": {"line": 4, "character": 99}},
    })
    assert "result" in full and "result" in ranged, (full, ranged)
    full_data = full["result"]["data"]
    range_data = ranged["result"]["data"]
    assert client.finish(timeout=30) == 0

full_tokens = decode(full_data)
range_tokens = decode(range_data)
lines = source.splitlines()

# Function definitions and extern declarations are distinguished. A concrete
# const definition is also readonly, and a direct `<-` target is a modification.
assert token_at(full_tokens, 0, 6, "LIMIT")[4] == 2 | 4
assert token_at(full_tokens, 1, 7, "ext")[4] == 1
assert token_at(full_tokens, 2, 4, "modify")[4] == 2
assert token_at(full_tokens, 4, 4, "local")[4] == 8
assert token_at(full_tokens, 5, 11, "LIMIT")[4] == 4
# The local declaration and read are not guessed readonly because the compiler
# occurrence channel does not retain local mutability metadata.
assert token_at(full_tokens, 3, 4, "local")[4] == 0
assert token_at(full_tokens, 5, 19, "local")[4] == 0
assert all(modifiers in (0, 1, 2, 4, 6, 8) for *_, modifiers in full_tokens)
assert range_tokens == [token for token in full_tokens if token[0] == 4]

# A client that omits tokenModifiers receives the same token types with all
# modifier bits dropped at the protocol boundary.
plain_uri = "file:///semantic-modifiers-plain.elisa"
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {"textDocument": {"semanticTokens": {"tokenTypes": list(schema["legend"])}}}})
    assert "result" in initialized, initialized
    provider = initialized["result"]["capabilities"]["semanticTokensProvider"]
    assert provider["legend"]["tokenModifiers"] == [], provider
    client.notify("textDocument/didOpen", {"textDocument": {
        "uri": plain_uri, "languageId": "Elisa", "version": 1, "text": source,
    }})
    response = client.request("textDocument/semanticTokens/full", {"textDocument": {"uri": plain_uri}})
    assert "result" in response, response
    plain_tokens = decode(response["result"]["data"])
    assert all(token[4] == 0 for token in plain_tokens), plain_tokens
    assert client.finish(timeout=30) == 0

print("semantic modifiers OK: negotiated legend, declaration/definition/readonly/modification bits, and full/range remapping verified")
PY
