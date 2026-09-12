#!/usr/bin/env bash
# E04: selection ranges — word -> line -> enclosing blocks -> document, with a
# strict containment invariant, for every requested position; unknown URIs and
# whitespace positions are handled without malformed output.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
DOC = ('def outer() -> void:\n'      # 0
       '    x: i64 = 1\n'            # 1
       '    if x > 0:\n'             # 2
       '        y: i64 = 2\n'        # 3
       '        while y > 0:\n'      # 4
       '            y <- y - 1\n'    # 5
       '    return\n')               # 6
def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def select(positions, uri="file:///sel.elisa"):
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":"file:///sel.elisa","languageId":"Elisa","version":1,"text":DOC}}})
    m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/selectionRange",
                "params":{"textDocument":{"uri":uri},"positions":positions}})
    m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    p = subprocess.run([srv], input=m, capture_output=True, timeout=30)
    assert p.returncode == 0
    out, pos, res = p.stdout, 0, None
    while pos < len(out):
        sep = out.find(b"\r\n\r\n", pos)
        ln = int(out[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(out[start:start+ln])  # every frame must be valid JSON
        if msg.get("id") == 2: res = msg["result"]
        pos = start+ln
    return res
def chain(r):
    out = []
    while r is not None:
        rg = r["range"]
        out.append(((rg["start"]["line"], rg["start"]["character"]),
                    (rg["end"]["line"], rg["end"]["character"])))
        r = r.get("parent")
    return out

nlines = len(DOC.split("\n")) - 1  # final newline -> last addressable line
res = select([{"line":5,"character":12},{"line":1,"character":4},{"line":6,"character":0}])
assert len(res) == 3, res
chains = [chain(r) for r in res]

# Containment invariant for every chain, and the outermost is the document.
for c in chains:
    assert len(c) >= 2, c
    for inner, outer in zip(c, c[1:]):
        assert inner[0] >= outer[0] and inner[1] <= outer[1], f"not contained: {inner} !in {outer}"
    assert c[-1] == ((0, 0), (nlines, 0)) or c[-1][0] == (0, 0), f"root must start at document: {c[-1]}"
    assert c[-1][1][0] >= nlines - 1, f"root must end near document end: {c[-1]}"

# Word -> line -> while-block -> if-block -> function -> document.
expected = [((5,12),(5,13)), ((5,0),(5,22)), ((4,0),(5,22)), ((2,0),(5,22)), ((0,0),(6,10)), ((0,0),(7,0))]
assert chains[0] == expected, f"nested chain wrong:\n{chains[0]}\n{expected}"

# Word on line 1 nests directly under its line then the function block.
assert chains[1][0] == ((1,4),(1,5)), chains[1]
assert chains[1][1] == ((1,0),(1,14)), chains[1]
assert chains[1][-1][0] == (0,0), chains[1]

# Whitespace position still yields line/block/document ranges (zero-width inner).
assert chains[2][0] == ((6,0),(6,0)), chains[2]
assert chains[2][1] == ((6,0),(6,10)), chains[2]

# Unknown URI -> empty list; no crash.
assert select([{"line":0,"character":0}], uri="file:///absent.elisa") == []

print("selection OK: nested word/line/block/document with containment")
PY
