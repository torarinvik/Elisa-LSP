#!/usr/bin/env bash
# semanticTokens/full: legend advertised at initialize; a didOpen'd document
# tokenizes into correctly classified, delta-encoded tokens.
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
doc = "def demo(a: i64, b: u32) -> bool:\n    x: mutable f64 = 2.5\n    x <- 3.0\n    if a > 5:\n        return true\n    return false\n"
doc += "\nenum Event:\n    None\n    Quit\n    Resize(size: i64)\n\ndef make_event() -> Event:\n    return Event.Resize(1)\n\ndef kind(event: Event) -> i64:\n    match event:\n        Event.None:\n            return 0\n        Event.Quit:\n            return 1\n        Event.Resize(size):\n            return size\n"
doc += "\ndef invoke() -> Event:\n    return make_event()\n\ndef increment(value: i64) -> i64:\n    return value + 1\n\ndef label() -> dstr:\n    return \"event\"\n\ndef char_label() -> char:\n    return 'x'\n"
doc += "\ndef shadow_family(Event: i32) -> i32:\n    return Event.Resize(2)\n"
doc += "\ntype EventAlias = Event\n\ndef make_alias_event() -> EventAlias:\n    return EventAlias.Resize(1)\n\ndef consume_alias_event(event: EventAlias) -> i64:\n    match event:\n        EventAlias.Resize(size):\n            return size\n"
doc += "\ndef shadow(p: i64) -> i64:\n    p: i64 = p\n    return p\n"
doc += "\nenum LeftState:\n    Shared\nenum RightState:\n    Shared\n\ndef inspect_shorthand(value: LeftState) -> i64:\n    match value:\n        .Shared:\n            return 1\n\ndef inspect_qualified(value: LeftState) -> i64:\n    match value:\n        LeftState.Shared:\n            return 2\n"

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    capabilities = initialized["result"]["capabilities"]
    provider = capabilities.get("semanticTokensProvider")
    assert provider and "elisa.type.int.signed" in provider["legend"]["tokenTypes"], \
        "legend not advertised"

    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": "file:///t.elisa",
            "languageId": "Elisa",
            "version": 1,
            "text": doc,
        }
    })
    token_response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": "file:///t.elisa"},
    }, timeout=30)
    unknown_response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": "file:///other.elisa"},
    }, timeout=30)
    assert "result" in token_response, token_response
    assert "result" in unknown_response, unknown_response
    result = token_response["result"]
    unknown = unknown_response["result"]
    client.finish(timeout=30)

assert "data" in result, result
data = result["data"]
assert len(data) % 5 == 0 and len(data) >= 5 * 10, f"suspicious token count: {len(data) // 5}"
# decode + spot-check classifications (legend indices from semtokens.elisa)
toks = []
line = col = 0
for i in range(0, len(data), 5):
    dl, dc, ln, tt, mods = data[i:i + 5]
    line += dl
    col = (col + dc) if dl == 0 else dc
    toks.append((line, col, ln, tt))
    assert mods == 0
lines = doc.split("\n")


def type_at(line_no, column, expected_text):
    matches = [
        token_type
        for token_line, token_col, length, token_type in toks
        if token_line == line_no and token_col == column and length == len(expected_text)
    ]
    assert len(matches) == 1, (line_no, column, expected_text, matches, toks)
    actual_text = lines[line_no][column:column + len(expected_text)]
    assert actual_text == expected_text, (line_no, column, expected_text, actual_text)
    return matches[0]


def types_at(line_no, column, expected_text):
    return [
        token_type
        for token_line, token_col, length, token_type in toks
        if token_line == line_no and token_col == column and length == len(expected_text)
    ]


# Address every expectation by source occurrence. Repeated spellings such as
# `i64`, `Event`, and the enum variants must not overwrite one another.
assert type_at(0, 4, "demo") == 13, "def-site name should be fn.def"
assert type_at(0, 12, "i64") == 0 and type_at(0, 20, "u32") == 1, "integral families"
assert type_at(0, 28, "bool") == 3
assert type_at(1, 15, "f64") == 2 and type_at(1, 21, "2.5") == 9
assert type_at(1, 7, "mutable") == 34 and type_at(2, 6, "<-") == 34
assert type_at(3, 4, "if") == 27
assert type_at(4, 15, "true") == 12 and type_at(5, 11, "false") == 12
assert type_at(0, 8, "(") == 41 and type_at(0, 32, ":") == 41
assert type_at(1, 19, "=") == 46 and type_at(3, 9, ">") == 43
assert type_at(13, 24, "1") == 8 and type_at(18, 19, "0") == 8
assert type_at(20, 19, "1") == 8

# The same enum name is checked at its declaration, annotations, constructor,
# and all qualified case uses, rather than just the final dictionary entry.
for line_no, column in [(7, 5), (12, 20), (13, 11), (15, 16), (17, 8), (19, 8), (21, 8), (24, 16)]:
    assert type_at(line_no, column, "Event") == 6, ("enum type should be type.user", line_no)

# Check every declaration and use of each repeated variant name.
for line_no, column, name in [
    (8, 4, "None"), (17, 14, "None"),
    (9, 4, "Quit"), (19, 14, "Quit"),
    (10, 4, "Resize"), (13, 17, "Resize"), (21, 14, "Resize"),
]:
    assert type_at(line_no, column, name) == 47, ("enum variant token kind", line_no, name)

assert type_at(12, 4, "make_event") == 13 and type_at(15, 4, "kind") == 13
assert type_at(24, 4, "invoke") == 13 and type_at(25, 11, "make_event") == 14
assert type_at(27, 4, "increment") == 13 and type_at(28, 17, "+") == 42
assert type_at(28, 19, "1") == 8
assert type_at(30, 15, "dstr") == 4 and type_at(31, 11, '"event"') == 11
assert type_at(33, 20, "char") == 3 and type_at(34, 11, "'x'") == 10
shadow_line = next(i for i, source_line in enumerate(lines) if "return Event.Resize(2)" in source_line)
shadow_column = lines[shadow_line].index("Event.Resize")
assert type_at(shadow_line, shadow_column, "Event") == 16, "parameter shadows the enum family"
assert type_at(shadow_line, shadow_column + len("Event."), "Resize") != 47, \
    "a shadowed enum receiver must not color its member as a variant"
# A type alias preserves the enum family identity at qualified construction and
# pattern sites. This must come from compiler metadata, not PascalCase guessing.
alias_decl_line = next(i for i, source_line in enumerate(lines) if source_line.startswith("type EventAlias ="))
assert type_at(alias_decl_line, lines[alias_decl_line].rindex("Event"), "Event") == 6
alias_constructor_line = next(i for i, source_line in enumerate(lines) if "return EventAlias.Resize(1)" in source_line)
alias_constructor_column = lines[alias_constructor_line].index("EventAlias.Resize")
assert type_at(alias_constructor_line, alias_constructor_column, "EventAlias") == 6
assert type_at(alias_constructor_line, alias_constructor_column + len("EventAlias."), "Resize") == 47
alias_pattern_line = next(i for i, source_line in enumerate(lines) if "EventAlias.Resize(size):" in source_line)
alias_pattern_column = lines[alias_pattern_line].index("EventAlias.Resize")
assert type_at(alias_pattern_line, alias_pattern_column, "EventAlias") == 6
assert type_at(alias_pattern_line, alias_pattern_column + len("EventAlias."), "Resize") == 47
# Exact token offsets distinguish same-spelling parameter and local occurrences
# on a single line, including the new local's declaration and its parameter-valued
# initializer.
shadow_decl_line = next(i for i, source_line in enumerate(lines) if source_line == "    p: i64 = p")
assert type_at(shadow_decl_line, 4, "p") == 17
assert type_at(shadow_decl_line, 13, "p") == 16
shadow_return_line = next(i for i, source_line in enumerate(lines) if source_line == "    return p")
assert type_at(shadow_return_line, 11, "p") == 17
# The compiler registry has only spelling/owner/module rows, not an exact
# target for a leading-dot case. A repeated spelling across two enum owners
# therefore stays unclassified in shorthand, while an explicit owner remains
# safely recognizable.
shorthand_line = next(i for i, source_line in enumerate(lines) if source_line.strip() == ".Shared:")
shorthand_column = lines[shorthand_line].index("Shared")
assert 47 not in types_at(shorthand_line, shorthand_column, "Shared"), \
    "an ambiguous leading-dot variant must not be globally guessed"
qualified_line = next(i for i, source_line in enumerate(lines) if "LeftState.Shared:" in source_line)
qualified_column = lines[qualified_line].index("Shared")
assert type_at(qualified_line, qualified_column, "Shared") == 47, \
    "an explicit owner should preserve enum-variant coloring"
# The separate contextual-token fixture addresses `can` at each occurrence
# where a binding and the effect-grant keyword have distinct classifications.
# unknown URI -> empty
assert unknown == {"data": []}, "unknown uri should yield empty data"
print("semtokens OK: %d tokens, classifications verified" % (len(data) // 5))
PY
