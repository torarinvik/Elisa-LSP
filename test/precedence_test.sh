#!/usr/bin/env bash
# H02: exact semantic precedence — a resolved param/local binding wins over
# keyword/type spelling (contextual keywords as names), shadowing a top-level
# declaration works, and member access stays a field.
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
ST_BIND_PARAM, ST_BIND_LOCAL, ST_BIND_FIELD = 16, 17, 18
ST_TYPE_USER, ST_DECL_SKELETON = 6, 30
ST_FN_DEF, ST_FN_USE = 13, 14
URI = "file:///prec.elisa"


def classify(text):
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": {}})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": URI,
                "languageId": "Elisa",
                "version": 1,
                "text": text,
            }
        })
        response = client.request("textDocument/semanticTokens/full", {
            "textDocument": {"uri": URI},
        }, timeout=30)
        assert "result" in response, response
        data = response["result"]["data"]
        client.finish(timeout=30)
    lines = text.split("\n")
    line = col = 0
    found = []
    for i in range(0, len(data), 5):
        dl, dc, length, tt, _ = data[i:i + 5]
        line += dl
        col = (col + dc) if dl == 0 else dc
        found.append((line, col, lines[line][col:col + length], tt))
    return found


# 1. Contextual keywords used as parameters keep the binding kind everywhere.
doc = ('def f(get: i64, of: i64, at: i64) -> i64:\n'
       '    return get + of + at\n')
toks = classify(doc)
occ = [(ln, txt, tt) for (ln, _c, txt, tt) in toks if txt in ("get", "of", "at")]
assert len(occ) == 6, f"expected 6 occurrences: {occ}"
for ln, txt, tt in occ:
    assert tt == ST_BIND_PARAM, f"contextual-keyword param {txt!r} on line {ln} must be bind.param, got {tt}"

# 2. A local shadowing a top-level type resolves to the local binding.
doc = ('struct Thing:\n    x: i64\n\n'
       'def g() -> i64:\n'
       '    Thing: i64 = 5\n'
       '    return Thing\n')
toks = classify(doc)
thing = [(ln, tt) for (ln, _c, txt, tt) in toks if txt == "Thing"]
assert (0, ST_TYPE_USER) in thing, f"struct name must stay type.user: {thing}"
local_lines = [ln for ln, tt in thing if ln >= 4]
assert local_lines, thing
for ln in local_lines:
    tt = [t for l, t in thing if l == ln][0]
    assert tt == ST_BIND_LOCAL, f"shadowing local Thing on line {ln} must be bind.local, got {tt}"

# 3. Member access is a field even when the member name is a contextual keyword.
doc = ('struct P:\n    at: i64\n\n'
       'def h(p: P) -> i64:\n'
       '    return p.at\n')
toks = classify(doc)
member = [(ln, tt) for (ln, _c, txt, tt) in toks if txt == "at" and ln == 4]
assert member and member[0][1] == ST_BIND_FIELD, f"`.at` member must be bind.field: {toks}"

# 4. A resolved contextual-keyword-named function is classified by the exact
# compiler reference edge, including when its absolute span comes from an
# f-string sublexer. Spelling alone would incorrectly color `get` as a keyword.
doc = ('def get(value: i64) -> i64:\n'
       '    return value\n'
       'def caller() -> dstr:\n'
       '    return f"value={get(1)}"\n')
toks = classify(doc)
get_tokens = [(ln, tt) for (ln, _c, txt, tt) in toks if txt == "get"]
assert get_tokens == [(0, ST_FN_DEF), (3, ST_FN_USE)], (
    f"exact resolved `get` declaration/use must beat keyword spelling in normal and interpolated syntax: {get_tokens}"
)

# `fn` is also a legal function name. Exact resolution must beat the lexical
# lambda category when this is a call; semtoken_families_test separately checks
# that actual `fn(...) => ...` lambda syntax keeps the lambda category.
doc = ('def fn(value: i64) -> i64:\n'
       '    return value\n'
       'def caller() -> i64:\n'
       '    return fn(1)\n')
toks = classify(doc)
fn_tokens = [(ln, tt) for (ln, _c, txt, tt) in toks if txt == "fn"]
assert fn_tokens == [(0, ST_FN_DEF), (3, ST_FN_USE)], (
    f"exact resolved `fn` declaration/use must remain distinct from lambda syntax: {fn_tokens}"
)

print("precedence OK: exact function targets, contextual spelling, lambda syntax, bindings, shadowing, members and interpolation")
PY
