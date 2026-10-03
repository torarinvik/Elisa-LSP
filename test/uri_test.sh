#!/usr/bin/env bash
# D03: URI identity — percent-decoding, scheme case, localhost authority,
# fragment stripping, malformed escapes, untitled/remote opacity, case policy.
# Responses echo the client's spelling; lookup uses the canonical form.
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
GOOD = "def one() -> void:\n    x: i64 = 1\n"


def open_doc(client, uri, text, version=1):
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": version,
            "text": text,
        }
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
        # finish() has drained all framed output through EOF, including any
        # diagnostics emitted by didOpen/didClose.
        return result, list(client.notifications)


# 1. Equivalent encodings alias; spelling is echoed back; distinct stays distinct.
def equivalent_uri_case(client):
    open_doc(client, "file:///a%20b.elisa", GOOD)
    responses = {
        2: tokens(client, "file:///a b.elisa"),
        3: tokens(client, "FILE:///a%20b.elisa"),
        4: tokens(client, "file://localhost/a%20b.elisa"),
        5: tokens(client, "file:///a%20b.elisa#frag"),
        6: tokens(client, "file:///other.elisa"),
    }
    return responses


res, notifs = run_session(equivalent_uri_case)
for i in (2, 3, 4, 5):
    assert res[i] and res[i].get("data"), f"alias form {i} must resolve: {res[i]}"
assert res[6] == {"data": []}, "unrelated URI must stay empty"
diags = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics"]
assert diags and diags[0]["params"]["uri"] == "file:///a%20b.elisa", \
    f"responses echo incoming spelling: {diags[0]['params']['uri'] if diags else None}"


# 2. %41 == 'A'; malformed/trailing % stays usable and distinct; close-by-alias works.
def malformed_and_close_case(client):
    open_doc(client, "file:///x%41y.elisa", GOOD)
    encoded_a = tokens(client, "file:///xAy.elisa")
    open_doc(client, "file:///we%2Fird.elisa", GOOD)
    malformed = tokens(client, "file:///we%ZZird.elisa")
    open_doc(client, "file:///trail%.elisa", GOOD)
    trailing = tokens(client, "file:///trail%.elisa")
    open_doc(client, "file:///bad%ZZ.elisa", GOOD)
    malformed_exact = tokens(client, "file:///bad%ZZ.elisa")
    escaped_percent = tokens(client, "file:///bad%25ZZ.elisa")
    client.notify("textDocument/didClose", {
        "textDocument": {"uri": "file:///x%41y.elisa"},
    })
    closed_alias = tokens(client, "file:///xAy.elisa")
    return encoded_a, malformed, trailing, malformed_exact, escaped_percent, closed_alias


(encoded_a, malformed, trailing, malformed_exact, escaped_percent, closed_alias), notifs = run_session(malformed_and_close_case)
assert encoded_a and encoded_a.get("data"), "%41 must equal A"
assert malformed == {"data": []}, "%2F must not alias %ZZ"
assert trailing and trailing.get("data"), "trailing % must not break the document"
assert malformed_exact and malformed_exact.get("data"), (
    "the parser reports malformed escapes but retains their literal identity"
)
assert escaped_percent == {"data": []}, "malformed %ZZ and valid escaped percent remain distinct"
assert closed_alias == {"data": []}, "close-by-alias must invalidate"
clears = [n for n in notifs if n.get("method") == "textDocument/publishDiagnostics"
          and n["params"]["uri"] == "file:///x%41y.elisa"
          and n["params"]["diagnostics"] == []]
assert clears, "close must publish the empty clear"


# 3. Case-distinct paths stay distinct (no lowercasing); untitled + non-ASCII
#    percent forms + unknown schemes behave as opaque overlays.
def opaque_uri_case(client):
    open_doc(client, "file:///Case.elisa", GOOD)
    lower_case = tokens(client, "file:///case.elisa")
    open_doc(client, "untitled:Untitled-1", GOOD)
    untitled = tokens(client, "untitled:Untitled-1")
    open_doc(client, "file:///caf%C3%A9.elisa", GOOD)
    encoded_unicode = tokens(client, "file:///caf%C3%A9.elisa")
    open_doc(client, "https://example.com/x.elisa", GOOD)
    remote = tokens(client, "https://example.com/x.elisa")
    return lower_case, untitled, encoded_unicode, remote


(lower_case, untitled, encoded_unicode, remote), _ = run_session(opaque_uri_case)
assert lower_case == {"data": []}, "differing case must not alias"
for index, response in enumerate((untitled, encoded_unicode, remote), start=3):
    assert response and response.get("data"), f"opaque form {index} must work: {response}"


# 4. Encoded reserved separators retain their URI structure. `%2F` is one
#    path-segment byte, `/` separates segments, and `%252F` is the literal
#    three-character sequence `%2F`; these identities must not collapse.
ENCODED = "def alpha() -> void:\n    x: i64 = 1\n"
SEPARATOR = "def bravo() -> void:\n    y: bool = true\n"
PERCENT_TEXT = "def charlie() -> void:\n    z: f64 = 1.0\n"


def reserved_separator_case(client):
    open_doc(client, "file:///a%2Fb.elisa", ENCODED)
    open_doc(client, "file:///a/b.elisa", SEPARATOR)
    open_doc(client, "file:///a%252Fb.elisa", PERCENT_TEXT)
    encoded_slash = tokens(client, "file:///a%2Fb.elisa")
    path_separator = tokens(client, "file:///a/b.elisa")
    encoded_percent = tokens(client, "file:///a%252Fb.elisa")
    lowercase_escape = tokens(client, "file:///a%2fb.elisa")
    return encoded_slash, path_separator, encoded_percent, lowercase_escape


(encoded_slash, path_separator, encoded_percent, lowercase_escape), _ = run_session(
    reserved_separator_case
)
for index, response in enumerate((encoded_slash, path_separator, encoded_percent), start=2):
    assert response and response.get("data"), f"distinct URI {index} must resolve: {response}"
assert encoded_slash != path_separator, "encoded slash must not alias a path separator"
assert encoded_slash != encoded_percent, "encoded percent must not double-decode into encoded slash"
assert path_separator != encoded_percent, "literal percent sequence must remain distinct"
assert lowercase_escape == encoded_slash, "hex case in a retained escape must canonicalize"


# 5. Parsed file-URI components stay distinct at their delimiters. The
# authority is case-normalized for file URIs; path/query non-reserved escapes
# decode bytewise (including UTF-8); query participates in identity; fragment
# does not. Raw Unicode and its UTF-8 percent form therefore resolve together.
def file_component_case(client):
    open_doc(
        client,
        "FiLe://EXAMPLE.test/caf%C3%A9%20space.elisa?q=%C3%A9#first",
        GOOD,
    )
    component_alias = tokens(
        client,
        "file://example.test/café space.elisa?q=é#second",
    )
    different_query = tokens(
        client,
        "file://example.test/café space.elisa?q=e#second",
    )
    other_authority_text = "def two() -> void:\n    y: bool = true\n"
    open_doc(
        client,
        "file://other.test/caf%C3%A9%20space.elisa?q=%C3%A9",
        other_authority_text,
    )
    other_authority = tokens(
        client,
        "file://other.test/café space.elisa?q=é",
    )

    open_doc(client, "file:/single/path.elisa", GOOD)
    single_slash = tokens(client, "FILE:/single/path.elisa#fragment")
    triple_slash = tokens(client, "file:///single/path.elisa")
    return component_alias, different_query, other_authority, single_slash, triple_slash


(component_alias, different_query, other_authority, single_slash, triple_slash), _ = run_session(file_component_case)
assert component_alias and component_alias.get("data"), (
    "scheme, file authority, UTF-8 path/query escapes, and fragment parsing "
    f"must preserve the established alias: {component_alias}"
)
assert different_query == {"data": []}, "query text remains part of document identity"
assert other_authority and other_authority.get("data"), "non-local file authority remains a distinct usable identity"
assert other_authority != component_alias, "different file authorities cannot share one document slot"
assert single_slash and single_slash.get("data"), "scheme case and fragment parsing must work without authority"
assert triple_slash == {"data": []}, "file:/ and file:/// retain distinct URI authority structure"


# 6. Non-file schemes are still local overlays. Their scheme and UTF-8 escape
# spelling canonicalize for cache identity, but no URI is fetched.
def remote_overlay_case(client):
    open_doc(client, "HTTPS://example.test/caf%C3%A9.elisa", GOOD)
    alias = tokens(client, "https://example.test/café.elisa")
    return alias


remote_alias, _ = run_session(remote_overlay_case)
assert remote_alias and remote_alias.get("data"), (
    "non-file URI must remain an in-memory overlay with component aliases"
)

print("uri OK: structured components, equivalence, reserved delimiters, spelling echo, malformed safety, opaque schemes")
PY
