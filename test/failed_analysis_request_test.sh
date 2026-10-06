#!/usr/bin/env bash
# P01: a recoverable failed frontend snapshot produces InternalError for
# providers that require it, while source-only and absent-document requests
# keep their ordinary result behavior. The failure trigger exists only in a
# temporary server copy; the shipped binary has no test hook.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ELISAC_BIN="${ELISAC:-$HOME/.elisac/elisac-stage0}"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-$ROOT/../Elisa-compiler}"
[[ -x "$ELISAC_BIN" ]] || { echo "error: no compiler at $ELISAC_BIN (set ELISAC)" >&2; exit 2; }
[[ -d "$COMPILER_ROOT/src/semantic" ]] || { echo "error: compiler checkout not found at $COMPILER_ROOT" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "error: missing clang" >&2; exit 2; }

WORK="$(mktemp -d)"
cleanup_test_work() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ -n "${WORK:-}" && -e "$WORK" ]]; then
    # build.sh leaves content-addressed source snapshots immutable. Restore
    # owner write permission only inside this private test directory so rm can
    # remove nested snapshot directories. Cleanup diagnostics must not replace
    # the protocol test's actual exit status.
    chmod -R u+w "$WORK" 2>/dev/null || true
    if ! rm -rf "$WORK"; then
      printf 'warning: could not remove temporary test directory %s (test exit status %s)\n' \
        "$WORK" "$status" >&2
    fi
  fi
  exit "$status"
}
trap cleanup_test_work EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
TEST_ROOT="$WORK/Elisa-LSP"
mkdir -p "$TEST_ROOT/scripts"
cp -R "$ROOT/src" "$TEST_ROOT/src"
cp "$ROOT/build.sh" "$ROOT/project.json" "$TEST_ROOT/"
cp "$ROOT/scripts/build_hashes.py" "$TEST_ROOT/scripts/"
cp "$ROOT/scripts/generate_diagnostic_codes.py" "$TEST_ROOT/scripts/"

# Force only sources beginning with '#' to return a failed worker packet, and
# corrupt one request-local cached span. Both mutations are test-only and exist
# only in this temporary copy; the shipped binary has no fault-injection hook.
python3 - "$TEST_ROOT/src/main.elisa" "$TEST_ROOT/src/features/signature_help.elisa" "$TEST_ROOT/src/features/definition.elisa" "$TEST_ROOT/src/features/references.elisa" "$TEST_ROOT/src/features/document_highlight.elisa" "$TEST_ROOT/src/features/document_symbols.elisa" "$TEST_ROOT/src/semtokens.elisa" "$TEST_ROOT/src/features/folding.elisa" "$TEST_ROOT/src/features/selection.elisa" <<'PY'
from pathlib import Path
import sys

main_path = Path(sys.argv[1])
source = main_path.read_text(encoding="utf-8")
needle = "        if analysis_valid:\n"
assert source.count(needle) == 1, "expected one worker frontend validation branch"
source = source.replace(needle, "        if analysis_valid and source[0] != 35:\n", 1)
hover_span = "    hover_start: mutable usize = document.caches.hover_start\n"
assert source.count(hover_span) == 1, "expected one request-local hover span"
source = source.replace(
    hover_span,
    hover_span + "    hover_start <- document_storage.count if document.lifecycle.version == 3\n",
    1,
)
main_path.write_text(source, encoding="utf-8")

signature_path = Path(sys.argv[2])
signature_source = signature_path.read_text(encoding="utf-8")
span = "    signature_start: mutable usize = document.caches.signature_start\n"
assert signature_source.count(span) == 1, "expected one request-local signature span"
signature_source = signature_source.replace(
    span,
    span + "    signature_start <- document_storage.count if document.lifecycle.version == 3\n",
    1,
)
signature_path.write_text(signature_source, encoding="utf-8")

definition_path = Path(sys.argv[3])
definition_source = definition_path.read_text(encoding="utf-8")
span = "    definition_start: mutable usize = document.caches.hover_start\n"
assert definition_source.count(span) == 1, "expected one request-local definition span"
definition_source = definition_source.replace(
    span,
    span + "    definition_start <- document_storage.count if document.lifecycle.version == 3\n",
    1,
)
definition_path.write_text(definition_source, encoding="utf-8")

references_path = Path(sys.argv[4])
references_source = references_path.read_text(encoding="utf-8")
span = "    references_start: mutable usize = document.caches.hover_start\n"
assert references_source.count(span) == 1, "expected one request-local references span"
references_source = references_source.replace(
    span,
    span + "    references_start <- document_storage.count if document.lifecycle.version == 3\n",
    1,
)
references_path.write_text(references_source, encoding="utf-8")

highlight_path = Path(sys.argv[5])
highlight_source = highlight_path.read_text(encoding="utf-8")
span = "    highlight_start: mutable usize = document.caches.hover_start\n"
assert highlight_source.count(span) == 1, "expected one request-local highlight span"
highlight_source = highlight_source.replace(
    span,
    span + "    highlight_start <- document_storage.count if document.lifecycle.version == 3\n",
    1,
)
highlight_path.write_text(highlight_source, encoding="utf-8")

symbols_path = Path(sys.argv[6])
symbols_source = symbols_path.read_text(encoding="utf-8")
span = "    symbols_start: mutable usize = document.caches.symbols_start\n"
assert symbols_source.count(span) == 1, "expected one request-local document-symbol span"
symbols_source = symbols_source.replace(
    span,
    span + "    symbols_start <- document_storage.count if document.lifecycle.version == 3\n",
    1,
)
symbols_path.write_text(symbols_source, encoding="utf-8")

semtokens_path = Path(sys.argv[7])
semtokens_source = semtokens_path.read_text(encoding="utf-8")
span = "    semantic_start: mutable usize = document.caches.semantic_start\n"
assert semtokens_source.count(span) == 2, "expected one request-local full and range semantic-token span"
semtokens_source = semtokens_source.replace(
    span,
    span + "    semantic_start <- document_storage.count if document.lifecycle.version == 3\n",
    2,
)
semtokens_path.write_text(semtokens_source, encoding="utf-8")

for index, feature in ((8, "folding"), (9, "selection")):
    feature_path = Path(sys.argv[index])
    feature_source = feature_path.read_text(encoding="utf-8")
    span = "    source_start: mutable usize = document.source.text_start\n"
    assert feature_source.count(span) == 1, f"expected one request-local source span in {feature}"
    feature_source = feature_source.replace(
        span,
        span + "    source_start <- document_storage.count if document.lifecycle.version == 3\n",
        1,
    )
    feature_path.write_text(feature_source, encoding="utf-8")
PY

ELISAC="$ELISAC_BIN" ELISA_COMPILER_ROOT="$COMPILER_ROOT" \
  bash "$TEST_ROOT/build.sh" --release

python3 - "$TEST_ROOT/build/elisa-lsp" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]
uri = "file:///failed-analysis.elisa"
td = {"textDocument": {"uri": uri}}
position = {"line": 0, "character": 0}
requests = [
    ("textDocument/semanticTokens/full", td),
    ("textDocument/semanticTokens/range", {**td, "range": {"start": position, "end": position}}),
    ("textDocument/signatureHelp", {**td, "position": position}),
    ("textDocument/definition", {**td, "position": position}),
    ("textDocument/references", {**td, "position": position, "context": {"includeDeclaration": True}}),
    ("textDocument/documentHighlight", {**td, "position": position}),
    ("textDocument/documentSymbol", td),
]


def open_doc(client, text, version):
    client.notify("textDocument/didOpen" if version == 1 else "textDocument/didChange", {
        "textDocument": {"uri": uri, "languageId": "Elisa", "version": version, "text": text}
    } if version == 1 else {
        "textDocument": {"uri": uri, "version": version},
        "contentChanges": [{"text": text}],
    })


# The temporary optimized binary may be launched while the canonical suite is
# compiling another isolated fixture. Keep the wait finite but allow the host
# loader and a busy machine enough time to initialize the server.
with LspSession(srv, startup_timeout=30, request_timeout=30, teardown_timeout=30) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized

    # No open document is not an analyzer failure.
    for method, params in requests:
        response = client.request(method, params)
        assert "result" in response and "error" not in response, (method, response)

    failed_source = (
        "# force recoverable frontend failure\n"
        "def f(xs: darray[i64]) -> i64:\n"
        "    total: mutable i64 = 0\n"
        "    r: i64 =\n"
        "        for x in xs |acc = 0| -> acc:\n"
        "            total <- total + x\n"
        "            acc <- acc + 1\n"
        "    return total + r\n"
    )
    open_doc(client, failed_source, 1)
    for method, params in requests:
        response = client.request(method, params)
        assert response.get("error", {}).get("code") == -32603, (method, response)
        assert response["error"].get("message") == "InternalError", (method, response)

    failed_stats = client.request("$/elisa/stats", {})["result"]
    assert failed_stats["snapshots"] == {
        "open": 1,
        "pending": 0,
        "ready": 0,
        "failed": 1,
    }, failed_stats

    # Source-only requests remain available, and a later valid snapshot recovers.
    folding = client.request("textDocument/foldingRange", td)
    assert "result" in folding and "error" not in folding, folding
    selection = client.request("textDocument/selectionRange", {**td, "positions": [position]})
    assert "result" in selection and "error" not in selection, selection
    failed_hover_id = "failed-analysis-loop-hover"
    failed_capture_line = failed_source.splitlines()[4]
    failed_capture_open = failed_capture_line.index("|")
    failed_capture_close = failed_capture_line.index("|", failed_capture_open + 1)
    failed_hover = client.request(
        "textDocument/hover",
        {**td, "position": {"line": 4, "character": failed_capture_open + 1}},
        req_id=failed_hover_id,
    )
    assert "result" in failed_hover and "error" not in failed_hover, failed_hover
    assert failed_hover["result"]["contents"]["value"].startswith("**Loop header**"), failed_hover
    assert failed_hover["result"]["range"] == {
        "start": {"line": 4, "character": failed_capture_open},
        "end": {"line": 4, "character": failed_capture_close + 1},
    }, failed_hover
    assert [message for message in client.all_messages if message.get("id") == failed_hover_id] == [failed_hover]
    open_doc(client, "def recovered() -> i64:\n    return 7\n", 2)
    for method, params in requests:
        response = client.request(method, params)
        assert "result" in response and "error" not in response, (method, response)
    recovered_stats = client.request("$/elisa/stats", {})["result"]
    assert recovered_stats["snapshots"] == {
        "open": 1,
        "pending": 0,
        "ready": 1,
        "failed": 0,
    }, recovered_stats
    symbols = client.request("textDocument/documentSymbol", td)
    assert [item["name"] for item in symbols["result"]] == ["recovered"], symbols

    # A Ready document with a corrupt retained signature span is an internal
    # cache failure, not a normal null result. A later accepted version must
    # replace the cache and restore provider behavior.
    signature_source = (
        "def add(value: i64) -> i64:\n"
        "    return value\n"
        "def caller() -> i64:\n"
        "    return add(1)\n"
    )
    open_doc(client, signature_source, 3)
    signature_params = {
        "textDocument": {"uri": uri},
        "position": {"line": 3, "character": 16},
    }
    corrupt_signature_id = "signature-span-corruption"
    corrupt_signature = client.request(
        "textDocument/signatureHelp", signature_params, req_id=corrupt_signature_id
    )
    assert corrupt_signature.get("error", {}).get("code") == -32603, corrupt_signature
    assert corrupt_signature["error"].get("message") == "InternalError", corrupt_signature
    signature_replies = [
        message for message in client.all_messages if message.get("id") == corrupt_signature_id
    ]
    assert signature_replies == [corrupt_signature], signature_replies

    # Full and range semantic tokens share retained storage but each provider
    # must validate the span before constructing a view. Corrupt both through
    # a request-local copy and ensure each request has one error response.
    semantic_requests = [
        ("textDocument/semanticTokens/full", td, "semantic-full-span-corruption"),
        (
            "textDocument/semanticTokens/range",
            {**td, "range": {"start": position, "end": {"line": 4, "character": 0}}},
            "semantic-range-span-corruption",
        ),
    ]
    for method, params, request_id in semantic_requests:
        response = client.request(method, params, req_id=request_id)
        assert response.get("error", {}).get("code") == -32603, (method, response)
        assert response["error"].get("message") == "InternalError", (method, response)
        replies = [message for message in client.all_messages if message.get("id") == request_id]
        assert replies == [response], (method, replies)

    source_only_requests = [
        ("textDocument/foldingRange", td, "folding-source-span-corruption"),
        (
            "textDocument/selectionRange",
            {**td, "positions": [{"line": 3, "character": 12}]},
            "selection-source-span-corruption",
        ),
    ]
    for method, params, request_id in source_only_requests:
        response = client.request(method, params, req_id=request_id)
        assert response.get("error", {}).get("code") == -32603, (method, response)
        assert response["error"].get("message") == "InternalError", (method, response)
        replies = [message for message in client.all_messages if message.get("id") == request_id]
        assert replies == [response], (method, replies)

    # Document symbols uses the cached JSON span directly. Corrupting its
    # request-local start must also yield one InternalError and leave version 4
    # able to use the intact snapshot.
    corrupt_symbols_id = "document-symbol-span-corruption"
    corrupt_symbols = client.request(
        "textDocument/documentSymbol", td, req_id=corrupt_symbols_id
    )
    assert corrupt_symbols.get("error", {}).get("code") == -32603, corrupt_symbols
    assert corrupt_symbols["error"].get("message") == "InternalError", corrupt_symbols
    symbols_replies = [
        message for message in client.all_messages if message.get("id") == corrupt_symbols_id
    ]
    assert symbols_replies == [corrupt_symbols], symbols_replies

    # The definition provider has an independent request-local span. Corrupt
    # it on the same Ready snapshot, assert exactly one InternalError response,
    # then verify the next accepted version restores the actual target range.
    definition_params = {
        "textDocument": {"uri": uri},
        "position": {"line": 3, "character": 12},
    }
    corrupt_definition_id = "definition-span-corruption"
    corrupt_definition = client.request(
        "textDocument/definition", definition_params, req_id=corrupt_definition_id
    )
    assert corrupt_definition.get("error", {}).get("code") == -32603, corrupt_definition
    assert corrupt_definition["error"].get("message") == "InternalError", corrupt_definition
    definition_replies = [
        message
        for message in client.all_messages
        if message.get("id") == corrupt_definition_id
    ]
    assert definition_replies == [corrupt_definition], definition_replies

    references_params = {
        "textDocument": {"uri": uri},
        "position": {"line": 3, "character": 12},
        "context": {"includeDeclaration": True},
    }
    corrupt_references_id = "references-span-corruption"
    corrupt_references = client.request(
        "textDocument/references", references_params, req_id=corrupt_references_id
    )
    assert corrupt_references.get("error", {}).get("code") == -32603, corrupt_references
    assert corrupt_references["error"].get("message") == "InternalError", corrupt_references
    references_replies = [
        message
        for message in client.all_messages
        if message.get("id") == corrupt_references_id
    ]
    assert references_replies == [corrupt_references], references_replies

    highlight_params = {
        "textDocument": {"uri": uri},
        "position": {"line": 3, "character": 12},
    }
    corrupt_highlight_id = "highlight-span-corruption"
    corrupt_highlight = client.request(
        "textDocument/documentHighlight", highlight_params, req_id=corrupt_highlight_id
    )
    assert corrupt_highlight.get("error", {}).get("code") == -32603, corrupt_highlight
    assert corrupt_highlight["error"].get("message") == "InternalError", corrupt_highlight
    highlight_replies = [
        message
        for message in client.all_messages
        if message.get("id") == corrupt_highlight_id
    ]
    assert highlight_replies == [corrupt_highlight], highlight_replies

    hover_params = {
        "textDocument": {"uri": uri},
        "position": {"line": 3, "character": 12},
    }
    corrupt_hover_id = "hover-span-corruption"
    corrupt_hover = client.request("textDocument/hover", hover_params, req_id=corrupt_hover_id)
    assert corrupt_hover.get("error", {}).get("code") == -32603, corrupt_hover
    assert corrupt_hover["error"].get("message") == "InternalError", corrupt_hover
    hover_replies = [message for message in client.all_messages if message.get("id") == corrupt_hover_id]
    assert hover_replies == [corrupt_hover], hover_replies

    open_doc(client, signature_source, 4)
    recovered_signature = client.request("textDocument/signatureHelp", signature_params)
    assert "result" in recovered_signature and "error" not in recovered_signature, recovered_signature
    assert recovered_signature["result"]["signatures"][0]["label"] == "add(value)", recovered_signature
    recovered_semantic = client.request("textDocument/semanticTokens/full", td)
    assert isinstance(recovered_semantic.get("result", {}).get("data"), list), recovered_semantic
    assert recovered_semantic["result"]["data"], recovered_semantic
    recovered_semantic_range = client.request(
        "textDocument/semanticTokens/range",
        {**td, "range": {"start": position, "end": {"line": 4, "character": 0}}},
    )
    assert isinstance(recovered_semantic_range.get("result", {}).get("data"), list), recovered_semantic_range
    recovered_symbols = client.request("textDocument/documentSymbol", td)
    assert [item["name"] for item in recovered_symbols.get("result", [])] == ["add", "caller"], recovered_symbols
    recovered_hover = client.request("textDocument/hover", hover_params)
    assert recovered_hover.get("result", {}).get("contents", {}).get("value") == "```elisa\ndef add(value: i64) -> i64:\n```", recovered_hover
    recovered_folding = client.request("textDocument/foldingRange", td)
    assert isinstance(recovered_folding.get("result"), list), recovered_folding
    recovered_selection = client.request(
        "textDocument/selectionRange",
        {**td, "positions": [{"line": 3, "character": 12}]},
    )
    assert isinstance(recovered_selection.get("result"), list), recovered_selection
    recovered_definition = client.request("textDocument/definition", definition_params)
    assert recovered_definition.get("result") == {
        "uri": uri,
        "range": {
            "start": {"line": 0, "character": 4},
            "end": {"line": 0, "character": 7},
        },
    }, recovered_definition
    expected_call_and_declaration = [
        {
            "uri": uri,
            "range": {
                "start": {"line": 0, "character": 4},
                "end": {"line": 0, "character": 7},
            },
        },
        {
            "uri": uri,
            "range": {
                "start": {"line": 3, "character": 11},
                "end": {"line": 3, "character": 14},
            },
        },
    ]
    recovered_references = client.request("textDocument/references", references_params)
    assert recovered_references.get("result") == expected_call_and_declaration, recovered_references
    recovered_highlight = client.request("textDocument/documentHighlight", highlight_params)
    assert recovered_highlight.get("result") == [
        {
            "range": {
                "start": {"line": 0, "character": 4},
                "end": {"line": 0, "character": 7},
            },
            "kind": 1,
        },
        {
            "range": {
                "start": {"line": 3, "character": 11},
                "end": {"line": 3, "character": 14},
            },
            "kind": 2,
        },
    ], recovered_highlight
    client.finish(timeout=30)

print("failed analysis requests OK: analyzer and Ready-cache failures for semantic tokens, signature, definition, references, highlights, symbols, hover, folding, and selection; Failed-state loop-hover fallback; absent-doc behavior; exactly-once responses; and recovery")
PY
