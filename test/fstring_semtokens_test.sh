#!/usr/bin/env bash
# semanticTokens/full over an f-string: the token expands into fine-grained
# spans — literal chunks (incl. `f"` prefix + closing quote) as string literals,
# `{`/`}` as punctuation, and the interpolated expression classified as real code
# (`{name}` -> a param reference, `{b.c}` -> local + field). Escaped `{{`/`}}`
# stay part of the surrounding string run. Non-overlapping, source-ordered.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, re, sys
def frame(o):
    b = json.dumps(o); return f"Content-Length: {len(b)}\r\n\r\n{b}".encode()
# line1: single interpolation; line2: escaped braces + two interpolations w/ field access
doc = ('def f(name: i64, b: i64) -> i64:\n'
       '    msg: dstr = f"hi {name}!"\n'
       '    two: dstr = f"{{x}} {name} {b}"\n'
       '    return name\n')
m  = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.elisa","languageId":"Elisa","version":1,"text":doc}}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///t.elisa"}}})
m += frame({"jsonrpc":"2.0","method":"exit"})
out = subprocess.run([sys.argv[1]], input=m, capture_output=True, timeout=30).stdout.decode(errors="replace")
mm = re.search(r'"id":2,"result":\{"data":\[([^\]]*)\]', out)
assert mm, "no tokens response"
data = [int(x) for x in mm.group(1).split(",") if x.strip()]
assert len(data) % 5 == 0

ST_LIT_STRING, ST_PUNCTUATION = 11, 41
ST_BIND_PARAM, ST_BIND_LOCAL, ST_BIND_FIELD = 16, 17, 18

toks = []
line = col = 0
for i in range(0, len(data), 5):
    dl, dc, ln, tt, mods = data[i:i+5]
    line += dl; col = (col + dc) if dl == 0 else dc
    assert mods == 0
    toks.append((line, col, ln, tt))

lines = doc.split("\n")
def text(t): return lines[t[0]][t[1]:t[1]+t[2]]

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

print("fstring semtokens OK: %d spans; interpolations coloured as code" % len(toks))
PY
