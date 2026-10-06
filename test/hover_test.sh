#!/usr/bin/env bash
# Smoke test: textDocument/hover surfaces a loop-header capture list —
# "Mutates (captured, in place): …" plus "Loop-private accumulators: …" — reports
# "Pure over outer state" for a header with no captures, and returns null on a
# non-header line and on a bitwise `|` that is not a header.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "error: $SRV missing — build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]
# line 3: capture header; line 6: no-capture header; line 9: bitwise | (not a header)
doc = ("def f(xs: darray[i64], a: i64, b: i64) -> i64:\n"      # 0
       "    total: mutable i64 = 0\n"                          # 1
       "    r: i64 =\n"                                        # 2
       "        for x in xs |acc = 0, total| -> acc:\n"        # 3
       "            total <- total + x\n"                      # 4
       "            acc <- acc + 1\n"                          # 5
       "    s: i64 =\n"                                        # 6
       "        for x in xs |n = 0| -> n:\n"                   # 7
       "            n <- n + 1\n"                              # 8
       "    for y in 0..<(a | b):\n"                           # 9
       "        total <- total + y\n"                          # 10
       "    return total + r + s\n")                           # 11
def hover_request(line, ch, request_id):
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "textDocument/hover",
        "params": {
            "textDocument": {"uri": "file:///t.elisa"},
            "position": {"line": line, "character": ch},
        },
    }

def hover_text(response):
    assert "result" in response, response
    result = response["result"]
    if result is None:
        return ""
    contents = result["contents"]
    if isinstance(contents, dict):
        return contents["value"]
    return contents

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": "file:///t.elisa",
            "languageId": "Elisa",
            "version": 1,
            "text": doc,
        }
    })
    line_index_before = client.request("$/elisa/stats", {}, req_id=96)["result"]["line_index"]
    # Keep all four requests pipelined as in the original smoke test.
    client.send_many([
        hover_request(3, 20, 2),  # capture header
        hover_request(7, 20, 3),  # no-capture header
        hover_request(9, 20, 4),  # bitwise | — not a header
        hover_request(1, 5, 5),   # ordinary decl line
        hover_request(3, 0, 6),   # before the capture list
        hover_request(3, len(doc.splitlines()[3]) - 1, 7),  # suffix after the capture list
    ])
    results = {request_id: hover_text(client.wait_response(request_id))
               for request_id in (2, 3, 4, 5, 6, 7)}
    capture_range = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///t.elisa"},
        "position": {"line": 3, "character": 20},
    }, req_id=98)["result"]["range"]
    line_index_after = client.request("$/elisa/stats", {}, req_id=97)["result"]["line_index"]
    assert line_index_after == line_index_before, (line_index_before, line_index_after)
    assert line_index_after["fallback_build_calls"] == 0, line_index_after
    # The explicit hover IDs are pipelined, so use a distinct ID for shutdown.
    shutdown = client.request("shutdown", req_id=99, timeout=30)
    assert shutdown.get("result", "missing") is None, shutdown
    client.notify("exit")
    client.close(expect_exit=0, timeout=30)

r2 = results[2]
if not r2.startswith("**Loop header**") or "docs/119" in r2:
    raise AssertionError(f"loop header hover should use a user-facing label: {r2}")
if "captured, in place): total" not in r2 or "accumulators: acc" not in r2:
    raise AssertionError(f"capture header hover wrong: {r2}")
capture_line = doc.splitlines()[3]
capture_start = capture_line.index("|")
capture_end = capture_line.index("|", capture_start + 1) + 1
expected_capture_range = {
    "start": {"line": 3, "character": capture_start},
    "end": {"line": 3, "character": capture_end},
}
if capture_range != expected_capture_range:
    raise AssertionError(f"loop hover range must cover only the capture list: {capture_range}")
r3 = results[3]
if "Pure over outer state" not in r3:
    raise AssertionError(f"no-capture header hover wrong: {r3}")
if "loop header" in results[4]:
    raise AssertionError(f"bitwise | must not show a loop-header hover: {results[4]}")
if "loop header" in results[5]:
    raise AssertionError(f"ordinary line must not show a loop-header hover: {results[5]}")
if "loop header" in results[6] or "loop header" in results[7]:
    raise AssertionError(f"loop hover must be restricted to the capture-list span: {results[6:8]}")

# Plaintext hover keeps plain text content and reports the same exact range.
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {"textDocument": {"hover": {"contentFormat": ["plaintext"]}}}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": "file:///plain.elisa", "languageId": "Elisa", "version": 1, "text": doc}
    })
    plain = client.request("textDocument/hover", {
        "textDocument": {"uri": "file:///plain.elisa"}, "position": {"line": 3, "character": 20}
    }, req_id=8)["result"]
    assert plain["contents"]["kind"] == "plaintext", plain
    assert plain["contents"]["value"].startswith("Loop header\n\n"), plain
    assert "**Loop header**" not in plain["contents"]["value"], plain
    assert plain["range"] == expected_capture_range, plain
    client.finish(timeout=30)

# A non-ASCII accumulator proves loop-range conversion honors the negotiated
# position encoding at both endpoints.
unicode_doc = (
    "def f(xs: darray[i64]) -> i64:\n"
    "    result: i64 =\n"
    "        for x in xs |π = 0| -> π:\n"
    "            π <- π + 1\n"
    "    return result\n"
)
unicode_line = unicode_doc.splitlines()[2]
unicode_open = unicode_line.index("|")
unicode_close = unicode_line.index("|", unicode_open + 1)

def encoded_units(text, encoding):
    if encoding == "utf-8":
        return len(text.encode("utf-8"))
    return len(text.encode("utf-16-le")) // 2

for encoding in ("utf-16", "utf-8"):
    capabilities = {"general": {"positionEncodings": [encoding]}} if encoding == "utf-8" else {}
    unicode_uri = f"file:///unicode-{encoding}.elisa"
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": capabilities})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {"uri": unicode_uri, "languageId": "Elisa", "version": 1, "text": unicode_doc}
        })
        response = client.request("textDocument/hover", {
            "textDocument": {"uri": unicode_uri},
            "position": {"line": 2, "character": encoded_units(unicode_line[:unicode_open + 1], encoding)},
        }, req_id=20)["result"]
        expected_unicode_range = {
            "start": {"line": 2, "character": encoded_units(unicode_line[:unicode_open], encoding)},
            "end": {"line": 2, "character": encoded_units(unicode_line[:unicode_close + 1], encoding)},
        }
        assert response and response["range"] == expected_unicode_range, (encoding, response, expected_unicode_range)
        client.finish(timeout=30)

print("hover smoke OK: capture-only exact range, markdown/plaintext, pure-over-outer, bitwise-| safe, no header off-span")
PY
