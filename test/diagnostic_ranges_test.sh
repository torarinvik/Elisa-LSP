#!/usr/bin/env bash
# G01: diagnostic ranges are bounded, inside the snapshot, and never 999.
# Exact frontend spans when available; bounded line-extent fallback otherwise.
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
CASES = {
    "file:///r-ascii.elisa": "def main() -> int:\n    return nope_undefined\n",
    "file:///r-unicode.elisa": "def æøå() -> void:\n    x: i64 = λ\n    y: bool = 5\n",
    "file:///r-eof.elisa": "def main( -> int:\n",
    "file:///r-multi.elisa": "def a() -> void:\n    pass\ndef b( -> void:\n    pass\n",
}

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    for uri, text in CASES.items():
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": text,
            }
        })
    client.finish(timeout=30)
    notifs = [n for n in client.notifications
              if n.get("method") == "textDocument/publishDiagnostics"]

by_uri = {n["params"]["uri"]: n["params"]["diagnostics"] for n in notifs}
# This type mismatch carries a real frontend span. Assert the exact identifier
# range after the earlier Nordic declaration and multibyte lambda; boundary
# checks alone would miss a byte/column or end-exclusive conversion regression.
unicode_diags = by_uri["file:///r-unicode.elisa"]
typed = [d for d in unicode_diags if 'variable "y" expects bool' in d["message"]]
assert len(typed) == 1, f"expected one typed mismatch with a source span: {unicode_diags}"
assert typed[0]["range"] == {
    "start": {"line": 2, "character": 4},
    "end": {"line": 2, "character": 5},
}, f"diagnostic must select only y on the Unicode source: {typed[0]}"
for uri, text in CASES.items():
    diags = by_uri.get(uri)
    assert diags is not None and len(diags) > 0, f"{uri}: expected diagnostics, got {diags}"
    lines = text.split("\n")
    # UTF-16 code units per line for bound checks.
    ulens = [sum(2 if ord(c) > 0xFFFF else 1 for c in line) for line in lines]
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

# The same physical span must follow negotiated UTF-8 units. The non-ASCII
# literal makes the exact end differ by one unit from the UTF-16 result.
utf8_uri = "file:///r-utf8.elisa"
utf8_text = 'def f() -> void:\n    if "é":\n        pass\n'
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({
        "capabilities": {"general": {"positionEncodings": ["utf-8"]}}
    })
    assert initialized["result"]["capabilities"].get("positionEncoding") == "utf-8", initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": utf8_uri,
            "languageId": "Elisa",
            "version": 1,
            "text": utf8_text,
        }
    })
    publication = client.wait_notification("textDocument/publishDiagnostics", timeout=30)
    client.finish(timeout=30)
utf8_diagnostic = next(
    d for d in publication["params"]["diagnostics"]
    if "if condition must be bool" in d["message"]
)
assert utf8_diagnostic["range"] == {
    "start": {"line": 1, "character": 0},
    "end": {"line": 1, "character": 12},
}, f"UTF-8 diagnostic range must use byte units: {utf8_diagnostic}"

print("ranges OK: exact Unicode/UTF-8 spans, bounded fallback, EOF/multiline, no 999")
PY
