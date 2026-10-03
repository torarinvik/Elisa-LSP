#!/usr/bin/env bash
# D01: versioned document lifecycle — stale rejection, close clearing, reopen.
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


def open_doc(client, uri, text, version=1):
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


def close_doc(client, uri):
    client.notify("textDocument/didClose", {
        "textDocument": {"uri": uri},
    })


def tokens(client, uri):
    response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    }, timeout=30)
    assert "result" in response, response
    return response["result"]


def run_session(action):
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": {}})
        assert "result" in initialized, initialized
        result = action(client)
        client.finish(timeout=30)
        return result, list(client.notifications)


GOOD = "def one() -> void:\n    x: i64 = 1\n"
BAD = "def broken() -> void:\n    z: bool = 3\n"
uri = "file:///doc-version.elisa"

# 1. Stale/equal versions never mutate: open v2, change v1 (stale) + v2 (equal) are ignored.
def stale_version_case(client):
    open_doc(client, uri, GOOD, 2)
    initial = tokens(client, uri)
    change_doc(client, uri, BAD, 1)   # stale
    stale = tokens(client, uri)
    change_doc(client, uri, BAD, 2)   # equal
    equal = tokens(client, uri)
    return initial, stale, equal


initial, stale, equal = run_session(stale_version_case)[0]
assert stale == initial, "stale version mutated the document"
assert equal == initial, "equal version mutated the document"

# 2. Newer version applies; close publishes empty diagnostics and invalidates tokens.
def close_clears_case(client):
    open_doc(client, uri, GOOD, 1)
    change_doc(client, uri, BAD, 2)
    updated = tokens(client, uri)
    close_doc(client, uri)
    closed = tokens(client, uri)
    return updated, closed


(updated, closed), notifs = run_session(close_clears_case)
assert updated and updated.get("data"), "updated doc must have tokens"
assert closed == {"data": []}, "closed doc must not serve stale tokens"
diags = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics"
         and n["params"]["uri"] == uri]
assert diags and diags[-1]["params"]["diagnostics"] == [], \
    "close must publish empty diagnostics"

# 3. Reopen after close works (new generation) even with a reused client version.
def reopen_case(client):
    open_doc(client, uri, GOOD, 1)
    close_doc(client, uri)
    open_doc(client, uri, GOOD, 1)
    return tokens(client, uri)


reopened, _ = run_session(reopen_case)
assert reopened and reopened.get("data"), "reopened doc must serve fresh tokens"

# 4. Empty document is valid: no crash, empty tokens.
def empty_document_case(client):
    empty_uri = "file:///empty.elisa"
    open_doc(client, empty_uri, "", 1)
    return tokens(client, empty_uri)


empty, _ = run_session(empty_document_case)
assert empty == {"data": []}, f"empty doc must yield empty tokens: {empty}"

# 5. Rejected notifications for unknown/malformed documents must not allocate
# dead cache slots. In particular, didChange on a URI that was never opened is
# ignored, and didOpen with a missing or malformed version creates no cache entry.
def rejected_notifications_case(client):
    before = client.request("$/elisa/stats", {})
    assert "result" in before, before
    for i in range(20):
        client.notify("textDocument/didChange", {
            "textDocument": {"uri": f"file:///never-opened-{i}.elisa", "version": 1},
            "contentChanges": [{"text": BAD}],
        })
    for i, bad_version in enumerate((1.5, "2", 2147483648, -2147483649)):
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": f"file:///bad-version-{i}.elisa",
                "languageId": "Elisa",
                "version": bad_version,
                "text": GOOD,
            }
        })
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": "file:///missing-version.elisa",
            "languageId": "Elisa",
            "text": GOOD,
        }
    })
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": "file:///bad-text.elisa",
            "version": 1,
            "text": 17,
        }
    })
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": "file:///never-opened-change.elisa", "version": 2},
        "contentChanges": "not-an-array",
    })
    client.notify("textDocument/didClose", {
        "textDocument": {"uri": False},
    })
    after = client.request("$/elisa/stats", {})
    assert "result" in after, after
    return before["result"], after["result"]


stats_before, stats_after = run_session(rejected_notifications_case)[0]
assert stats_before == stats_after, \
    f"rejected notifications allocated retained document state: {stats_before} -> {stats_after}"

# 6. Negative signed LSP versions are valid data, not integer-parser failure
# sentinels. They remain attached to diagnostics and must still increase.
def negative_version_case(client):
    negative_uri = "file:///negative-version.elisa"
    open_doc(client, negative_uri, BAD, -2)
    change_doc(client, negative_uri, GOOD, -1)
    close_doc(client, negative_uri)


_, notifs = run_session(negative_version_case)
negative_versions = [n["params"].get("version") for n in notifs
                     if n.get("method") == "textDocument/publishDiagnostics"
                     and n["params"]["uri"] == "file:///negative-version.elisa"]
assert negative_versions == [-2, -1, -1], \
    f"signed versions must round-trip through open/change/close: {negative_versions}"

# 7. A duplicate didOpen while the URI is still open starts a fresh internal
#    generation. Its full source replaces the current snapshot even when the
#    client reuses the same version number.
def duplicate_open_case(client):
    open_doc(client, uri, GOOD, 7)
    first = tokens(client, uri)
    open_doc(client, uri, BAD, 7)
    second = tokens(client, uri)
    return first, second


(first, second), notifs = run_session(duplicate_open_case)
assert first and second and first != second, \
    "same-version duplicate didOpen must replace the analyzed snapshot"
dup_diags = [n["params"] for n in notifs
             if n.get("method") == "textDocument/publishDiagnostics"
             and n["params"].get("uri") == uri]
assert [d.get("version") for d in dup_diags] == [7, 7], \
    f"duplicate-open pushes must carry the reused version: {dup_diags}"
assert dup_diags[-1]["diagnostics"], \
    "duplicate-open replacement text must be diagnosed"

# 8. Save notifications are not advertised and never replace the open-buffer
#    overlay. Even a didSave carrying disk text cannot overwrite editor state
#    or trigger another analysis.
def save_notifications_case(client):
    save_uri = "file:///save-policy.elisa"
    open_doc(client, save_uri, GOOD, 1)
    before_symbols = client.request("textDocument/documentSymbol", {
        "textDocument": {"uri": save_uri},
    })
    before_tokens = tokens(client, save_uri)
    prior_message_count = len(client.all_messages)
    client.notify("textDocument/willSave", {
        "textDocument": {"uri": save_uri},
        "reason": 1,
    })
    client.notify("textDocument/didSave", {
        "textDocument": {"uri": save_uri},
        "text": BAD,
    })
    after_save_symbols = client.request("textDocument/documentSymbol", {
        "textDocument": {"uri": save_uri},
    })
    after_save_tokens = tokens(client, save_uri)
    messages_after_saves = client.all_messages[prior_message_count:]

    after_save_source = "def changed_after_save() -> void:\n    pass\n"
    change_doc(client, save_uri, after_save_source, 2)
    after_change_symbols = client.request("textDocument/documentSymbol", {
        "textDocument": {"uri": save_uri},
    })
    return (before_symbols, before_tokens, after_save_symbols, after_save_tokens,
            messages_after_saves, after_change_symbols)


((before_symbols, before_tokens, after_save_symbols, after_save_tokens,
  messages_after_saves, after_change_symbols), save_notifs) = run_session(save_notifications_case)
assert before_symbols["result"] == after_save_symbols["result"] and [item["name"] for item in after_save_symbols["result"]] == ["one"], \
    f"didSave text must not replace open-buffer symbols: {before_symbols} -> {after_save_symbols}"
assert before_tokens == after_save_tokens, \
    f"save notifications must leave open-buffer semantic tokens unchanged: {before_tokens} -> {after_save_tokens}"
assert not any("method" in message for message in messages_after_saves), \
    f"willSave/didSave must not emit server notifications: {messages_after_saves}"
assert [item["name"] for item in after_change_symbols["result"]] == ["changed_after_save"], \
    f"didChange after ignored save notifications must still update the overlay: {after_change_symbols}"
save_diags = [n for n in save_notifs if n.get("method") == "textDocument/publishDiagnostics"
              and n["params"].get("uri") == "file:///save-policy.elisa"]
assert [n["params"].get("version") for n in save_diags] == [1, 2], \
    f"only open and subsequent change may publish diagnostics: {save_diags}"

print("documents OK: versions, stale rejection, close clearing, reopen, empty, duplicate-open generation, and ignored save notifications")
PY
