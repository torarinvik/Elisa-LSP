#!/usr/bin/env bash
# D02: full-sync correctness — multi-change application order, CRLF/trailing
# fidelity, ranged-change rejection, empty/malformed change safety.
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
GOOD = "def one() -> void:\n    x: i64 = 1\n"
BAD = "def broken() -> void:\n    z: bool = 3\n"
uri = "file:///sync.elisa"


def open_doc(client, text, document_uri=uri):
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": document_uri,
            "languageId": "Elisa",
            "version": 1,
            "text": text,
        }
    })


def change_doc(client, version, content_changes, document_uri=uri):
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": document_uri, "version": version},
        "contentChanges": content_changes,
    })


def request(client, method, document_uri=uri, **params):
    request_params = {"textDocument": {"uri": document_uri}, **params}
    response = client.request(method, request_params, timeout=30)
    assert "result" in response, response
    return response["result"]


def session(action, capabilities=None):
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": capabilities or {}})
        assert "result" in initialized, initialized
        result = action(client)
        client.finish(timeout=30)
        return result, list(client.notifications)


# 1. Multi-change full replacements apply in order: last entry wins.
def multi_full_change(client):
    open_doc(client, GOOD)
    change_doc(client, 2, [{"text": BAD}, {"text": GOOD}])
    return request(client, "textDocument/semanticTokens/full")


result, notifs = session(multi_full_change)
assert result and result.get("data"), "last full replacement must win"
diags = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics"
         and n["params"]["uri"] == uri]
assert diags and diags[-1]["params"]["diagnostics"] == [], \
    f"GOOD tail must be clean: {diags[-1] if diags else None}"

# 2. Ranged change (incremental sync, advertised): applied against the current
#    text; renaming the declared function changes its tokens.
def ranged_rename(client):
    open_doc(client, GOOD)
    initial = request(client, "textDocument/semanticTokens/full")
    change_doc(client, 2, [{
        "range": {"start": {"line": 0, "character": 4},
                  "end": {"line": 0, "character": 7}},
        "text": "longer",
    }])
    symbols = request(client, "textDocument/documentSymbol")
    updated = request(client, "textDocument/semanticTokens/full")
    return initial, symbols, updated


initial, symbols, updated = session(ranged_rename)[0]
assert updated and updated.get("data"), "ranged edit must keep the document analyzable"
assert updated != initial, "ranged rename must change the token stream"
names = [symbol["name"] for symbol in (symbols or [])]
assert "longer" in names, f"ranged rename must reach the symbol table: {names}"

# 3. CRLF fidelity: bytes preserved exactly (the frontend itself reports the
# CR as a token, which proves the \r reached analysis intact, not normalized).
crlf_doc = "def cr() -> void:\r\n    pass\r\n"


def crlf_session(client):
    open_doc(client, crlf_doc)
    return request(client, "textDocument/semanticTokens/full")


crlf_tokens, notifs = session(crlf_session)
assert crlf_tokens and crlf_tokens.get("data"), "CRLF doc must tokenize"
diags = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics"
         and n["params"]["uri"] == uri]
assert diags, "CRLF doc must publish diagnostics"
found_cr = any("\\r" in json.dumps(d) for d in diags[-1]["params"]["diagnostics"])
assert found_cr, f"CR bytes must survive to analysis intact: {diags[-1]}"
for diagnostic in diags[-1]["params"]["diagnostics"]:
    assert diagnostic["range"]["start"]["character"] != 999 \
        and diagnostic["range"]["end"]["character"] != 999

# 4. Empty change list / missing text: malformed, no mutation, no crash.
def malformed_changes(client):
    open_doc(client, GOOD)
    before = request(client, "textDocument/semanticTokens/full")
    change_doc(client, 2, [])
    change_doc(client, 3, [{}])
    after = request(client, "textDocument/semanticTokens/full")
    return before, after


before, after = session(malformed_changes)[0]
assert after == before, "malformed changes must not mutate"

# 5. rangeLength is optional deprecated metadata. When present it must match
#    the removed span in the negotiated units; a mismatch rejects the entire
#    notification, while a correct value allows the ranged edit.
def range_length_case(encoding, expected_length, mismatched_length, document_uri):
    doc = 'def f() -> void:\n    s: dstr = "é🌍"\n'
    prefix = '    s: dstr = "'
    start = len(prefix)
    end = start + expected_length
    caps = {} if encoding == "utf-16" else {"general": {"positionEncodings": ["utf-8"]}}
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        open_doc(client, doc, document_uri)
        initial = request(client, "textDocument/semanticTokens/full", document_uri)
        replacement = {
            "range": {"start": {"line": 1, "character": start},
                      "end": {"line": 1, "character": end}},
            "rangeLength": mismatched_length,
            "text": "bad",
        }
        change_doc(client, 2, [replacement], document_uri)
        mismatched = request(client, "textDocument/semanticTokens/full", document_uri)
        replacement["rangeLength"] = expected_length
        replacement["text"] = "ok"
        change_doc(client, 3, [replacement], document_uri)
        matching = request(client, "textDocument/semanticTokens/full", document_uri)
        client.finish(timeout=30)
    assert initial and mismatched == initial, \
        f"{encoding} rangeLength mismatch mutated the document"
    assert matching and matching != initial, \
        f"{encoding} matching rangeLength did not apply the edit"


range_length_case("utf-16", 3, 6, "file:///range-length-16.elisa")
range_length_case("utf-8", 6, 3, "file:///range-length-8.elisa")

# rangeLength by itself cannot convert a text-only/full replacement into a
# ranged edit and is malformed under the documented policy.
def range_length_without_range(client):
    open_doc(client, GOOD)
    before = request(client, "textDocument/semanticTokens/full")
    change_doc(client, 2, [{"rangeLength": 0, "text": BAD}])
    after = request(client, "textDocument/semanticTokens/full")
    return before, after


before, after = session(range_length_without_range)[0]
assert after == before, "rangeLength without range must not mutate the document"

# 6. Position.character beyond a valid line clamps to its end, but a line
#    beyond the document is not an EOF alias. Reject that whole notification,
#    preserve the earlier accepted edit, and accept a later valid version.
def out_of_document_line_case(client):
    document_uri = "file:///out-of-document-line.elisa"
    open_doc(client, GOOD, document_uri)
    before = request(client, "textDocument/semanticTokens/full", document_uri)
    change_doc(client, 2, [{
        "range": {
            "start": {"line": 0, "character": 999},
            "end": {"line": 0, "character": 999},
        },
        "text": " # tail",
    }], document_uri)
    after_clamped_character = request(client, "textDocument/semanticTokens/full", document_uri)
    before_invalid_line_stats = client.request("$/elisa/stats", {})["result"]
    change_doc(client, 3, [{
        "range": {
            "start": {"line": 0, "character": 0},
            "end": {"line": 99, "character": 0},
        },
        "text": "MUTATION",
    }], document_uri)
    after_invalid_line = request(client, "textDocument/semanticTokens/full", document_uri)
    after_invalid_line_stats = client.request("$/elisa/stats", {})["result"]
    change_doc(client, 4, [{
        "range": {
            "start": {"line": 0, "character": 4},
            "end": {"line": 0, "character": 7},
        },
        "text": "renamed",
    }], document_uri)
    after_valid = request(client, "textDocument/documentSymbol", document_uri)
    return before, after_clamped_character, after_invalid_line, after_valid, before_invalid_line_stats, after_invalid_line_stats


(before_clamp, after_clamped_character, after_invalid_line, after_valid_line, before_invalid_line_stats, after_invalid_line_stats), _ = session(out_of_document_line_case)
assert after_clamped_character != before_clamp, \
    "an oversized character on a valid line must clamp to the line end and apply"
assert after_invalid_line == after_clamped_character, \
    "out-of-document line must reject the complete change without mutating source"
assert after_invalid_line_stats["storage_bytes"] == before_invalid_line_stats["storage_bytes"], \
    f"out-of-document line must not allocate a replacement snapshot: {before_invalid_line_stats} -> {after_invalid_line_stats}"
assert after_invalid_line_stats["live_bytes"] == before_invalid_line_stats["live_bytes"], \
    f"out-of-document line must preserve live source bytes: {before_invalid_line_stats} -> {after_invalid_line_stats}"
assert any(symbol["name"] == "renamed" for symbol in (after_valid_line or [])), \
    f"a valid later version must still apply after an invalid line: {after_valid_line}"


def unicode_eol_clamp_case(client, use_utf8, document_uri):
    doc = 'def f() -> void:\n    s: dstr = "é🌍"\n'
    open_doc(client, doc, document_uri)
    before = request(client, "textDocument/semanticTokens/full", document_uri)
    change_doc(client, 2, [{
        "range": {"start": {"line": 1, "character": 999},
                  "end": {"line": 1, "character": 999}},
        "text": " # tail",
    }], document_uri)
    after = request(client, "textDocument/semanticTokens/full", document_uri)
    before_reject_stats = client.request("$/elisa/stats", {})["result"]
    change_doc(client, 3, [{
        "range": {"start": {"line": 1, "character": 0},
                  "end": {"line": 99, "character": 0}},
        "text": "MUTATION",
    }], document_uri)
    rejected = request(client, "textDocument/semanticTokens/full", document_uri)
    after_reject_stats = client.request("$/elisa/stats", {})["result"]
    assert after != before, \
        f"oversized Unicode {'UTF-8' if use_utf8 else 'UTF-16'} column failed to clamp to EOL"
    assert rejected == after, "invalid line after Unicode EOL clamp must preserve the accepted snapshot"
    assert after_reject_stats["storage_bytes"] == before_reject_stats["storage_bytes"], \
        f"invalid Unicode edit allocated storage: {before_reject_stats} -> {after_reject_stats}"
    assert after_reject_stats["live_bytes"] == before_reject_stats["live_bytes"], \
        f"invalid Unicode edit changed live bytes: {before_reject_stats} -> {after_reject_stats}"
    return before, after


for unicode_utf8, unicode_uri in (
    (False, "file:///unicode-eol-clamp-utf16.elisa"),
    (True, "file:///unicode-eol-clamp-utf8.elisa"),
):
    encoding_caps = {"general": {"positionEncodings": ["utf-8"]}} if unicode_utf8 else {}
    def action(client, use_utf8=unicode_utf8, uri_value=unicode_uri):
        return unicode_eol_clamp_case(client, use_utf8, uri_value)
    (unicode_before, unicode_after), _ = session(action, encoding_caps)
    assert unicode_after != unicode_before

# 7. Edit endpoints inside a scalar are invalid, even though request-time
# queries retain their permissive clamp policy. Test both encodings and both
# endpoints, then prove a later valid version still commits.
def unaligned_edit_case(utf8, document_uri):
    doc = 'def before() -> void:\n    s: dstr = "a🌍b"\n'
    caps = {"general": {"positionEncodings": ["utf-8"]}} if utf8 else {}
    char_mid = 17
    char_before = 16
    char_after = 20 if utf8 else 18
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        open_doc(client, doc, document_uri)
        # didOpen analysis runs in an isolated worker. Finish that snapshot
        # before recording storage so cache publication cannot be mistaken
        # for an invalid edit mutating the accepted source bytes.
        analyzed = client.request("textDocument/semanticTokens/full", {
            "textDocument": {"uri": document_uri}
        })
        assert "result" in analyzed, analyzed
        before = client.request("$/elisa/stats", {})["result"]
        for version, start, end in (
            (2, char_mid, char_after),  # split the start inside the emoji
            (3, char_before, char_mid),  # split the end inside the emoji
        ):
            change_doc(client, version, [{
                "range": {"start": {"line": 1, "character": start},
                          "end": {"line": 1, "character": end}},
                "text": "X",
            }], document_uri)
            observed = client.request("$/elisa/stats", {})["result"]
            assert observed["storage_bytes"] == before["storage_bytes"], \
                f"unaligned {('UTF-8' if utf8 else 'UTF-16')} edit mutated stored source: {observed}"
            assert observed["live_bytes"] == before["live_bytes"], \
                f"unaligned {('UTF-8' if utf8 else 'UTF-16')} edit changed live source bytes: {observed}"
        change_doc(client, 4, [{
            "range": {"start": {"line": 0, "character": 4},
                      "end": {"line": 0, "character": 10}},
            "text": "afterLong",
        }], document_uri)
        symbols = client.request("textDocument/documentSymbol", {
            "textDocument": {"uri": document_uri}
        })["result"]
        client.finish(timeout=30)
    assert any(symbol["name"] == "afterLong" for symbol in (symbols or [])), \
        f"valid edit after rejected unaligned endpoints did not apply: {symbols}"


unaligned_edit_case(False, "file:///unaligned-edit-utf16.elisa")
unaligned_edit_case(True, "file:///unaligned-edit-utf8.elisa")

print("sync OK: ordered edits, CRLF, malformed rollback, rangeLength, and strict edit boundaries")
PY
