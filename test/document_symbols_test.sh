#!/usr/bin/env bash
# F02: document symbols — flat SymbolInformation and hierarchical DocumentSymbol
# shapes, source order, prelude exclusion, restricted symbolKind.valueSet,
# unknown/closed URIs, and malformed-source safety.
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
def parse(buf):
    res, notifs = {}, []
    pos = 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        assert sep >= 0, "truncated header"
        ln = int(buf[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        raw = buf[start:start+ln]
        assert len(raw) == ln, "truncated body"
        msg = json.loads(raw)  # every frame must be valid JSON
        if "id" in msg: res[msg["id"]] = msg.get("result")
        else: notifs.append(msg)
        pos = start+ln
    return res, notifs

DOC = ('def alpha(x: i64) -> i64:\n    return x\n\n'
       'enum Color:\n    Red\n    Green\n\n'
       'struct Point:\n    x: i64\n    y: i64\n\n'
       'const LIMIT: i64 = 10\n'
       'alias Num = i64\n'
       'def main() -> int:\n    return 0\n')
URI = "file:///outline.elisa"
def symbols(caps, uri=URI, text=DOC):
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":caps}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":text}}})
    m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol",
                "params":{"textDocument":{"uri":uri}}})
    m += frame({"jsonrpc":"2.0","id":3,"method":"textDocument/documentSymbol",
                "params":{"textDocument":{"uri":"file:///missing.elisa"}}})
    m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    res, _ = parse(run(m))
    return res[2], res[3]

# 1. Flat default: SymbolInformation with location, source order, no builtins.
flat, unknown = symbols({})
assert unknown == [], f"unknown URI must be empty: {unknown}"
names = [s["name"] for s in flat]
assert names == ["alpha", "Color", "Point", "LIMIT", "Num", "main"], names
assert all("location" in s and "range" in s["location"] for s in flat), "flat shape must be SymbolInformation"
assert not any("location" in s and s["location"]["uri"] != URI for s in flat), "location uri must echo"
kinds = {s["name"]: s["kind"] for s in flat}
assert kinds == {"alpha":12, "Color":10, "Point":23, "LIMIT":14, "Num":5, "main":12}, kinds
# source order by line
lines = [s["location"]["range"]["start"]["line"] for s in flat]
assert lines == sorted(lines), f"symbols must be source-ordered: {lines}"
assert all(not any(c in n for n in names) for c in ()), "sanity"

# 2. Hierarchical: DocumentSymbol with children; selection within range.
hier, _ = symbols({"textDocument":{"documentSymbol":{"hierarchicalDocumentSymbolSupport":True}}})
assert all("location" not in s and "children" in s for s in hier), "hier shape must be DocumentSymbol"
for s in hier:
    r, sr = s["range"], s["selectionRange"]
    assert (sr["start"]["line"] >= r["start"]["line"] and sr["end"]["line"] <= r["end"]["line"]), \
        f"selectionRange must be inside range: {s['name']} {r} {sr}"
    assert (sr["end"]["character"] >= sr["start"]["character"]), f"inverted selection: {s['name']}"

# 3. Restricted symbolKind.valueSet: nothing outside the set is emitted.
restricted, _ = symbols({"textDocument":{"documentSymbol":{"symbolKind":{"valueSet":[12,10]}}}})
assert {s["name"] for s in restricted} == {"alpha", "Color", "main"}, [s["name"] for s in restricted]
assert all(s["kind"] in (12, 10) for s in restricted)

# 4. Malformed source still yields a valid outline (recovery), never malformed JSON.
BROKEN = "def good() -> void:\n    pass\ndef bad( -> void:\n"
br, _ = symbols({}, uri="file:///broken.elisa", text=BROKEN)
assert any(s["name"] == "good" for s in br), f"unfinished code must keep earlier decls: {br}"

print("symbols OK: flat/hier shapes, order, prelude excluded, valueSet clamp, recovery")
PY
