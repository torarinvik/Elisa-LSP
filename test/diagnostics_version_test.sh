#!/usr/bin/env bash
# G02: versioned publication lifecycle — versions on pushes, identical-repeat
# suppression, error clearing on clean edits, bounded output with a visible cap.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import json
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]


def run_session(action, timeout=60):
    with LspSession(srv, request_timeout=timeout, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": {}}, timeout=min(timeout, 30))
        assert "result" in initialized, initialized
        action(client)
        client.finish(timeout=timeout)
        return list(client.notifications)


def pubs(notifications, uri=None):
    return [n["params"] for n in notifications
            if n.get("method") == "textDocument/publishDiagnostics"
            and (uri is None or n["params"]["uri"] == uri)]


def open_doc(client, uri, text, version):
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": version,
            "text": text,
        }
    })


def change_doc(client, uri, text, version):
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": version},
        "contentChanges": [{"text": text}],
    })


GOOD = "def one() -> void:\n    x: i64 = 1\n"
BAD = "def broken() -> void:\n    z: bool = 3\n"

# 1. Versions ride on pushes; duplicate didOpen is suppressed; clean edit
#    after an error clears it with a new version.
uri = "file:///ver.elisa"


def version_publication_case(client):
    open_doc(client, uri, BAD, 1)
    open_doc(client, uri, BAD, 1)
    change_doc(client, uri, GOOD, 2)


ps = pubs(run_session(version_publication_case), uri)
assert len(ps) == 2, f"duplicate open must suppress repeat publish: {[(p.get('version'), len(p['diagnostics'])) for p in ps]}"
assert ps[0].get("version") == 1 and len(ps[0]["diagnostics"]) == 1, f"v1 must carry the error: {ps[0]}"
assert ps[1].get("version") == 2 and ps[1]["diagnostics"] == [], f"clean v2 must clear: {ps[1]}"

# 2. Flood control: 300 findings cap at 200 with a visible hint, no dupes.
big_lines = ["def f() -> void:"] + [f"    _ = undef{n}" for n in range(300)]
big_text = "\n".join(big_lines) + "\n"
curi = "file:///cap.elisa"


def flood_control_case(client):
    open_doc(client, curi, big_text, 1)


ps = pubs(run_session(flood_control_case), curi)
assert len(ps) == 1
ds = ps[0]["diagnostics"]
assert ps[0].get("version") == 1
assert len(ds) == 201, f"expected 200 + hint, got {len(ds)}"
assert ds[-1].get("severity") == 4 and "omitted" in ds[-1].get("message", ""), f"hint must be visible: {ds[-1]}"
keys = [json.dumps(d, sort_keys=True) for d in ds]
assert len(set(keys)) == len(keys), "published findings must not contain duplicates"
for d in ds:
    assert d["range"]["start"]["character"] != 999 and d["range"]["end"]["character"] != 999

print("versioned diagnostics OK: versions, suppression, clearing, cap+hint, no dupes")
PY
