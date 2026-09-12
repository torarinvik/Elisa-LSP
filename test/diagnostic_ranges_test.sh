#!/usr/bin/env bash
# G01: diagnostic ranges are bounded, inside the snapshot, and never 999.
# Exact frontend spans when available; bounded line-extent fallback otherwise.
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

CASES = {
    "file:///r-ascii.elisa": "def main() -> int:\n    return nope_undefined\n",
    "file:///r-unicode.elisa": "def æøå() -> void:\n    x: i64 = λ\n    y: bool = 5\n",
    "file:///r-eof.elisa": "def main( -> int:\n",
    "file:///r-multi.elisa": "def a() -> void:\n    pass\ndef b( -> void:\n    pass\n",
}
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
for uri, text in CASES.items():
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":text}}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
out = run(m)
notifs = []
pos = 0
while pos < len(out):
    sep = out.find(b"\r\n\r\n", pos)
    ln = int(out[pos:sep].split(b":",1)[1].strip())
    start = sep+4
    msg = json.loads(out[start:start+ln])
    if msg.get("method") == "textDocument/publishDiagnostics":
        notifs.append(msg)
    pos = start+ln
by_uri = {n["params"]["uri"]: n["params"]["diagnostics"] for n in notifs}
for uri, text in CASES.items():
    diags = by_uri.get(uri)
    assert diags is not None and len(diags) > 0, f"{uri}: expected diagnostics, got {diags}"
    lines = text.split("\n")
    # UTF-16 code units per line for bound checks.
    ulens = [sum(2 if ord(c) > 0xFFFF else 1 for c in ln) for ln in lines]
    for d in diags:
        r = d["range"]
        s, e = r["start"], r["end"]
        for pt in (s, e):
            assert isinstance(pt["line"], int) and isinstance(pt["character"], int), f"{uri}: non-int pos {pt}"
            assert pt["line"] >= 0 and pt["character"] >= 0, f"{uri}: negative pos {pt}"
            assert pt["character"] != 999, f"{uri}: unbounded 999 character {pt}"
        assert s["line"] < len(lines) and e["line"] < len(lines), f"{uri}: line OOB {r}"
        assert s["character"] <= ulens[s["line"]], f"{uri}: start beyond line {r} (len {ulens[s['line']]})"
        assert e["character"] <= ulens[e["line"]], f"{uri}: end beyond line {r} (len {ulens[e['line']]})"
        assert (e["line"], e["character"]) >= (s["line"], s["character"]), f"{uri}: inverted range {r}"
print("ranges OK: bounded, in-snapshot, ordered, no 999 (ascii/unicode/eof/multiline)")
PY
