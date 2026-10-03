#!/usr/bin/env bash
# W01 foundation: initialize-time workspace roots have deterministic,
# boundary-aware ownership, including trailing-slash and nested roots.
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


def inspect_workspace(client, uri=None):
    params = {}
    if uri is not None:
        params["textDocument"] = {"uri": uri}
    response = client.request("$/elisa/workspace", params, timeout=15)
    assert "result" in response, response
    return response["result"]


roots = [
    {"name": "nested", "uri": "file:///work/project/nested/"},
    {"name": "project", "uri": "file:///work/project/"},
]
with LspSession(srv, startup_timeout=5, request_timeout=15, teardown_timeout=5) as client:
    initialized = client.initialize({"capabilities": {}, "workspaceFolders": roots})
    assert "result" in initialized, initialized

    all_roots = inspect_workspace(client)
    assert all_roots == {
        "folders": [root["uri"] for root in roots],
        "count": 2,
    }, all_roots

    nested_file = inspect_workspace(client, "file:///work/project/nested/src/main.elisa")
    project_file = inspect_workspace(client, "file:///work/project/src/main.elisa")
    nested_directory = inspect_workspace(client, "file:///work/project/nested/")
    project_directory = inspect_workspace(client, "file:///work/project/")
    sibling_prefix = inspect_workspace(client, "file:///work/project-other/main.elisa")
    outside = inspect_workspace(client, "file:///other/main.elisa")
    assert nested_file["documentRoot"] == 0, nested_file
    assert project_file["documentRoot"] == 1, project_file
    assert nested_directory["documentRoot"] == 0, nested_directory
    assert project_directory["documentRoot"] == 1, project_directory
    assert sibling_prefix["documentRoot"] == -1, sibling_prefix
    assert outside["documentRoot"] == -1, outside
    assert client.finish(timeout=15) == 0

# Legacy rootUri is used only when workspaceFolders has no entries. A root
# ending in slash must still own child documents under the same URI boundary.
with LspSession(srv, startup_timeout=5, request_timeout=15, teardown_timeout=5) as client:
    initialized = client.initialize({
        "capabilities": {},
        "workspaceFolders": [],
        "rootUri": "file:///legacy/",
    })
    assert "result" in initialized, initialized
    legacy = inspect_workspace(client, "file:///legacy/src/main.elisa")
    assert legacy == {"folders": ["file:///legacy/"], "count": 1, "documentRoot": 0}, legacy
    assert client.finish(timeout=15) == 0

print("workspace roots OK: nested precedence, trailing-slash containment, boundary isolation, and rootUri fallback")
PY
