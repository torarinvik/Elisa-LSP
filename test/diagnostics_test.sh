#!/usr/bin/env bash
# didOpen diagnostics (valid JSON fixtures via python json.dumps — B02):
#   1. a clean document -> empty publishDiagnostics notification.
#   2. a document with an error -> publishDiagnostics with >=1 diagnostic (no crash).
#   3. a dotted module path in type position -> one precise `::` namespace diagnostic.
#
# Case 2 used to abort the server with an arena "assert failed" (fixed in Elisa-core
# 742c2b4b — see the comment atop src/diagnostics.elisa).
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import re
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]


def diagnostics(uri, text):
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": {}})
        assert "result" in initialized, initialized
        client.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "Elisa",
                "version": 1,
                "text": text,
            }
        })
        notification = client.wait_notification(
            "textDocument/publishDiagnostics",
            predicate=lambda message: message.get("params", {}).get("uri") == uri,
            timeout=30,
        )
        params = notification["params"]
        assert params["uri"] == uri, f"diagnostic notification matched wrong document: {notification}"
        result = params["diagnostics"]
        stderr = client.stderr_text()
        client.finish(timeout=30)
        return result, stderr


# 1. A clean document produces an empty diagnostic list.
clean, clean_stderr = diagnostics(
    "file:///t.elisa",
    "def main() -> int:\n    return 0\n",
)
assert clean == [], f"expected empty diagnostics for clean document: {clean}"
assert "assert failed" not in clean_stderr.lower(), clean_stderr

# 2. A semantic error produces at least one error-severity diagnostic without
# aborting the compiler/server process.
semantic, semantic_stderr = diagnostics(
    "file:///bad.elisa",
    "def main() -> int:\n    return nope_undefined\n",
)
assert semantic, "expected a non-empty diagnostic list for the semantic error"
assert any(item.get("severity") == 1 for item in semantic), semantic
assert all(item.get("source") == "elisa" for item in semantic), semantic
assert all(isinstance(item.get("code"), str) and item["code"].startswith("ELISA-") for item in semantic), semantic
assert "assert failed" not in semantic_stderr.lower(), semantic_stderr

# 3. A namespace path in type position uses `::`, not the value-member `.`.
# The current frontend classifies this type-path walk as NamespaceUsedAsValue;
# pattern-style paths use ModulePathDotSeparator. Keep the compiler's actionable
# spelling correction and the diagnostic range anchored at the namespace token.
namespace_type, namespace_stderr = diagnostics(
    "file:///namespace-dot-type.elisa",
    "module math:\n"
    "    struct Box:\n"
    "        value: int\n"
    "\n"
    "def run(box: math.Box) -> int:\n"
    "    return box.value\n",
)
assert len(namespace_type) == 1, namespace_type
namespace_diag = namespace_type[0]
assert namespace_diag.get("severity") == 1, namespace_diag
assert namespace_diag.get("source") == "elisa", namespace_diag
assert namespace_diag.get("code") == "ELISA-NamespaceUsedAsValue", namespace_diag
assert namespace_diag.get("message") == (
    '"math" is a namespace; write math::Box (`.` accesses value members, '
    "`::` accesses namespaces)"
), namespace_diag
assert namespace_diag.get("range") == {
    "start": {"line": 4, "character": 13},
    "end": {"line": 4, "character": 17},
}, namespace_diag
assert "assert failed" not in namespace_stderr.lower(), namespace_stderr

# 4. Parser errors (Ast::File.errors folded into Semantic::check) must be
# surfaced as error diagnostics, rather than only semantic findings.
syntax, syntax_stderr = diagnostics(
    "file:///syn.elisa",
    "def main( -> int:\n    return 0\n",
)
assert syntax, "expected a non-empty diagnostic list for the syntax error"
assert any(item.get("severity") == 1 for item in syntax), syntax
assert all(item.get("source") == "elisa" for item in syntax), syntax
messages = "\n".join(item.get("message", "") for item in syntax)
assert re.search(
    r"expected a token|unexpected token|expected a declaration|expected an expression",
    messages,
), f"expected a parser diagnostic message: {messages}"
assert "assert failed" not in syntax_stderr.lower(), syntax_stderr

# 5. Truncation is reported only after 200 distinct findings have been
# serialized; duplicate filtering must not be counted as omitted output.
many_source = "\n".join(
    f"def generated_{index}() -> int:\n    return missing_{index}\n"
    for index in range(205)
)
many, many_stderr = diagnostics("file:///many-errors.elisa", many_source)
assert len(many) == 201, f"expected 200 findings plus one truncation note, got {len(many)}"
assert many[-1].get("message") == "additional distinct diagnostics omitted (showing first 200)", many[-1]
assert many[-1].get("source") == "elisa-lsp", many[-1]
assert many[-1].get("code") == "ELISA-LSP-DiagnosticsTruncated", many[-1]
findings = many[:-1]
assert all(item.get("source") == "elisa" for item in findings), findings[-1]
keys = [
    (item.get("range"), item.get("severity"), item.get("message"))
    for item in findings
]
assert len(keys) == len(set(map(repr, keys))), "duplicate diagnostics survived serialization"
assert "assert failed" not in many_stderr.lower(), many_stderr

print("diagnostics OK: clean, semantic error, namespace type spelling/range, syntax error, bounded distinct results; URI-matched notifications")
PY
