#!/usr/bin/env bash
# G03: compiler secondary spans surface as LSP relatedInformation for duplicate
# declarations, only when the client advertises support; otherwise unchanged.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]
DOC = ('module Foo:\n    def a() -> void:\n        pass\n\n'
       'module Foo:\n    def b() -> void:\n        pass\n')
URI = "file:///dupmod.elisa"


def diags(caps, uri=URI, text=DOC):
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": text,
            }
        })
        client.wait_notification(
            "textDocument/publishDiagnostics",
            timeout=60,
            predicate=lambda n: n.get("params", {}).get("uri") == uri,
        )
        client.finish(timeout=30)
        found = [n["params"]["diagnostics"] for n in client.notifications
                 if n.get("method") == "textDocument/publishDiagnostics"
                 and n["params"]["uri"] == uri]
        assert found, "no diagnostics published"
        return found[-1]


CAP = {"textDocument": {"publishDiagnostics": {"relatedInformation": True}}}

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
