#!/usr/bin/env bash
# A03: analysis-call counters prove providers reuse the retained snapshot.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]
uri = "file:///analysis-cache.elisa"
source = (
    "def alpha(x: i64) -> i64:\n"
    "    local: i64 = x\n"
    "    return local + beta()\n"
    "def beta() -> i64:\n"
    "    return 1\n"
)
edited = "\n" + source

ANALYSIS_COUNTERS = (
    "tokenize_calls",
    "parse_calls",
    "check_calls",
    "adapter_query_calls",
    "symbol_index_build_calls",
    "occurrence_index_build_calls",
)


def stats(client):
    response = client.request("$/elisa/stats", {})
    assert "result" in response and isinstance(response["result"], dict), response
    result = response["result"]
    analysis = result.get("analysis")
    assert isinstance(analysis, dict), result
    for name in ANALYSIS_COUNTERS:
        assert type(analysis.get(name)) is int and analysis[name] >= 0, (name, analysis)
    line_index = result.get("line_index")
    assert isinstance(line_index, dict), result
    for name in ("entries", "cached_documents", "stored_entries", "capacity_entries", "build_calls", "fallback_build_calls"):
        assert type(line_index.get(name)) is int and line_index[name] >= 0, (name, line_index)
    return result


with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {
            "uri": uri,
            "languageId": "Elisa",
            "version": 1,
            "text": source,
        }
    })

    opened = stats(client)
    assert (opened["analysis"]["tokenize_calls"], opened["analysis"]["parse_calls"], opened["analysis"]["check_calls"]) == (1, 1, 1), opened
    assert opened["analysis"]["symbol_index_build_calls"] == 1, opened
    assert opened["analysis"]["occurrence_index_build_calls"] == 1, opened
    assert opened["analysis"]["adapter_query_calls"] > 0, opened
    assert opened["line_index"]["entries"] == source.count("\n") + 1, opened
    assert opened["line_index"]["build_calls"] == 1, opened
    assert opened["line_index"]["fallback_build_calls"] == 0, opened

    line = source.splitlines()[2]
    beta_char = line.index("beta") + 1
    responses = [
        client.request("textDocument/semanticTokens/full", {
            "textDocument": {"uri": uri},
        }),
        client.request("textDocument/hover", {
            "textDocument": {"uri": uri},
            "position": {"line": 0, "character": 5},
        }),
        client.request("textDocument/documentSymbol", {
            "textDocument": {"uri": uri},
        }),
        client.request("textDocument/foldingRange", {
            "textDocument": {"uri": uri},
        }),
        client.request("textDocument/selectionRange", {
            "textDocument": {"uri": uri},
            "positions": [{"line": 2, "character": line.index("local") + 1}],
        }),
        client.request("textDocument/selectionRange", {
            "textDocument": {"uri": uri},
            "positions": [{"line": 2, "character": line.index("local") + 1}],
        }),
        client.request("textDocument/signatureHelp", {
            "textDocument": {"uri": uri},
            "position": {"line": 2, "character": line.index("beta") + len("beta(")},
        }),
        client.request("textDocument/signatureHelp", {
            "textDocument": {"uri": uri},
            "position": {"line": 2, "character": line.index("beta") + len("beta(")},
        }),
        client.request("textDocument/definition", {
            "textDocument": {"uri": uri},
            "position": {"line": 2, "character": beta_char},
        }),
        client.request("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": 2, "character": beta_char},
            "context": {"includeDeclaration": True},
        }),
    ]
    for response in responses:
        assert "result" in response, response
    assert responses[0]["result"]["data"], responses[0]
    assert responses[1]["result"] is not None, responses[1]
    assert responses[2]["result"], responses[2]
    assert responses[3]["result"], responses[3]
    assert responses[4]["result"], responses[4]
    assert responses[5]["result"], responses[5]
    assert responses[6]["result"]["signatures"][0]["label"] == "beta()", responses[6]
    assert responses[7]["result"]["signatures"][0]["label"] == "beta()", responses[7]
    assert responses[8]["result"] is not None, responses[8]
    assert responses[9]["result"], responses[9]
    for _ in range(3):
        repeated_hover = client.request("textDocument/hover", {
            "textDocument": {"uri": uri},
            "position": {"line": 0, "character": 5},
        })
        assert repeated_hover.get("result", {}).get("range", {}).get("start", {}).get("line") == 0, repeated_hover
    for _ in range(2):
        repeated_folding = client.request("textDocument/foldingRange", {
            "textDocument": {"uri": uri},
        })
        assert repeated_folding.get("result") == responses[3]["result"], repeated_folding

    cached = stats(client)
    assert cached == opened, f"cached providers performed analysis or adapter queries: {opened} -> {cached}"
    assert cached["line_index"]["build_calls"] == opened["line_index"]["build_calls"], cached
    assert cached["line_index"]["fallback_build_calls"] == 0, cached

    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{"text": edited}],
    })
    after_edit = stats(client)
    for key in ("tokenize_calls", "parse_calls", "check_calls",
                "symbol_index_build_calls", "occurrence_index_build_calls"):
        assert after_edit["analysis"][key] == opened["analysis"][key] + 1, (key, opened, after_edit)
    assert after_edit["analysis"]["adapter_query_calls"] > opened["analysis"]["adapter_query_calls"], (opened, after_edit)
    assert after_edit["line_index"]["entries"] == edited.count("\n") + 1, after_edit
    assert after_edit["line_index"]["build_calls"] == opened["line_index"]["build_calls"] + 1, after_edit
    assert after_edit["line_index"]["fallback_build_calls"] == 0, after_edit
    shifted_line = edited.splitlines()[3]
    shifted_selection = client.request("textDocument/selectionRange", {
        "textDocument": {"uri": uri},
        "positions": [{"line": 3, "character": shifted_line.index("local") + 1}],
    })
    assert shifted_selection.get("result"), shifted_selection
    assert shifted_selection["result"][0]["range"]["start"]["line"] == 3, shifted_selection
    shifted_signature = client.request("textDocument/signatureHelp", {
        "textDocument": {"uri": uri},
        "position": {"line": 3, "character": shifted_line.index("beta") + len("beta(")},
    })
    assert shifted_signature.get("result", {}).get("signatures", [{}])[0].get("label") == "beta()", shifted_signature
    shifted_hover = client.request("textDocument/hover", {
        "textDocument": {"uri": uri},
        "position": {"line": 1, "character": 5},
    })
    assert shifted_hover.get("result", {}).get("range", {}).get("start", {}).get("line") == 1, shifted_hover
    after_position_queries = stats(client)
    assert after_position_queries["line_index"]["build_calls"] == after_edit["line_index"]["build_calls"], after_position_queries
    assert after_position_queries["line_index"]["fallback_build_calls"] == 0, after_position_queries

    # A lower version is stale; a higher version with invalid change content is
    # malformed. Each is ignored before any frontend or adapter work begins.
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 1},
        "contentChanges": [{"text": source}],
    })
    after_stale = stats(client)
    assert after_stale == after_position_queries, f"stale change performed analysis: {after_position_queries} -> {after_stale}"

    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 3},
        "contentChanges": [{"text": 17}],
    })
    after_malformed = stats(client)
    assert after_malformed == after_position_queries, f"malformed change performed analysis: {after_position_queries} -> {after_malformed}"

    # A successful replacement that removes all declarations must replace all
    # derived caches too; none of the prior snapshot's symbols or resolver
    # records may leak through providers after the source changes.
    comment_only = "# replacement snapshot has no declarations\n"
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 4},
        "contentChanges": [{"text": comment_only}],
    })
    no_symbols = client.request("textDocument/documentSymbol", {
        "textDocument": {"uri": uri},
    })
    comment_tokens = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri},
    })
    no_hover = client.request("textDocument/hover", {
        "textDocument": {"uri": uri}, "position": {"line": 0, "character": 3},
    })
    no_definition = client.request("textDocument/definition", {
        "textDocument": {"uri": uri}, "position": {"line": 0, "character": 3},
    })
    no_references = client.request("textDocument/references", {
        "textDocument": {"uri": uri},
        "position": {"line": 0, "character": 3},
        "context": {"includeDeclaration": True},
    })
    no_highlights = client.request("textDocument/documentHighlight", {
        "textDocument": {"uri": uri}, "position": {"line": 0, "character": 3},
    })
    no_signature = client.request("textDocument/signatureHelp", {
        "textDocument": {"uri": uri}, "position": {"line": 0, "character": 3},
    })
    assert no_symbols.get("result") == [], no_symbols
    assert comment_tokens.get("result", {}).get("data"), comment_tokens
    assert no_hover.get("result", "missing") is None, no_hover
    assert no_definition.get("result", "missing") is None, no_definition
    assert no_references.get("result") == [], no_references
    assert no_highlights.get("result") == [], no_highlights
    assert no_signature.get("result", "missing") is None, no_signature

    # The retained sidecar is capped at 1,048,576 line starts. A source with
    # one more entry must use one worker-local fallback shared by every
    # analysis-time provider, then return to the retained path when replaced.
    before_budget = stats(client)
    over_budget = "\n" * 1_048_576
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 5},
        "contentChanges": [{"text": over_budget}],
    })
    after_budget = stats(client)
    assert after_budget["line_index"]["entries"] == 0, after_budget
    assert after_budget["line_index"]["cached_documents"] == 0, after_budget
    assert after_budget["line_index"]["stored_entries"] == 0, after_budget
    assert after_budget["line_index"]["build_calls"] == before_budget["line_index"]["build_calls"], after_budget
    assert after_budget["line_index"]["fallback_build_calls"] == before_budget["line_index"]["fallback_build_calls"] + 1, (before_budget, after_budget)
    oversized_hover = client.request("textDocument/hover", {
        "textDocument": {"uri": uri},
        "position": {"line": 0, "character": 0},
    })
    assert oversized_hover.get("result", "missing") is None, oversized_hover
    after_budget_hover = stats(client)
    assert after_budget_hover["line_index"]["fallback_build_calls"] == after_budget["line_index"]["fallback_build_calls"] + 1, after_budget_hover

    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 6},
        "contentChanges": [{"text": source}],
    })
    back_under_budget = stats(client)
    assert back_under_budget["line_index"]["entries"] == source.count("\n") + 1, back_under_budget
    assert back_under_budget["line_index"]["cached_documents"] == 1, back_under_budget
    assert back_under_budget["line_index"]["fallback_build_calls"] == after_budget_hover["line_index"]["fallback_build_calls"], back_under_budget

    client.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
    closed = stats(client)
    assert closed["line_index"]["entries"] == 0, closed
    assert closed["line_index"]["cached_documents"] == 0, closed
    assert closed["line_index"]["stored_entries"] == 0, closed

    client.finish(timeout=30)

print("analysis cache OK: providers share retained line indexes; over-budget workers build one fallback; edits rebuild once")
PY
