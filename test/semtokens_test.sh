#!/usr/bin/env bash
# semanticTokens/full: legend advertised at initialize; a didOpen'd document
# tokenizes into correctly classified, delta-encoded tokens.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, re, sys
def frame(o):
    b = json.dumps(o)
    return f"Content-Length: {len(b)}\r\n\r\n{b}".encode()
doc = "def demo(a: i64, b: u32) -> bool:\n    x: mutable f64 = 2.5\n    x <- 3.0\n    if a > 5:\n        return true\n    return false\n"
m  = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.elisa","languageId":"Elisa","version":1,"text":doc}}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///t.elisa"}}})
m += frame({"jsonrpc":"2.0","id":3,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///other.elisa"}}})
m += frame({"jsonrpc":"2.0","method":"exit"})
out = subprocess.run([sys.argv[1]], input=m, capture_output=True, timeout=30).stdout.decode(errors="replace")

assert '"semanticTokensProvider"' in out and '"elisa.type.int.signed"' in out, "legend not advertised"
mm = re.search(r'"id":2,"result":\{"data":\[([^\]]*)\]', out)
assert mm, "no tokens response"
data = [int(x) for x in mm.group(1).split(",") if x.strip()]
assert len(data) % 5 == 0 and len(data) >= 5*10, f"suspicious token count: {len(data)//5}"
# decode + spot-check classifications (legend indices from semtokens.elisa)
toks = []
line = col = 0
for i in range(0, len(data), 5):
    dl, dc, ln, tt, mods = data[i:i+5]
    line += dl; col = (col + dc) if dl == 0 else dc
    toks.append((line, col, ln, tt))
    assert mods == 0
lines = doc.split("\n")
def tok_text(t): return lines[t[0]][t[1]:t[1]+t[2]]
by_text = {tok_text(t): t[3] for t in toks}
assert by_text["demo"] == 13, "def-site name should be fn.def"
assert by_text["i64"] == 0 and by_text["u32"] == 1, "integral families"
assert by_text["f64"] == 2 and by_text["bool"] == 3
assert by_text["2.5"] == 9 and by_text["<-"] == 34 and by_text["mutable"] == 34
assert by_text["true"] == 12 and by_text["if"] == 27
# unknown uri -> empty
mm3 = re.search(r'"id":3,"result":\{"data":\[([^\]]*)\]', out)
assert mm3 and mm3.group(1).strip() == "", "unknown uri should yield empty data"
print("semtokens OK: %d tokens, classifications verified" % (len(data)//5))
PY
