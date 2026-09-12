#!/usr/bin/env bash
# F01: general hover — declarations and param/local bindings resolve under the
# cursor with the correct precedence, exact range, cursor boundary policy,
# markdown/plaintext kinds, and null for unknown identifiers/keywords.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
DOC = ('def alpha(x: i64) -> i64:\n'      # 0
       '    local: i64 = x\n'             # 1
       '    return local\n\n'             # 2
       'struct Point:\n'                   # 3
       '    x: i64\n')                    # 4
def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def hover(line, ch, caps=None):
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":caps or {}}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":"file:///g.elisa","languageId":"Elisa","version":1,"text":DOC}}})
    m += frame({"jsonrpc":"2.0","id":9,"method":"textDocument/hover",
                "params":{"textDocument":{"uri":"file:///g.elisa"},"position":{"line":line,"character":ch}}})
    m += frame({"jsonrpc":"2.0","id":99,"method":"shutdown"})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    p = subprocess.run([srv], input=m, capture_output=True, timeout=30)
    assert p.returncode == 0, f"exit {p.returncode}"
    out, pos, res = p.stdout, 0, None
    while pos < len(out):
        sep = out.find(b"\r\n\r\n", pos)
        ln = int(out[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(out[start:start+ln])  # every frame valid JSON
        if msg.get("id") == 9: res = msg["result"]
        pos = start+ln
    return res

# 1. A top-level function shows its declaration and declared return type.
r = hover(0, 5)
assert r and r["contents"]["value"] == "def alpha -> i64", r
assert r["contents"]["kind"] == "markdown", r["contents"]["kind"]
rg = r["range"]
assert (rg["start"]["line"], rg["start"]["character"]) == (0, 4), rg
assert (rg["end"]["line"], rg["end"]["character"]) == (0, 9), rg

# 2. A parameter and a local (declaration and reference) win over any symbol.
assert hover(0, 10)["contents"]["value"] == "(parameter) x"
assert hover(1, 5)["contents"]["value"] == "(local) local"
assert hover(2, 11)["contents"]["value"] == "(local) local"

# 3. A struct name shows its category.
assert hover(4, 8)["contents"]["value"] == "struct Point"

# 4. Unknown identifiers and keywords hover null (the loop-header fallback is
#    separate and not triggered here).
assert hover(0, 0) is None, hover(0, 0)

# 5. Cursor at the END of a token still hovers it (boundary policy).
assert hover(0, 9)["contents"]["value"] == "def alpha -> i64", hover(0, 9)

# 6. plaintext clients get plaintext content.
r = hover(0, 5, {"textDocument":{"hover":{"contentFormat":["plaintext"]}}})
assert r["contents"]["kind"] == "plaintext", r["contents"]

# 7. Unknown/closed documents hover null (no cross-URI leakage).
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","id":9,"method":"textDocument/hover",
            "params":{"textDocument":{"uri":"file:///absent.elisa"},"position":{"line":0,"character":0}}})
m += frame({"jsonrpc":"2.0","id":99,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = subprocess.run([srv], input=m, capture_output=True, timeout=30)
assert b'"id":9,"result":null' in p.stdout, p.stdout[:200]

print("general hover OK: declaration, precedence, range, boundary, kinds, null")
PY
