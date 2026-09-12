#!/usr/bin/env bash
# H02: exact semantic precedence — a resolved param/local binding wins over
# keyword/type spelling (contextual keywords as names), shadowing a top-level
# declaration works, and member access stays a field.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
ST_BIND_PARAM, ST_BIND_LOCAL, ST_BIND_FIELD = 16, 17, 18
ST_TYPE_USER, ST_DECL_SKELETON = 6, 30
def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def classify(text):
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":"file:///prec.elisa","languageId":"Elisa","version":1,"text":text}}})
    m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
                "params":{"textDocument":{"uri":"file:///prec.elisa"}}})
    m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    p = subprocess.run([srv], input=m, capture_output=True, timeout=30)
    assert p.returncode == 0
    out, pos, data = p.stdout, 0, None
    while pos < len(out):
        sep = out.find(b"\r\n\r\n", pos)
        ln = int(out[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(out[start:start+ln])
        if msg.get("id") == 2:
            data = msg["result"]["data"]
        pos = start+ln
    lines = text.split("\n")
    line = col = 0
    found = []
    for i in range(0, len(data), 5):
        dl, dc, ln, tt, _ = data[i:i+5]
        line += dl; col = (col + dc) if dl == 0 else dc
        found.append((line, col, lines[line][col:col+ln], tt))
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

print("precedence OK: bindings beat keyword spelling; shadowing; members stay fields")
PY
