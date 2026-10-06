#!/usr/bin/env bash
# B03: manifest validation — legend, exact advertised capability set, method
# coverage, and the live initialize/initialized/shutdown/exit sequence.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import json
import os
import re
import sys

srv, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "test"))
from lsp_client import LspSession
with open(f"{root}/docs/semantic-token-schema.json", encoding="utf-8") as source:
    schema = json.load(source)
with open(f"{root}/docs/feature-manifest.json", encoding="utf-8") as source:
    manifest = json.load(source)
with open(f"{root}/docs/unsupported-constructs.json", encoding="utf-8") as source:
    unsupported_inventory = json.load(source)

unsupported_manifest = manifest.get("unsupported_constructs")
assert unsupported_manifest == {
    "inventory": "docs/unsupported-constructs.json",
    "test": "test/unsupported_constructs_test.sh",
    "compiler_rejected": "removed or invalid language spellings are probed against the compiler pinned by the build manifest and remain diagnostic passthrough cases",
    "lsp_provider_limits": "compiler-accepted constructs that a provider cannot identify exactly remain explicit no-match cases; these entries are not compiler or server regressions",
    "triage": "a changed compiler probe or compiler source fingerprint is frontend/toolchain drift; a provider golden failure with unchanged compiler provenance is an LSP regression",
}, unsupported_manifest
assert unsupported_inventory["schema_version"] == 1
assert unsupported_inventory["compiler_rejected"]
assert unsupported_inventory["lsp_provider_limits"]

standard_token_types = {
    "namespace", "type", "class", "enum", "interface", "struct",
    "typeParameter", "parameter", "variable", "property", "enumMember",
    "event", "function", "method", "macro", "keyword", "modifier",
    "comment", "string", "number", "regexp", "operator", "decorator",
}
assert schema["count"] == len(schema["legend"]) == 48
assert set(schema["standard_fallback"]) == set(schema["legend"]), (
    "every custom legend entry must have exactly one standard fallback"
)
assert set(schema["standard_fallback"].values()) <= standard_token_types, (
    "fallback table contains a non-standard semantic token type"
)
with open(f"{root}/src/semtokens.elisa", encoding="utf-8") as source:
    semtokens_source = source.read()


fallback_block = semtokens_source.split("def semtok_fallback_category", 1)[1].split("\n\n", 1)[0]
fallback_categories = {}
for first, last, category in re.findall(
    r"^\s*(\d+)(?:\.\.=(\d+))?\s*->\s*(-?\d+)", fallback_block, re.MULTILINE
):
    for index in range(int(first), int(last or first) + 1):
        fallback_categories[index] = int(category)
category_names = {
    int(category): name
    for category, name in re.findall(
        r'^\s*(\d+)\s*->\s*"([A-Za-z]+)"',
        semtokens_source.split("def semtok_standard_type_name", 1)[1].split("\n\n", 1)[0],
        re.MULTILINE,
    )
}
implementation_fallbacks = {
    schema["legend"][index]: category_names[fallback_categories[index]]
    for index in range(len(schema["legend"]))
}
assert implementation_fallbacks == schema["standard_fallback"], (
    "compiled fallback category table drifted from semantic-token schema"
)


# Exercise all four lifecycle messages in their valid order. The private stats
# request proves its dispatch path is reachable, and initialized must remain a
# response-free notification.
with LspSession(srv, startup_timeout=5, request_timeout=15) as client:
    initialize_response = client.initialize({"capabilities": {}})
    assert "result" in initialize_response, f"initialize result missing: {initialize_response}"
    stats_response = client.request("$/elisa/stats", {})
    assert "result" in stats_response, f"private stats dispatch failed: {stats_response}"
    assert client.finish() == 0
    messages = client.all_messages[:]
    shutdown_response = client.responses.get(("int", 3))

responses = {message["id"]: message for message in messages if "id" in message}
assert set(responses) == {1, 2, 3}, f"unexpected lifecycle responses: {messages}"
assert responses[1] == initialize_response
assert responses[2] == stats_response
assert shutdown_response == responses[3], f"shutdown response missing: {shutdown_response}"
stats = responses[2].get("result", {})
assert stats.keys() == {
    "storage_bytes", "storage_capacity", "live_bytes", "dead_storage_bytes", "documents",
    "documents_capacity", "open", "open_uri_bytes", "open_source_bytes",
    "derived_cache_bytes", "max_document_cache_bytes", "snapshots", "analysis_worker",
    "open_document_limit", "open_uri_bytes_limit", "configuration",
    "index_keys", "index_used", "index_capacity", "line_index", "analysis", "budgets", "timings"
}, f"private stats dispatch missing or malformed: {responses[2]}"
assert stats["storage_capacity"] >= stats["storage_bytes"], stats
assert stats["documents_capacity"] >= stats["documents"], stats
assert stats["storage_bytes"] == stats["live_bytes"] + stats["dead_storage_bytes"], stats
assert stats["snapshots"] == {
    "open": 0,
    "pending": 0,
    "ready": 0,
    "failed": 0,
}, f"snapshot counters should start at zero: {stats}"
assert stats["line_index"] == {
    "entries": 0,
    "cached_documents": 0,
    "stored_entries": 0,
    "capacity_entries": 0,
    "build_calls": 0,
    "fallback_build_calls": 0,
}, f"line-index counters should start at zero: {stats}"
assert stats["analysis"] == {
    "tokenize_calls": 0,
    "parse_calls": 0,
    "check_calls": 0,
    "adapter_query_calls": 0,
    "symbol_index_build_calls": 0,
    "occurrence_index_build_calls": 0,
}, f"analysis counters should start at zero: {stats}"
assert stats["timings"] == {
    "enabled": False,
    "decode_ms": 0,
    "edit_ms": 0,
    "line_index_ms": 0,
    "lex_ms": 0,
    "parse_ms": 0,
    "check_ms": 0,
    "index_ms": 0,
    "provider_ms": 0,
    "serialization_ms": 0,
    "queue_wait_ms": 0,
    "transport_ms": 0,
}, f"timing counters should start disabled and empty: {stats}"
assert stats["budgets"].keys() == {"transport", "documents", "analysis", "cache"}, stats
assert stats["budgets"]["transport"]["max_header_bytes"] > 0, stats
assert stats["budgets"]["transport"]["max_header_lines"] > 0, stats
assert stats["budgets"]["transport"]["max_body_bytes"] > 0, stats
assert stats["budgets"]["transport"]["write_timeout_ms"] > 0, stats
assert stats["budgets"]["documents"] == {
    "open": 0,
    "open_limit": stats["open_document_limit"],
    "open_uri_bytes": 0,
    "open_uri_bytes_limit": stats["open_uri_bytes_limit"],
    "open_source_bytes": 0,
    "open_source_bytes_limit": stats["budgets"]["documents"]["open_source_bytes_limit"],
}, stats
assert stats["budgets"]["analysis"]["mode"] == "one_shot_worker", stats
assert stats["budgets"]["analysis"]["queued"] == 0, stats
assert stats["budgets"]["analysis"]["queue_capacity"] == stats["open_document_limit"], stats
assert stats["budgets"]["analysis"]["in_flight"] == 0, stats
assert stats["budgets"]["analysis"]["timeout_ms"] > 0, stats
assert stats["budgets"]["analysis"]["worker_packet_limit_bytes"] > 0, stats
cache_budget = stats["budgets"]["cache"]
assert cache_budget["derived_bytes"] == 0, stats
assert cache_budget["retained_bytes"] == 0, stats
assert type(cache_budget["aggregate_limit_bytes"]) is int and cache_budget["aggregate_limit_bytes"] >= 1024, stats
assert cache_budget["eviction"] == "lru_snapshot", stats
assert cache_budget["evictions"] == 0, stats
assert responses[3].get("result", "missing") is None, f"shutdown result must be null: {responses[3]}"
assert not any(message.get("method") == "initialized" for message in messages), (
    "initialized is a client notification and must not receive a response"
)

# 1. The initialize legend must exactly match the shared schema, in wire-index
# order, so implementation, docs, and client indices cannot drift.
capabilities = responses[1]["result"]["capabilities"]
legend = capabilities["semanticTokensProvider"]["legend"]["tokenTypes"]
assert legend == schema["legend"], f"legend drift: server {len(legend)} vs schema {len(schema['legend'])}"
assert len(legend) == 48, f"legend count {len(legend)} != 48"
assert legend[13] == "elisa.fn.def" and legend[47] == "elisa.enum.variant", "wire indices moved"
assert manifest["legend"]["test"] == "test/capabilities_test.sh"
assert "complete custom tokenTypes" in manifest["legend"]["note"]
assert "standard-only subset" in manifest["legend"]["note"]

# 2. Implemented entries must be backed by existing test files. Check every
# explicit test reference as well, including capability/client-feature tests.
def validate_manifest_references(value, path="manifest"):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in ("test", "transport_test", "documentation") and isinstance(item, str):
                assert os.path.isfile(os.path.join(root, item)), f"{path}.{key} references missing {item}"
            else:
                validate_manifest_references(item, f"{path}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            validate_manifest_references(item, f"{path}[{index}]")


validate_manifest_references(manifest)
for method, spec in manifest["methods"].items():
    if spec.get("implemented"):
        assert spec.get("test"), f"implemented method lacks test coverage: {method}"

# Lifecycle documentation must agree with the dispatch and focused protocol
# regression suite. In particular, initialized is a real transition, not a no-op.
for method, kind in (
    ("initialize", "client-to-server request"),
    ("initialized", "client-to-server notification"),
    ("shutdown", "client-to-server request"),
    ("exit", "client-to-server notification"),
):
    spec = manifest["methods"].get(method)
    assert spec and spec.get("implemented") is True, f"lifecycle method missing or unimplemented: {method}"
    assert spec.get("test") == "test/protocol_test.sh", f"lifecycle coverage drift for {method}: {spec}"
    assert spec.get("kind") == kind, f"lifecycle message kind drift for {method}: {spec}"
assert manifest["lifecycle"]["operational_after"] == "initialize response (Running)"
assert manifest["lifecycle"]["initialized_notification"].startswith("first notification transitions Running to Initialized once")
assert manifest["lifecycle"]["clean_eof"].startswith("exit 0 between complete frames")

# 3. Compare every initialize capability name with the manifest's required / optional
# set. Then derive the exact standard feature-method set from those capabilities.
cap_manifest = manifest["capabilities_advertised"]
actual_cap_names = set(capabilities)
required = set(cap_manifest["required"])
optional = set(cap_manifest["optional"])
assert required <= actual_cap_names, f"required capabilities missing: {required - actual_cap_names}"
assert actual_cap_names <= required | optional, f"unmanifested capabilities: {actual_cap_names - required - optional}"

sync = capabilities.get("textDocumentSync", {})
advertised_methods = set()
if sync.get("openClose") is True:
    advertised_methods.update(("textDocument/didOpen", "textDocument/didClose"))
if sync.get("change"):
    advertised_methods.add("textDocument/didChange")
semantic = capabilities.get("semanticTokensProvider", {})
if semantic.get("full"):
    advertised_methods.add("textDocument/semanticTokens/full")
if semantic.get("range"):
    advertised_methods.add("textDocument/semanticTokens/range")
if capabilities.get("hoverProvider") is True:
    advertised_methods.add("textDocument/hover")
if isinstance(capabilities.get("completionProvider"), dict):
    advertised_methods.add("textDocument/completion")
    if capabilities["completionProvider"].get("resolveProvider") is True:
        advertised_methods.add("completionItem/resolve")
if capabilities.get("definitionProvider") is True:
    advertised_methods.add("textDocument/definition")
if capabilities.get("referencesProvider") is True:
    advertised_methods.add("textDocument/references")
rename = capabilities.get("renameProvider", {})
if isinstance(rename, dict) and rename.get("prepareProvider") is True:
    advertised_methods.update(("textDocument/prepareRename", "textDocument/rename"))
if capabilities.get("documentHighlightProvider") is True:
    advertised_methods.add("textDocument/documentHighlight")
if capabilities.get("documentSymbolProvider") is True:
    advertised_methods.add("textDocument/documentSymbol")
if capabilities.get("foldingRangeProvider") is True:
    advertised_methods.add("textDocument/foldingRange")
if capabilities.get("selectionRangeProvider") is True:
    advertised_methods.add("textDocument/selectionRange")
if isinstance(capabilities.get("signatureHelpProvider"), dict):
    advertised_methods.add("textDocument/signatureHelp")

manifest_methods = set(cap_manifest["methods"])
conditional_methods = set(cap_manifest.get("conditional_methods", []))
assert advertised_methods == manifest_methods, (
    f"default-profile method drift: server={sorted(advertised_methods)}, "
    f"manifest={sorted(manifest_methods)}"
)
for method in advertised_methods | conditional_methods:
    spec = manifest["methods"].get(method)
    assert spec and spec.get("implemented") is True and spec.get("test"), (
        f"capability advertises method without tested implementation: {method}"
    )

assert sync == {"openClose": True, "change": 2}, f"sync capability drift: {sync}"
assert semantic.get("full") is True and semantic.get("range") is True
assert capabilities.get("hoverProvider") is True
assert capabilities.get("completionProvider") == {"resolveProvider": True}
assert capabilities.get("definitionProvider") is True
assert capabilities.get("referencesProvider") is True
assert "renameProvider" not in capabilities
assert capabilities.get("documentHighlightProvider") is True
assert capabilities.get("signatureHelpProvider", {}).get("triggerCharacters") == ["(", ","]
print(
    f"manifest OK: {len(legend)} legend entries, "
    f"{len(advertised_methods)} advertised feature methods, "
    f"{sum(1 for item in manifest['methods'].values() if item.get('implemented'))} tested implementations"
)
PY
