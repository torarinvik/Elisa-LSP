#!/usr/bin/env bash
# P03: capability negotiation — positionEncoding preference order, hover
# contentFormat fallback, safe defaults for absent/unknown capabilities.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
DOC = ('def f(name: i64) -> i64:\n'
       '    x: dstr = "héllo 🌍"\n'
       '    return name\n')
LOOP = ('def f(xs: darray[i64]) -> i64:\n'
        '    r: i64 =\n'
        '        for x in xs |acc = 0| -> acc:\n'
        '            acc <- acc + 1\n'
        '    return acc\n')
def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def session(caps, uri, text, extra=()):
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":caps}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":text}}})
    m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
                "params":{"textDocument":{"uri":uri}}})
    for i, req in extra:
        m += frame(dict(req, id=i))
    m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    p = subprocess.run([srv], input=m, capture_output=True, timeout=30)
    assert p.returncode == 0, f"exit {p.returncode}"
    res = {}
    pos = 0
    out = p.stdout
    while pos < len(out):
        sep = out.find(b"\r\n\r\n", pos)
        ln = int(out[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(out[start:start+ln])
        if "id" in msg: res[msg["id"]] = msg.get("result")
        pos = start+ln
    return res
def bslice(line, col, ln):
    raw = line.encode("utf-8")
    assert 0 <= col <= len(raw) and 0 <= ln and col+ln <= len(raw)
    return raw[col:col+ln].decode("utf-8")
def u16slice(line, col, ln):
    raw = line.encode("utf-16-le")
    assert 0 <= col <= len(raw)//2 and 0 <= ln and col+ln <= len(raw)//2
    return raw[col*2:(col+ln)*2].decode("utf-16-le")
def toks(data):
    out, line, col = [], 0, 0
    for i in range(0, len(data), 5):
        dl, dc, ln, tt, _ = data[i:i+5]
        line += dl; col = (col + dc) if dl == 0 else dc
        out.append((line, col, ln, tt))
    return out

lines = DOC.split("\n")
# 1. utf-8 session: advertised, byte columns/lengths.
r = session({"general":{"positionEncodings":["utf-8"]}}, "file:///c8.elisa", DOC)
assert r[1]["capabilities"].get("positionEncoding") == "utf-8", r[1]["capabilities"].get("positionEncoding")
strtok = [t for t in toks(r[2]["data"]) if t[0] == 1 and t[3] == 11]
assert len(strtok) == 1, strtok
assert (strtok[0][1], strtok[0][2]) == (14, 13), f"utf-8 bytes expected: {strtok[0]}"
assert bslice(lines[1], 14, 13) == '"héllo 🌍"', "byte slice must decode"

# 2. default session: no positionEncoding field, UTF-16 units.
r = session({}, "file:///c16.elisa", DOC)
assert "positionEncoding" not in r[1]["capabilities"], r[1]["capabilities"].get("positionEncoding")
strtok = [t for t in toks(r[2]["data"]) if t[0] == 1 and t[3] == 11]
assert (strtok[0][1], strtok[0][2]) == (14, 10), f"utf-16 units expected: {strtok[0]}"
assert u16slice(lines[1], 14, 10) == '"héllo 🌍"'

# 3. preference order: ["utf-16","utf-8"] stays utf-16; unknown-only falls back.
r = session({"general":{"positionEncodings":["utf-16","utf-8"]}}, "file:///c16b.elisa", DOC)
assert "positionEncoding" not in r[1]["capabilities"]
strtok = [t for t in toks(r[2]["data"]) if t[0] == 1 and t[3] == 11]
assert (strtok[0][1], strtok[0][2]) == (14, 10)
r = session({"general":{"positionEncodings":["utf-32"]}}, "file:///c32.elisa", DOC)
assert "positionEncoding" not in r[1]["capabilities"]
strtok = [t for t in toks(r[2]["data"]) if t[0] == 1 and t[3] == 11]
assert (strtok[0][1], strtok[0][2]) == (14, 10)

# 4. hover kind follows contentFormat; markdown is the default.
hover = {"method":"textDocument/hover",
         "params":{"textDocument":{"uri":"file:///h.elisa"},"position":{"line":2,"character":20}}}
r = session({"textDocument":{"hover":{"contentFormat":["plaintext"]}}}, "file:///h.elisa", LOOP, [(3, hover)])
assert r[3]["contents"]["kind"] == "plaintext", r[3]
r = session({}, "file:///h2.elisa", LOOP, [(3, dict(hover, params={**hover["params"], "textDocument":{"uri":"file:///h2.elisa"}}))])
assert r[3]["contents"]["kind"] == "markdown", r[3]

# 5. diagnostics follow the negotiated units past non-ASCII content.
ERR = 'def f() -> void:\n    z: i64 = "é" + nope_undefined\n'
def diag_session(caps):
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":caps}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":"file:///e.elisa","languageId":"Elisa","version":1,"text":ERR}}})
    m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    p = subprocess.run([srv], input=m, capture_output=True, timeout=30)
    assert p.returncode == 0
    out, pos, diags = p.stdout, 0, []
    while pos < len(out):
        sep = out.find(b"\r\n\r\n", pos)
        ln = int(out[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(out[start:start+ln])
        if msg.get("method") == "textDocument/publishDiagnostics":
            diags.append(msg["params"])
        pos = start+ln
    return diags
d8 = diag_session({"general":{"positionEncodings":["utf-8"]}})[-1]["diagnostics"]
d16 = diag_session({})[-1]["diagnostics"]
u8 = [d for d in d8 if "nope_undefined" in d["message"]][0]["range"]
u16 = [d for d in d16 if "nope_undefined" in d["message"]][0]["range"]
assert (u8["start"]["character"], u8["end"]["character"]) == (0, 34), u8
assert (u16["start"]["character"], u16["end"]["character"]) == (0, 33), u16
assert bslice(ERR.split("\n")[1], 0, 34) and u16slice(ERR.split("\n")[1], 0, 33)

print("capabilities OK: encoding order, byte/unit columns, hover kinds, safe defaults")
PY
