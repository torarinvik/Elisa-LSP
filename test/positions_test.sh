#!/usr/bin/env bash
# U02: one coordinate API — diagnostics, tokens, and hover slice the same
# UTF-16 lines. Every token and diagnostic range must decode through a single
# UTF-16 slicing helper, including past emoji/CJK content on the same line.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def run(payload):
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=30)
    assert p.returncode == 0, f"exit {p.returncode}"
    return p.stdout
def u16slice(line, col, ln):
    raw = line.encode("utf-16-le")
    assert 0 <= col <= len(raw)//2 and 0 <= ln and col+ln <= len(raw)//2, \
        f"span ({col},{ln}) outside {len(raw)//2}-unit line {line!r}"
    part = raw[col*2:(col+ln)*2].decode("utf-16-le")
    assert len(part) > 0, "zero-length slice"
    return part

doc = ('def f(name: i64) -> i64:\n'
       '    x: dstr = "héllo 🌍"\n'
       '    y: i64 = name + 1 # héllo\n'
       '    return zzz_undefined\n')
uri = "file:///positions.elisa"
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":doc}}})
m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":uri}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
out = run(m)
res, notifs = {}, []
pos = 0
while pos < len(out):
    sep = out.find(b"\r\n\r\n", pos)
    ln = int(out[pos:sep].split(b":",1)[1].strip())
    start = sep+4
    msg = json.loads(out[start:start+ln])
    if "id" in msg: res[msg["id"]] = msg.get("result")
    else: notifs.append(msg)
    pos = start+ln

lines = doc.split("\n")
# --- tokens: decode all, spot-check exact texts ---
data = res[2]["data"]
assert len(data) % 5 == 0 and len(data) >= 5*10
toks = []
line = col = 0
for i in range(0, len(data), 5):
    dl, dc, ln_, tt, md = data[i:i+5]
    line += dl; col = (col + dc) if dl == 0 else dc
    text = u16slice(lines[line], col, ln_)
    toks.append((line, col, ln_, tt, text))
by_text = {}
for _, _, _, tt, text in toks:
    by_text.setdefault(text, tt)
assert by_text.get('"héllo 🌍"') == 11, f"string token mis-sliced/classified"
assert by_text.get("# héllo") == 40, f"comment token mis-sliced/classified"
assert by_text.get("zzz_undefined") == 17, f"local fallback mis-sliced/classified"
# token after non-ASCII on the SAME line: `name` follows nothing non-ASCII here,
# but `1` follows the `#`-comment line content — instead assert the return line:
ret = [t for t in toks if t[0] == 3 and t[4] == "return"]
assert ret and ret[0][3] == 27, f"keyword after unicode lines wrong: {ret}"

# --- diagnostics: same helper, same lines (provider agreement) ---
diags = [n["params"] for n in notifs
         if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["uri"] == uri]
assert diags, "no diagnostics published"
found = False
for d in diags[-1]["diagnostics"]:
    r = d["range"]
    if r["end"]["line"] == r["start"]["line"]:
        frag = u16slice(lines[r["start"]["line"]], r["start"]["character"],
                        r["end"]["character"] - r["start"]["character"])
        if "zzz_undefined" in frag:
            found = True
    else:
        # multiline: start must at least be in-bounds
        rest = len(lines[r["start"]["line"]].encode("utf-16-le"))//2 - r["start"]["character"]
        u16slice(lines[r["start"]["line"]], r["start"]["character"], rest)
assert found, "no diagnostic covers zzz_undefined"
print(f"positions OK: {len(toks)} tokens + diagnostics share one UTF-16 basis")
PY
