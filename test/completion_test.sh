#!/usr/bin/env bash
# F05 completion slice: cached declarations, exact-owner parameters, on-demand
# signature resolution, exact edits, conservative declines, and validation.
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
uri = "file:///completion.elisa"
source = (
    "def render() -> i64:\n"
    "    return 1\n"
    "def reverse() -> i64:\n"
    "    return 1\n"
    "struct RenderBox:\n"
    "    count: i64\n"
    "enum RenderMode:\n"
    "    Fast\n"
    "def typed(value: RenderB) -> i64:\n"
    "    return 0\n"
    "def main() -> i64:\n"
    "    return render\n"
    "    # re\n"
    '    value: dstr = "re"\n'
    "    value.re\n"
    "def uses_param(parameter: i64) -> i64:\n"
    "    return par\n"
    "def uses_variant() -> i64:\n"
    "    return Fas\n"
    "def transform(first: i64, second: i64) -> i64:\n"
    "    return first\n"
    "def snippet_site() -> i64:\n"
    "    return tran\n"
    "def existing_call() -> i64:\n"
    "    return tran()\n"
    "def spaced_existing_call() -> i64:\n"
    "    return tran   ()\n"
)

with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    completion_provider = initialized["result"]["capabilities"].get("completionProvider")
    assert completion_provider == {"resolveProvider": True}, completion_provider
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": source}
    })

    # Cursor is in the middle of `render`; the complete token is replaced and
    # the exact prefix limits candidates. Ranking is deterministic.
    expression = client.request("textDocument/completion", {
        "textDocument": {"uri": uri},
        "position": {"line": 11, "character": 6},
        "context": {"triggerKind": 1},
    })
    assert "result" in expression, expression
    result = expression["result"]
    assert result["isIncomplete"] is True, result
    items = result["items"]
    assert [item["label"] for item in items] == ["render", "reverse"], items
    assert items[0]["kind"] == 3 and items[0]["detail"] == "function", items[0]
    assert "commitCharacters" not in items[0], items[0]
    for item in items:
        assert item["textEdit"] == {
            "range": {
                "start": {"line": 11, "character": 4},
                "end": {"line": 11, "character": 10},
            },
            "newText": item["label"],
        }, item

    # Resolve adds the retained function signature on demand, snapshot-tags
    # the item, and preserves fields owned by the client that round-trips it.
    resolve_item = dict(items[0])
    resolve_item["detail"] = "client detail"
    resolve_item["clientExtension"] = {"escaped": "quote: \\\" newline: \\n", "array": [1, True, None]}
    resolved = client.request("completionItem/resolve", {"item": resolve_item})
    assert "result" in resolved, resolved
    assert resolved["result"]["detail"] == "render()", resolved
    assert resolved["result"]["label"] == "render", resolved
    assert resolved["result"]["textEdit"] == resolve_item["textEdit"], resolved
    assert resolved["result"]["data"] == resolve_item["data"], resolved
    assert resolved["result"]["clientExtension"] == resolve_item["clientExtension"], resolved

    malformed_resolve = client.request("completionItem/resolve", {"item": []})
    assert malformed_resolve.get("error", {}).get("code") == -32602, malformed_resolve

    # A type annotation narrows to known same-file types.
    typed = client.request("textDocument/completion", {
        "textDocument": {"uri": uri},
        "position": {"line": 8, "character": 24},
    })
    assert [item["label"] for item in typed["result"]["items"]] == ["RenderBox"], typed
    assert typed["result"]["items"][0]["kind"] == 7, typed
    unresolved_item = dict(typed["result"]["items"][0])
    unresolved_item["clientExtension"] = {"raw": ["backslash " + chr(92), "tab " + chr(9), False, 2.5]}
    unresolved = client.request("completionItem/resolve", {"item": unresolved_item})
    assert unresolved.get("result") == unresolved_item, unresolved

    # Exact function ownership makes parameters available in a completed
    # function body, without adding parameter names to type contexts.
    parameter = client.request("textDocument/completion", {
        "textDocument": {"uri": uri},
        "position": {"line": 16, "character": 14},
    })
    assert [item["label"] for item in parameter["result"]["items"]] == ["parameter"], parameter
    assert parameter["result"]["items"][0]["kind"] == 6, parameter
    assert parameter["result"]["items"][0]["detail"] == "parameter", parameter

    # Enum variants are retained separately from declaration symbols and are
    # offered as standard EnumMember items in expression context.
    variant = client.request("textDocument/completion", {
        "textDocument": {"uri": uri},
        "position": {"line": 18, "character": 14},
    })
    assert [item["label"] for item in variant["result"]["items"]] == ["Fast"], variant
    assert variant["result"]["items"][0]["kind"] == 20, variant
    assert variant["result"]["items"][0]["detail"] == "enum variant", variant

    # A bare variant name shared by multiple enum owners is ambiguous and must
    # not leak as an apparently unique completion.
    ambiguous_uri = "file:///completion-ambiguous-variants.elisa"
    ambiguous_source = (
        "enum FirstMode:\n"
        "    Shared\n"
        "enum SecondMode:\n"
        "    Shared\n"
        "def uses_shared() -> i64:\n"
        "    return Shared\n"
    )
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": ambiguous_uri, "languageId": "Elisa", "version": 1, "text": ambiguous_source}
    })
    ambiguous_symbols = client.request("textDocument/documentSymbol", {"textDocument": {"uri": ambiguous_uri}})
    assert [symbol["name"] for symbol in ambiguous_symbols.get("result", [])] == ["FirstMode", "SecondMode", "uses_shared"], ambiguous_symbols
    ambiguous = client.request("textDocument/completion", {
        "textDocument": {"uri": ambiguous_uri},
        "position": {"line": 5, "character": 14},
    })
    assert ambiguous.get("result", {}).get("items") == [], ambiguous

    # Comments, ordinary strings, and member positions do not receive
    # unqualified same-file candidates.
    for line, character in ((12, 7), (13, 20), (14, 12)):
        declined = client.request("textDocument/completion", {
            "textDocument": {"uri": uri}, "position": {"line": line, "character": character}
        })
        assert declined["result"] == [], (line, declined)
    missing = client.request("textDocument/completion", {
        "textDocument": {"uri": "file:///missing.elisa"},
        "position": {"line": 0, "character": 0},
    })
    assert missing["result"] == [], missing

    malformed = client.request("textDocument/completion", {
        "textDocument": {"uri": uri},
        "position": {"line": 11, "character": 6},
        "context": {"triggerKind": 4},
    })
    assert malformed.get("error", {}).get("code") == -32602, malformed

    bad_trigger_character = client.request("textDocument/completion", {
        "textDocument": {"uri": uri},
        "position": {"line": 11, "character": 6},
        "context": {"triggerKind": 2, "triggerCharacter": "xy"},
    })
    assert bad_trigger_character.get("error", {}).get("code") == -32602, bad_trigger_character

    # A source-version change makes an old item's resolve data stale; the
    # server returns that item unchanged instead of borrowing the new snapshot.
    client.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{"text": source}],
    })
    stale_by_version = client.request("completionItem/resolve", {"item": items[0]})
    assert stale_by_version.get("result", {}).get("detail") == "function", stale_by_version

    current_completion = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 11, "character": 6}
    })
    current_item = current_completion["result"]["items"][0]
    client.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": uri, "languageId": "Elisa", "version": 2, "text": source}
    })
    stale_by_generation = client.request("completionItem/resolve", {"item": current_item})
    assert stale_by_generation.get("result", {}).get("detail") == "function", stale_by_generation

    # A visible root local with the same spelling replaces the global row.
    shadow_uri = "file:///completion-shadow.elisa"
    shadow_source = "def render() -> i64:\n    return 1\ndef main() -> i64:\n    render: i64 = 1\n    return re\n"
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": shadow_uri, "languageId": "Elisa", "version": 1, "text": shadow_source}
    })
    shadowed = client.request("textDocument/completion", {
        "textDocument": {"uri": shadow_uri}, "position": {"line": 4, "character": 13}
    })
    assert [item["label"] for item in shadowed["result"]["items"]] == ["render"], shadowed
    assert shadowed["result"]["items"][0]["detail"] == "local variable", shadowed

    # A parameter with the same spelling as a file-level function replaces
    # the global completion row with the correctly typed local candidate.
    parameter_shadow_source = (
        "def render() -> i64:\n"
        "    return 1\n"
        "def main(render: i64) -> i64:\n"
        "    return ren\n"
    )
    parameter_shadow_uri = "file:///completion-parameter-shadow.elisa"
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": parameter_shadow_uri, "languageId": "Elisa", "version": 1, "text": parameter_shadow_source}
    })
    parameter_shadow = client.request("textDocument/completion", {
        "textDocument": {"uri": parameter_shadow_uri}, "position": {"line": 3, "character": 14}
    })
    assert [item["label"] for item in parameter_shadow["result"]["items"]] == ["render"], parameter_shadow
    assert parameter_shadow["result"]["items"][0]["kind"] == 6, parameter_shadow

    # If an exact local row with the same spelling shadows a parameter, the
    # declaration-backed local candidate replaces both other candidates.
    parameter_local_source = (
        "def render() -> i64:\n"
        "    return 1\n"
        "def main(render: i64) -> i64:\n"
        "    render: i64 = 1\n"
        "    return ren\n"
    )
    parameter_local_uri = "file:///completion-parameter-local-shadow.elisa"
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": parameter_local_uri, "languageId": "Elisa", "version": 1, "text": parameter_local_source}
    })
    parameter_local = client.request("textDocument/completion", {
        "textDocument": {"uri": parameter_local_uri}, "position": {"line": 4, "character": 14}
    })
    assert [item["label"] for item in parameter_local["result"]["items"]] == ["render"], parameter_local
    assert parameter_local["result"]["items"][0]["kind"] == 6, parameter_local
    assert parameter_local["result"]["items"][0]["detail"] == "local variable", parameter_local

    # Declaration-backed locals at the function body's root indentation are
    # offered with variable kind and replace any same-name file-level row.
    local_source = (
        "def local_main() -> i64:\n"
        "    root_value: i64 = 1\n"
        "    return roo\n"
    )
    local_uri = "file:///completion-root-local.elisa"
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": local_uri, "languageId": "Elisa", "version": 1, "text": local_source}
    })
    local_result = client.request("textDocument/completion", {
        "textDocument": {"uri": local_uri}, "position": {"line": 2, "character": 14}
    })
    assert [item["label"] for item in local_result["result"]["items"]] == ["root_value"], local_result
    assert local_result["result"]["items"][0]["kind"] == 6, local_result
    assert local_result["result"]["items"][0]["detail"] == "local variable", local_result

    # A local declared inside a nested block is not visible to this root-scope
    # request and must not leak out of that indentation region.
    nested_source = (
        "def nested_main() -> i64:\n"
        "    nested_outer: i64 = 1\n"
        "    if true:\n"
        "        nested_inner: i64 = 1\n"
        "        return nes\n"
        "    else:\n"
        "        return nes\n"
        "    return nes\n"
    )
    nested_uri = "file:///completion-nested-local.elisa"
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": nested_uri, "languageId": "Elisa", "version": 1, "text": nested_source}
    })
    nested_visible = client.request("textDocument/completion", {
        "textDocument": {"uri": nested_uri}, "position": {"line": 4, "character": 18}
    })
    assert [item["label"] for item in nested_visible["result"]["items"]] == [
        "nested_inner", "nested_main", "nested_outer"
    ], nested_visible
    nested_local_item = next(item for item in nested_visible["result"]["items"] if item["label"] == "nested_inner")
    assert nested_local_item["detail"] == "local variable", nested_visible

    # An outdent into a sibling `else` block closes the first arm's local
    # visibility even though both blocks belong to the same function.
    nested_else = client.request("textDocument/completion", {
        "textDocument": {"uri": nested_uri}, "position": {"line": 6, "character": 18}
    })
    assert [item["label"] for item in nested_else["result"]["items"]] == ["nested_main", "nested_outer"], nested_else

    # A nested-block declaration also stays hidden after the containing block.
    nested_result = client.request("textDocument/completion", {
        "textDocument": {"uri": nested_uri}, "position": {"line": 7, "character": 14}
    })
    assert [item["label"] for item in nested_result["result"]["items"]] == ["nested_main", "nested_outer"], nested_result

    # A nested local shadows the parameter only in its indentation block. In
    # the sibling else arm the parameter is visible and replaces the global.
    scope_shadow_source = (
        "def render() -> i64:\n"
        "    return 1\n"
        "def nested_shadow(render: i64) -> i64:\n"
        "    if true:\n"
        "        render: i64 = 2\n"
        "        return ren\n"
        "    else:\n"
        "        return ren\n"
    )
    scope_shadow_uri = "file:///completion-scope-shadow.elisa"
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": scope_shadow_uri, "languageId": "Elisa", "version": 1, "text": scope_shadow_source}
    })
    scope_local = client.request("textDocument/completion", {
        "textDocument": {"uri": scope_shadow_uri}, "position": {"line": 5, "character": 18}
    })
    assert [item["label"] for item in scope_local["result"]["items"]] == ["render"], scope_local
    assert scope_local["result"]["items"][0]["detail"] == "local variable", scope_local
    scope_parameter = client.request("textDocument/completion", {
        "textDocument": {"uri": scope_shadow_uri}, "position": {"line": 7, "character": 18}
    })
    assert [item["label"] for item in scope_parameter["result"]["items"]] == ["render"], scope_parameter
    assert scope_parameter["result"]["items"][0]["detail"] == "parameter", scope_parameter

    # A local with the same spelling in another function must not suppress a
    # file-level function candidate at the caller's cursor.
    unrelated_local_source = (
        "def render() -> i64:\n"
        "    return 1\n"
        "def unrelated() -> i64:\n"
        "    render: i64 = 2\n"
        "    return 1\n"
        "def caller() -> i64:\n"
        "    return ren\n"
    )
    unrelated_local_uri = "file:///completion-unrelated-local.elisa"
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": unrelated_local_uri, "languageId": "Elisa", "version": 1, "text": unrelated_local_source}
    })
    unrelated_local = client.request("textDocument/completion", {
        "textDocument": {"uri": unrelated_local_uri}, "position": {"line": 6, "character": 14}
    })
    assert [item["label"] for item in unrelated_local["result"]["items"]] == ["render"], unrelated_local
    assert unrelated_local["result"]["items"][0]["detail"] == "function", unrelated_local

    # Clients that omit snippetSupport keep receiving plain insertion text.
    plain_function = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 22, "character": 15}
    })
    assert "result" in plain_function, plain_function
    plain_item = next(item for item in plain_function["result"]["items"] if item["label"] == "transform")
    assert plain_item["textEdit"]["newText"] == "transform", plain_item
    assert "insertTextFormat" not in plain_item, plain_item
    assert "labelDetails" not in plain_item, plain_item
    client.finish(timeout=30)


# Label details are negotiated independently from snippets and contain only
# parameter names from one unique retained same-file function signature.
label_details_caps = {"textDocument": {"completion": {"completionItem": {"labelDetailsSupport": True}}}}
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": label_details_caps})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": source}
    })
    result = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 22, "character": 15}
    })
    assert "result" in result, result
    item = next(item for item in result["result"]["items"] if item["label"] == "transform")
    assert item["labelDetails"] == {"detail": "(first, second)"}, item
    assert item["textEdit"]["newText"] == "transform", item
    assert "insertTextFormat" not in item, item
    parameter = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 16, "character": 14}
    })
    parameter_item = next(item for item in parameter["result"]["items"] if item["label"] == "parameter")
    assert "labelDetails" not in parameter_item, parameter_item
    render = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 11, "character": 17}
    })
    render_item = next(item for item in render["result"]["items"] if item["label"] == "render")
    assert render_item["labelDetails"] == {"detail": "()"}, render_item
    client.finish(timeout=30)


# Snippet-capable clients get argument placeholders only for a unique retained
# function signature. Zero-argument functions receive a simple call snippet.
snippet_caps = {"textDocument": {"completion": {"completionItem": {"snippetSupport": True}}}}
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": snippet_caps})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": source}
    })
    result = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 22, "character": 15}
    })
    assert "result" in result, result
    item = next(item for item in result["result"]["items"] if item["label"] == "transform")
    assert item["insertTextFormat"] == 2, item
    assert item["textEdit"]["newText"] == "transform(${1:first}, ${2:second})$0", item
    plain_local = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 11, "character": 17}
    })
    render = next(item for item in plain_local["result"]["items"] if item["label"] == "render")
    assert render["insertTextFormat"] == 2, render
    assert render["textEdit"]["newText"] == "render()$0", render
    client.finish(timeout=30)


# Commit characters are negotiated and used only for plain function-name
# insertions. Snippets already include parentheses, and an existing call
# suffix must not receive a duplicate opening parenthesis.
commit_caps = {"textDocument": {"completion": {"completionItem": {"commitCharactersSupport": True}}}}
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": commit_caps})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": source}
    })
    result = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 22, "character": 15}
    })
    item = next(item for item in result["result"]["items"] if item["label"] == "transform")
    assert item["commitCharacters"] == ["("], item
    assert item["textEdit"]["newText"] == "transform", item
    existing_call = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 24, "character": 13}
    })
    existing_item = next(item for item in existing_call["result"]["items"] if item["label"] == "transform")
    assert "commitCharacters" not in existing_item, existing_item
    spaced_call = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 26, "character": 13}
    })
    spaced_item = next(item for item in spaced_call["result"]["items"] if item["label"] == "transform")
    assert "commitCharacters" not in spaced_item, spaced_item
    client.finish(timeout=30)

commit_snippet_caps = {"textDocument": {"completion": {"completionItem": {
    "commitCharactersSupport": True, "snippetSupport": True
}}}}
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": commit_snippet_caps})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": source}
    })
    result = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 22, "character": 15}
    })
    item = next(item for item in result["result"]["items"] if item["label"] == "transform")
    assert item["insertTextFormat"] == 2, item
    assert item["textEdit"]["newText"] == "transform(${1:first}, ${2:second})$0", item
    assert "commitCharacters" not in item, item
    client.finish(timeout=30)


# InsertReplaceEdit is used only when requested and separates inserting before
# the cursor from replacing the complete identifier token.
insert_replace_caps = {"textDocument": {"completion": {"completionItem": {"insertReplaceSupport": True}}}}
with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": insert_replace_caps})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {
        "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": source}
    })
    result = client.request("textDocument/completion", {
        "textDocument": {"uri": uri}, "position": {"line": 22, "character": 13}
    })
    assert "result" in result, result
    item = next(item for item in result["result"]["items"] if item["label"] == "transform")
    assert item["textEdit"] == {
        "range": {
            "insert": {
                "start": {"line": 22, "character": 11},
                "end": {"line": 22, "character": 13},
            },
            "replace": {
                "start": {"line": 22, "character": 11},
                "end": {"line": 22, "character": 15},
            },
        },
        "newText": "transform",
    }, item
    client.finish(timeout=30)


unicode_source = "def λπ() -> i64:\n    return 1\ndef main() -> i64:\n    return λπ()\n"
for encoding, expected_end, cursor_character in (("utf-16", 13, 12), ("utf-8", 15, 13)):
    caps = {"capabilities": {}}
    if encoding == "utf-8":
        caps["capabilities"] = {"general": {"positionEncodings": ["utf-8", "utf-16"]}}
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps["capabilities"]})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": unicode_source}
        })
        result = client.request("textDocument/completion", {
            # The cursor separates two non-ASCII identifier characters; the
            # edit must still replace the complete Unicode token.
            "textDocument": {"uri": uri}, "position": {"line": 3, "character": cursor_character}
        })
        assert [item["label"] for item in result["result"]["items"]] == ["λπ"], result
        edit = result["result"]["items"][0]["textEdit"]
        assert edit["range"] == {
            "start": {"line": 3, "character": 11},
            "end": {"line": 3, "character": expected_end},
        }, (encoding, edit)
        client.finish(timeout=30)


def completion_kind_profile(value_set_marker, expected_kind, item_label="parameter", position=None):
    completion_capability = {"completionItemKind": {}}
    if value_set_marker is not None:
        completion_capability["completionItemKind"]["valueSet"] = value_set_marker
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": {
            "textDocument": {"completion": completion_capability},
        }})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "Elisa", "version": 1, "text": source}
        })
        result = client.request("textDocument/completion", {
            "textDocument": {"uri": uri},
            "position": position or {"line": 16, "character": 14},
        })
        assert "result" in result, result
        item = next(item for item in result["result"]["items"] if item["label"] == item_label)
        if expected_kind is None:
            assert "kind" not in item, item
        else:
            assert item.get("kind") == expected_kind, item
        client.finish(timeout=30)


completion_kind_profile(None, 6)  # valueSet omitted: all standard kinds are accepted
completion_kind_profile([1], None)  # a client that rejects Variable receives no kind field
completion_kind_profile([6], 6)
completion_kind_profile([], None)
completion_kind_profile([20], 20, "Fast", {"line": 18, "character": 14})

print("completion OK: cached declarations, locals, enum variants and ambiguity suppression; negotiated kinds, snippets, insert/replace ranges, safe commit characters and label details; snapshot-bound resolve, stale-item no-op and client-field preservation; and conservative context declines")
PY
