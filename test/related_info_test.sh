#!/usr/bin/env bash
# G03: compiler secondary spans surface as LSP relatedInformation for duplicate
# declarations, only when the client advertises support; otherwise unchanged.
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
DOC = ('module Foo:\n    def a() -> void:\n        pass\n\n'
       'module Foo:\n    def b() -> void:\n        pass\n')
URI = "file:///dupmod.elisa"
def diags(caps, uri=URI, text=DOC):
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":caps}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":text}}})
    m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    p = subprocess.run([srv], input=m, capture_output=True, timeout=30)
    assert p.returncode == 0
    out, pos, found = p.stdout, 0, []
    while pos < len(out):
        sep = out.find(b"\r\n\r\n", pos)
        ln = int(out[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        msg = json.loads(out[start:start+ln])
        if msg.get("method") == "textDocument/publishDiagnostics" and msg["params"]["uri"] == uri:
            found.append(msg["params"]["diagnostics"])
        pos = start+ln
    assert found, "no diagnostics published"
    return found[-1]

CAP = {"textDocument":{"publishDiagnostics":{"relatedInformation":True}}}

# 1. Capable client: the redeclaration points at the ORIGINAL declaration.
ds = diags(CAP)
rel = [d for d in ds if "already declared" in d["message"]]
assert len(rel) == 1, f"expected one redeclaration finding: {ds}"
d = rel[0]
assert d["range"]["start"]["line"] == 4, f"primary on the redeclaration line: {d['range']}"
assert "relatedInformation" in d, f"related info missing: {d}"
assert len(d["relatedInformation"]) == 1, d["relatedInformation"]
info = d["relatedInformation"][0]
assert info["location"]["uri"] == URI, info["location"]["uri"]
r = info["location"]["range"]
assert r["start"]["line"] == 0 and r["end"]["line"] == 0, f"must point at line 0: {r}"
assert r["end"]["character"] > r["start"]["character"], f"non-empty span expected: {r}"
assert isinstance(info["message"], str) and info["message"], "related info needs a message"

# 2. Incapable client: no relatedInformation field at all; message unchanged.
ds2 = diags({})
rel2 = [d for d in ds2 if "already declared" in d["message"]]
assert rel2 and "relatedInformation" not in rel2[0], f"must not emit unsupported field: {rel2}"

# 3. Findings without a secondary location never fabricate related info.
CLEAN = "def ok() -> void:\n    pass\n"
ds3 = diags(CAP, uri="file:///clean.elisa", text=CLEAN)
assert ds3 == [], f"clean doc must be empty: {ds3}"

print("related info OK: duplicate points at original; capability-gated; no fabrication")
PY
