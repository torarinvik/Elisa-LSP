#!/usr/bin/env bash
# B03: exact source-occurrence checks covering every entry in the 48-type semantic-token legend.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

source = '''# family comment
const Limit: i64 = 4
const Ratio: f64 = 2.5
const Letter: char = 'x'
const Title: dstr = "elisa"
struct Box:
    value: i64

enum Choice:
    Ready

def choose() -> Choice:
    return Choice.Ready

def family(v: Box, xs: darray[i64]) -> void can[Abort.Panic, Unsafe]:
    requires true
    count: i64 = 0
    item: i64 = v.value
    if count == 0 and not false:
        count <- count + 1
    for i in 0..<2:
        pass
    return

def bits(a: i64, b: i64) -> i64:
    return (a | b) ^ ~a

def typed(value: u32, real: f64, flag: bool, label: dstr, glyph: char) -> i64:
    return called()

def called() -> i64:
    return 1

@inline
def annotated(x: i64) -> i64:
    return fn(y: i64) => y

def lambda_type() -> fn(i64) -> i64:
    return fn(z: i64) => z

def move_value(xs: darray[i64]) -> darray[i64]:
    return move xs

def region_value() -> void:
    region scratch:
        pass
    return

def concurrent_value() -> void:
    nursery:
        pass
    return

def error_flow() -> void:
    try:
        pass
    return

def discard(value: bool) -> i64:
    match value:
        _:
            return 0

def proof_names() -> void:
    forall
    ghost
    raises
    return

module math:
    def member() -> i64:
        return 1

static if true:
    const Feature: i64 = 1
'''
uri = "file:///semtoken-families.elisa"

with LspSession(sys.argv[1], request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    legend = initialized["result"]["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"]
    assert len(legend) == 48, legend
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": 1,
            "text": source,
        }
    })
    response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    }, timeout=30)
    assert "result" in response, (response, client.stderr_text())
    data = response["result"]["data"]
    client.finish(timeout=30)

lines = source.splitlines()
tokens = []
checked_categories = set()
line_no = column = 0
for offset in range(0, len(data), 5):
    delta_line, delta_column, length, token_type, _modifiers = data[offset:offset + 5]
    line_no += delta_line
    column = column + delta_column if delta_line == 0 else delta_column
    tokens.append((line_no, column, length, token_type))


def expect(line_fragment: str, spelling: str, category: str, occurrence: int = 0) -> None:
    matching_lines = [index for index, line in enumerate(lines) if line_fragment in line]
    assert len(matching_lines) == 1, (line_fragment, matching_lines)
    source_line = matching_lines[0]
    positions = []
    cursor = 0
    while True:
        found = lines[source_line].find(spelling, cursor)
        if found < 0:
            break
        positions.append(found)
        cursor = found + len(spelling)
    assert occurrence < len(positions), (line_fragment, spelling, positions)
    source_column = positions[occurrence]
    matches = [
        kind for token_line, token_column, length, kind in tokens
        if token_line == source_line and token_column == source_column and length == len(spelling)
    ]
    assert len(matches) == 1, (line_fragment, spelling, matches)
    actual = lines[source_line][source_column:source_column + len(spelling)]
    assert actual == spelling, (line_fragment, spelling, actual)
    assert matches[0] == legend.index(category), (
        line_fragment, spelling, category, legend[matches[0]],
    )
    checked_categories.add(matches[0])


# Type, literal, declaration, binding, and member families supplement the
# occurrence-specific enum, repeated-name, and alias cases in semtokens_test.sh.
expect("const Limit", "const", "elisa.decl.skeleton")
expect("const Limit", "Limit", "elisa.bind.global")
expect("const Limit", "i64", "elisa.type.int.signed")
expect("const Limit", "4", "elisa.lit.int", occurrence=1)
expect("const Ratio", "f64", "elisa.type.float")
expect("const Ratio", "2.5", "elisa.lit.float")
expect("const Letter", "char", "elisa.type.scalar")
expect("const Letter", "'x'", "elisa.lit.char")
expect("const Title", "dstr", "elisa.type.string")
expect("const Title", '"elisa"', "elisa.lit.string")
expect("struct Box", "Box", "elisa.type.user")
expect("enum Choice", "enum", "elisa.decl.skeleton")
expect("    Ready", "Ready", "elisa.enum.variant")
expect("value: i64", "value", "elisa.bind.local")
expect("family(v: Box, xs: darray", "darray", "elisa.type.container")
expect("-> void can", "void", "elisa.type.void")
expect("v.value", "value", "elisa.bind.field")
expect("can[Abort", "can", "elisa.effect.grant")
expect("can[Abort", "Abort", "elisa.effect.name")
expect("can[Abort", "Panic", "elisa.effect.name")
expect("can[Abort", "Unsafe", "elisa.effect.unsafe")
expect("requires true", "requires", "elisa.contract.clause")
expect("if count ==", "if", "elisa.flow.branch")
expect("if count ==", "==", "elisa.op.comparison")
expect("if count ==", "and", "elisa.op.logical")
expect("if count ==", "not", "elisa.op.logical")
expect("if count ==", "false", "elisa.lit.value")
expect("count <-", "<-", "elisa.op.mutation")
expect("count <-", "+", "elisa.op.arithmetic")
expect("for i in", "for", "elisa.flow.branch")
expect("for i in", "..<", "elisa.op.range")
expect("return (a |", "|", "elisa.op.bitwise")
expect("return (a |", "^", "elisa.op.bitwise")
expect("return (a |", "~", "elisa.op.bitwise")
expect("def typed", "u32", "elisa.type.int.unsigned")
expect("def typed", "value", "elisa.bind.param")
expect("def typed", "bool", "elisa.type.scalar")
expect("return called", "called", "elisa.fn.use")
expect("def family", "family", "elisa.fn.def")
expect("const Limit", "=", "elisa.op.assign")
expect("# family comment", "# family comment", "elisa.comment")
expect("value: i64", ":", "elisa.punctuation")
expect("@inline", "@", "elisa.meta.decorator")
expect("@inline", "inline", "elisa.meta.decorator")
expect("return fn(y", "fn", "elisa.fn.lambda")
expect("return fn(y", "=>", "elisa.op.lambda")
expect("return move", "move", "elisa.mem.qualifier")
expect("region scratch", "region", "elisa.mem.region")
expect("nursery:", "nursery", "elisa.flow.concurrent")
expect("try:", "try", "elisa.flow.error")
expect("        _:", "_", "elisa.bind.discard")
expect("    forall", "forall", "elisa.contract.quantifier")
expect("    ghost", "ghost", "elisa.contract.ghost")
expect("    raises", "raises", "elisa.effect.error")
expect("module math", "module", "elisa.decl.skeleton")
expect("module math", "math", "elisa.meta.module")
expect("static if", "static", "elisa.meta.directive")
expect("static if", "true", "elisa.lit.value")

assert checked_categories == set(range(48)), (
    "the exact-span fixture must cover every legend category; missing indices: "
    + repr(sorted(set(range(48)) - checked_categories))
)

print(f"semantic-token family coverage OK: {len(tokens)} exact spans cover all {len(checked_categories)} categories")
PY
