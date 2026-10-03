#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession, frame_bytes

srv = sys.argv[1]
uri = "file:///rename.elisa"
source = (
    "def rename_target(π: i64) -> i64:\n"
    "    local_value: i64 = π\n"
    "    return local_value\n"
    "# blocked_name appears only in a comment\n"
)
lines = source.splitlines()


def units(text, encoding):
    if encoding == "utf-8":
        return len(text.encode("utf-8"))
    return len(text.encode("utf-16-le")) // 2


def position(line_no, needle, encoding, occurrence=0, inside=0):
    start = -1
    cursor = 0
    for _ in range(occurrence + 1):
        start = lines[line_no].index(needle, cursor)
        cursor = start + len(needle)
    return {"line": line_no, "character": units(lines[line_no][:start], encoding) + inside}


def range_for(line_no, needle, encoding, occurrence=0):
    start = position(line_no, needle, encoding, occurrence)
    return {
        "start": start,
        "end": {"line": line_no, "character": start["character"] + units(needle, encoding)},
    }


def to_py_index(line, character, encoding):
    measured = 0
    for i, char in enumerate(line):
        if measured == character:
            return i
        measured += units(char, encoding)
        if measured > character:
            raise AssertionError((line, character, encoding, "position splits a code point"))
    assert measured == character, (line, character, encoding, measured)
    return len(line)


def apply_edits(text, edits, encoding):
    line_starts = []
    offset = 0
    for line in text.splitlines(keepends=True):
        line_starts.append(offset)
        offset += len(line)

    def absolute(pos):
        line = text.splitlines()[pos["line"]]
        return line_starts[pos["line"]] + to_py_index(line, pos["character"], encoding)

    result = text
    for edit in sorted(edits, key=lambda item: absolute(item["range"]["start"]), reverse=True):
        start = absolute(edit["range"]["start"])
        end = absolute(edit["range"]["end"])
        result = result[:start] + edit["newText"] + result[end:]
    return result


def check(encoding):
    caps = {"workspace": {"workspaceEdit": {"documentChanges": True}}}
    if encoding == "utf-8":
        caps["general"] = {"positionEncodings": ["utf-8"]}
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": caps})
        assert "result" in initialized, initialized
        server_caps = initialized["result"]["capabilities"]
        assert server_caps.get("renameProvider") == {"prepareProvider": True}, server_caps
        client.notify("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "Elisa", "version": 7, "text": source}
        })

        def prepare(line, name, occurrence=0):
            return client.request("textDocument/prepareRename", {
                "textDocument": {"uri": uri},
                "position": position(line, name, encoding, occurrence),
            })

        parameter_prepare = prepare(0, "π")
        assert parameter_prepare.get("result") == {
            "range": range_for(0, "π", encoding),
            "placeholder": "π",
        }, parameter_prepare
        local_prepare = prepare(1, "local_value")
        assert local_prepare.get("result") == {
            "range": range_for(1, "local_value", encoding),
            "placeholder": "local_value",
        }, local_prepare

        # The exact binding follows both its declaration and all uses. The
        # returned edit is versioned and applying it changes only that binding.
        parameter = client.request("textDocument/rename", {
            "textDocument": {"uri": uri},
            "position": position(1, "π", encoding),
            "newName": "renamed_π",
        })
        p_edit = parameter.get("result", {}).get("documentChanges", [None])[0]
        assert p_edit and p_edit["textDocument"] == {"uri": uri, "version": 7}, parameter
        assert [edit["range"] for edit in p_edit["edits"]] == [
            range_for(0, "π", encoding), range_for(1, "π", encoding)
        ], parameter
        assert all(edit["newText"] == "renamed_π" for edit in p_edit["edits"]), parameter
        assert apply_edits(source, p_edit["edits"], encoding) == source.replace("π", "renamed_π")

        local = client.request("textDocument/rename", {
            "textDocument": {"uri": uri},
            "position": position(2, "local_value", encoding),
            "newName": "fresh_local",
        })
        l_edit = local.get("result", {}).get("documentChanges", [None])[0]
        assert l_edit and l_edit["textDocument"] == {"uri": uri, "version": 7}, local
        assert [edit["range"] for edit in l_edit["edits"]] == [
            range_for(1, "local_value", encoding), range_for(2, "local_value", encoding)
        ], local
        assert apply_edits(source, l_edit["edits"], encoding) == source.replace("local_value", "fresh_local")

        # No candidate guessing: a file-scope function and an unresolved name
        # cannot be prepared/renamed as local BindingIds.
        assert prepare(0, "rename_target").get("result", "missing") is None
        unresolved = client.request("textDocument/prepareRename", {
            "textDocument": {"uri": uri}, "position": position(1, "i64", encoding)
        })
        assert unresolved.get("result", "missing") is None, unresolved

        for new_name in ("π", "blocked_name", "return", "can", "when", "move", "bad name", "x.y", ""):
            rejected = client.request("textDocument/rename", {
                "textDocument": {"uri": uri},
                "position": position(1, "local_value", encoding),
                "newName": new_name,
            })
            assert rejected.get("result", "missing") is None, (new_name, rejected)

        malformed = (b'{"jsonrpc":"2.0","id":900,"method":"textDocument/rename",'
                     b'"params":{"textDocument":{"uri":"file:///rename.elisa"},'
                     b'"position":{"line":1,"character":4},"newName":7}}')
        client.send(frame_bytes(malformed))
        invalid = client.wait_response(900, timeout=15)
        assert invalid.get("error", {}).get("code") == -32602, invalid
        client.finish(timeout=30)


def check_minimal_client():
    with LspSession(srv, request_timeout=30, teardown_timeout=5) as client:
        initialized = client.initialize({"capabilities": {}})
        assert "result" in initialized, initialized
        server_caps = initialized["result"]["capabilities"]
        assert "renameProvider" not in server_caps, server_caps
        client.notify("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "Elisa", "version": 7, "text": source}
        })
        prepare = client.request("textDocument/prepareRename", {
            "textDocument": {"uri": uri}, "position": position(0, "π", "utf-16")
        })
        rename = client.request("textDocument/rename", {
            "textDocument": {"uri": uri}, "position": position(0, "π", "utf-16"),
            "newName": "renamed_π",
        })
        assert prepare.get("result", "missing") is None, prepare
        assert rename.get("result", "missing") is None, rename
        client.finish(timeout=30)


check_minimal_client()
check("utf-16")
check("utf-8")
print("rename OK: capability-gated versioned local/parameter BindingIds, Unicode names and ranges, non-overlapping edits, conservative collision/keyword rejection")
PY
