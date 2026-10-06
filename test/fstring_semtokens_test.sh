#!/usr/bin/env bash
# semanticTokens/full over an f-string: the token expands into fine-grained
# spans — literal chunks (incl. `f"` prefix + closing quote) as string literals,
# `{`/`}` as punctuation, and the interpolated expression classified as real code
# (`{name}` -> a param reference, `{b.c}` -> local + field). Escaped `{{`/`}}`
# stay part of the surrounding string run. Non-overlapping, source-ordered.
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
deep_expr = 'f"leaf {name}"'
for _ in range(17):
    deep_expr = 'f"outer {' + deep_expr + '}"'
# line1: single interpolation; line2: escaped braces + two interpolations w/ field access
doc = ('def f(name: i64, b: i64) -> i64:\n'
       '    msg: dstr = f"hi {name}!"\n'
       '    two: dstr = f"{{x}} {name} {b}"\n'
       '    return name\n'
       '\n'
       'enum Event:\n'
       '    None\n'
       '\n'
       'def event_text(event: Event) -> dstr:\n'
       '    return f"event={Event.None}"\n'
       'def char_interp(name: i64) -> dstr:\n'
       "    return f\"char={'}'} {name}\"\n"
       'def escaped_char_interp(name: i64) -> dstr:\n'
       "    return f\"escaped={'\\\\'} {name}\"\n"
       'def nested_string_interp(name: i64) -> dstr:\n'
       '    return f"nested={"brace }"} {name}"\n'
       'def incomplete_interp(name: i64) -> dstr:\n'
       '    return f"open {name\n'
       'def unicode_interp(name: i64) -> dstr:\n'
       '    return f"før={"inne } ø"} {name}"\n'
       'def nested_fstring(name: i64) -> dstr:\n'
       '    return f"outer {f"inner {name}"}"\n'
       'def deep_nested_fstring(name: i64) -> dstr:\n'
       f'    return {deep_expr}\n')
lines = doc.split("\n")

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": "file:///t.elisa",
            "languageId": "Elisa",
            "version": 1,
            "text": doc,
        }
    })
    response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": "file:///t.elisa"},
    }, timeout=30)
    assert "result" in response, response
    data = response["result"]["data"]
    char_line = 11
    name_start = lines[char_line].rindex("name")
    references = client.request("textDocument/references", {
        "textDocument": {"uri": "file:///t.elisa"},
        "position": {"line": char_line, "character": name_start + 1},
        "context": {"includeDeclaration": True},
    }, timeout=30)
    assert "result" in references, references
    nested_references = client.request("textDocument/references", {
        "textDocument": {"uri": "file:///t.elisa"},
        "position": {"line": 21, "character": lines[21].rindex("name") + 1},
        "context": {"includeDeclaration": True},
    }, timeout=30)
    assert "result" in nested_references, nested_references
    nested_definition = client.request("textDocument/definition", {
        "textDocument": {"uri": "file:///t.elisa"},
        "position": {"line": 21, "character": lines[21].rindex("name") + 1},
    }, timeout=30)
    assert "result" in nested_definition, nested_definition
    client.finish(timeout=30)
assert len(data) % 5 == 0

ST_LIT_STRING, ST_PUNCTUATION = 11, 41
ST_BIND_PARAM, ST_BIND_LOCAL, ST_BIND_FIELD = 16, 17, 18
ST_LIT_CHAR, ST_ENUM_VARIANT = 10, 47

def decode_tokens(data):
    assert len(data) % 5 == 0
    tokens = []
    line = col = 0
    for i in range(0, len(data), 5):
        dl, dc, length, token_type, modifiers = data[i:i + 5]
        line += dl
        col = (col + dc) if dl == 0 else dc
        assert modifiers == 0
        tokens.append((line, col, length, token_type))
    return tokens


toks = decode_tokens(data)

char_line = 11


def protocol_units(value, encoding):
    if encoding == "utf-8":
        return len(value.encode("utf-8"))
    return len(value.encode("utf-16-le")) // 2


def text(t, encoding="utf-16"):
    line = lines[t[0]]
    def python_index(protocol_column):
        units = 0
        for index, char in enumerate(line):
            if units == protocol_column:
                return index
            units += protocol_units(char, encoding)
        assert units == protocol_column, (line, protocol_column, units, encoding)
        return len(line)
    start = python_index(t[1])
    end = python_index(t[1] + t[2])
    return line[start:end]


def protocol_column(line, python_index, encoding="utf-16"):
    return protocol_units(line[:python_index], encoding)


# Every emitted token must be nonempty, in-bounds, and aligned to UTF-16 source
# boundaries before any feature-specific span expectations are checked.
for token in toks:
    token_line, token_col, token_length = token[:3]
    assert 0 <= token_line < len(lines), token
    line_units = protocol_units(lines[token_line], "utf-16")
    assert token_col >= 0 and token_length > 0 and token_col + token_length <= line_units, token
    text(token)


# Non-overlapping + strictly source-ordered (LSP requires this).
for a, b in zip(toks, toks[1:]):
    assert (b[0], b[1]) >= (a[0], a[1]), f"tokens out of order: {a} then {b}"
    if b[0] == a[0]:
        assert b[1] >= a[1] + a[2], f"overlap: {a} ({text(a)!r}) and {b} ({text(b)!r})"

# --- line 1: f"hi {name}!" ---
l1 = [t for t in toks if t[0] == 1]
seq1 = [(text(t), t[3]) for t in l1 if t[1] >= 16]  # from the `f` onward
assert seq1 == [('f"hi ', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                ('name', ST_BIND_PARAM), ('}', ST_PUNCTUATION),
                ('!"', ST_LIT_STRING)], f"line1 spans wrong: {seq1}"

# --- line 2: f"{{x}} {name} {b}" — escaped braces stay literal ---
l2 = [t for t in toks if t[0] == 2]
seq2 = [(text(t), t[3]) for t in l2 if t[1] >= 16]
# leading chunk holds the escaped `{{x}}`; two real interpolations follow.
assert seq2[0] == ('f"{{x}} ', ST_LIT_STRING), f"escaped-brace chunk wrong: {seq2[0]}"
kinds = [k for _, k in seq2]
assert kinds.count(ST_PUNCTUATION) == 4, f"expected 4 brace spans, got {seq2}"
names = [txt for txt, _ in seq2]
assert 'name' in names and 'b' in names, f"interpolated idents missing: {seq2}"
# the interpolated identifiers classify as bindings, not as string content.
for txt, k in seq2:
    if txt == 'name': assert k == ST_BIND_PARAM
    if txt == 'b':    assert k == ST_BIND_PARAM

# --- line 9: qualified enum variant inside an interpolation ---
l9 = [t for t in toks if t[0] == 9]
assert ('None', ST_ENUM_VARIANT) in [(text(t), t[3]) for t in l9], \
       f"enum variant interpolation missing: {[(text(t), t[3]) for t in l9]}"

# A right brace inside a single-quoted character literal is part of the
# expression. It must not close the interpolation or consume the following
# parameter interpolation, which must keep its exact resolver identity.
l11 = [t for t in toks if t[0] == char_line]
seq11 = [(text(t), t[3]) for t in l11 if t[1] >= lines[char_line].index('f"')]
assert seq11 == [('f"char=', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ("'}'", ST_LIT_CHAR), ('}', ST_PUNCTUATION),
                 (' ', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ('name', ST_BIND_PARAM), ('}', ST_PUNCTUATION),
                 ('"', ST_LIT_STRING)], f"char-literal interpolation spans wrong: {seq11}"
name_start = lines[char_line].rindex("name")
expected_references = [
    {"uri": "file:///t.elisa", "range": {
        "start": {"line": 10, "character": lines[10].index("name")},
        "end": {"line": 10, "character": lines[10].index("name") + 4},
    }},
    {"uri": "file:///t.elisa", "range": {
        "start": {"line": char_line, "character": name_start},
        "end": {"line": char_line, "character": name_start + 4},
    }},
]
assert references["result"] == expected_references, references

# Query the nested use against its own function's parameter, rather than a
# same-spelled parameter from another function. This distinguishes missed
# interpolation occurrences from correct BindingId/scope isolation.
expected_nested_references = [
    {"uri": "file:///t.elisa", "range": {
        "start": {"line": 20, "character": lines[20].index("name")},
        "end": {"line": 20, "character": lines[20].index("name") + 4},
    }},
    {"uri": "file:///t.elisa", "range": {
        "start": {"line": 21, "character": lines[21].rindex("name")},
        "end": {"line": 21, "character": lines[21].rindex("name") + 4},
    }},
]
assert nested_references["result"] == expected_nested_references, nested_references
expected_nested_definition = {"uri": "file:///t.elisa", "range": {
    "start": {"line": 20, "character": lines[20].index("name")},
    "end": {"line": 20, "character": lines[20].index("name") + 4},
}}
assert nested_definition["result"] == expected_nested_definition, nested_definition

# Backslash-escaped content inside a character literal must not end the quote
# scan early; the following interpolation must still be a separate expression.
escaped_line = 13
l13 = [t for t in toks if t[0] == escaped_line]
seq13 = [(text(t), t[3]) for t in l13 if t[1] >= lines[escaped_line].index('f"')]
assert seq13 == [('f"escaped=', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 (r"'\\'", ST_LIT_CHAR), ('}', ST_PUNCTUATION),
                 (' ', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ('name', ST_BIND_PARAM), ('}', ST_PUNCTUATION),
                 ('"', ST_LIT_STRING)], f"escaped-char interpolation spans wrong: {seq13}"

# Quotes nested in the expression protect braces from ending the interpolation.
nested_line = 15
l15 = [t for t in toks if t[0] == nested_line]
seq15 = [(text(t), t[3]) for t in l15 if t[1] >= lines[nested_line].index('f"')]
assert seq15 == [('f"nested=', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ('"brace }"', ST_LIT_STRING), ('}', ST_PUNCTUATION),
                 (' ', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ('name', ST_BIND_PARAM), ('}', ST_PUNCTUATION),
                 ('"', ST_LIT_STRING)], f"nested-string interpolation spans wrong: {seq15}"

# An unfinished interpolation still yields bounded, ordered spans and does not
# invent a closing brace or consume bytes beyond the incomplete source line.
malformed_line = 17
l17 = [t for t in toks if t[0] == malformed_line]
seq17 = [(text(t), t[3]) for t in l17 if t[1] >= lines[malformed_line].index('f"')]
assert seq17 == [('f"open ', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ('name', ST_BIND_PARAM)], f"incomplete interpolation spans wrong: {seq17}"

# Source text before and inside interpolations may be non-ASCII. Semantic-token
# positions are UTF-16 units, so text reconstruction above checks code-point
# boundaries instead of accidentally slicing Python strings by protocol units.
unicode_line = 19
l19 = [t for t in toks if t[0] == unicode_line]
f_column = protocol_column(lines[unicode_line], lines[unicode_line].index('f"'))
seq19 = [(text(t), t[3]) for t in l19 if t[1] >= f_column]
assert seq19 == [('f"før=', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ('"inne } ø"', ST_LIT_STRING), ('}', ST_PUNCTUATION),
                 (' ', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ('name', ST_BIND_PARAM), ('}', ST_PUNCTUATION),
                 ('"', ST_LIT_STRING)], f"unicode interpolation spans wrong: {seq19}"

# Nested f-strings are valid compiler syntax. Their inner literal, braces, and
# resolved interpolation must be expanded recursively at absolute source spans.
nested_line = 21
l21 = [t for t in toks if t[0] == nested_line]
f_column21 = protocol_column(lines[nested_line], lines[nested_line].index('f"'))
seq21 = [(text(t), t[3]) for t in l21 if t[1] >= f_column21]
assert seq21 == [('f"outer ', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ('f"inner ', ST_LIT_STRING), ('{', ST_PUNCTUATION),
                 ('name', ST_BIND_PARAM), ('}', ST_PUNCTUATION),
                 ('"', ST_LIT_STRING), ('}', ST_PUNCTUATION),
                 ('"', ST_LIT_STRING)], f"nested f-string spans wrong: {seq21}"

# Expansion has a hard recursion bound. At extreme nesting, the deepest f-string
# is kept as one string span, while all surrounding spans remain ordered/bounded.
deep_line = 23
deep_spans = [t for t in toks if t[0] == deep_line]
assert any(t[3] == ST_LIT_STRING and 'name' in text(t) for t in deep_spans), \
       f"deep f-string recursion fallback missing: {[(text(t), t[3]) for t in deep_spans]}"

# Repeat the same Unicode interpolation with UTF-8 position encoding negotiated.
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {"general": {
        "positionEncodings": ["utf-8"]
    }}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": "file:///utf8.elisa",
            "languageId": "Elisa",
            "version": 1,
            "text": doc,
        }
    })
    response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": "file:///utf8.elisa"},
    }, timeout=30)
    assert "result" in response, response
    data_utf8 = response["result"]["data"]
    client.finish(timeout=30)

toks_utf8 = decode_tokens(data_utf8)
l19_utf8 = [t for t in toks_utf8 if t[0] == unicode_line]
f_column_utf8 = protocol_column(lines[unicode_line], lines[unicode_line].index('f"'), "utf-8")
seq19_utf8 = [(text(t, "utf-8"), t[3]) for t in l19_utf8 if t[1] >= f_column_utf8]
assert seq19_utf8 == seq19, f"UTF-8 interpolation spans differ: {seq19_utf8}"

print("fstring semtokens OK: %d spans; interpolations coloured as code" % len(toks))
PY
