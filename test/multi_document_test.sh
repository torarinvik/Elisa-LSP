#!/usr/bin/env bash
# Regression coverage for the session document store. The LSP must keep each
# URI's decoded snapshot independent: a request for B must never tokenize A,
# an edit to A must not change B, and closing A must invalidate only A.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json
import subprocess
import sys


def frame(message):
    body = json.dumps(message, separators=(",", ":")).encode()
    return frame_bytes(body)


def frame_bytes(body):
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


def open_document(uri, text, version=1):
    return {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {"textDocument": {
            "uri": uri, "languageId": "elisa", "version": version, "text": text,
        }},
    }


def change_document(uri, text, version):
    return {
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
            "textDocument": {"uri": uri, "version": version},
            "contentChanges": [{"text": text}],
        },
    }


def tokens_request(request_id, uri):
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "textDocument/semanticTokens/full",
        "params": {"textDocument": {"uri": uri}},
    }


def tokens_request_with_alternate_json_escaping(request_id, uri):
    # JSON permits equivalent escaping forms. This asks for A with every URI
    # slash escaped, so the cache must compare decoded URI bytes, not the raw
    # representation inside the request message.
    uri_literal = json.dumps(uri).replace("/", "\\/")
    body = (
        '{"jsonrpc":"2.0","id":%d,"method":"textDocument/semanticTokens/full",'
        '"params":{"textDocument":{"uri":%s}}}'
    ) % (request_id, uri_literal)
    return frame_bytes(body.encode())


def close_document(uri):
    return {
        "jsonrpc": "2.0",
        "method": "textDocument/didClose",
        "params": {"textDocument": {"uri": uri}},
    }


uri_a = "file:///multi-a.elisa"
uri_b = "file:///multi-b.elisa"
text_a = "def one() -> void:\n    x: i64 = 1\n"
text_b = "def two() -> void:\n    y: i64 = 2\n"
edited_a = "def broken() -> void:\n    z: bool = 3\n"

messages = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    open_document(uri_a, text_a),
    open_document(uri_b, text_b),
    tokens_request_with_alternate_json_escaping(2, uri_a),
    tokens_request(3, uri_b),
    change_document(uri_a, edited_a, 2),
    tokens_request(4, uri_b),
    tokens_request(6, uri_a),
    close_document(uri_a),
    tokens_request(5, uri_a),
    {"jsonrpc": "2.0", "id": 7, "method": "shutdown"},
    {"jsonrpc": "2.0", "method": "exit"},
]

completed = subprocess.run(
    [sys.argv[1]],
    input=b"".join(message if isinstance(message, bytes) else frame(message) for message in messages),
    capture_output=True, timeout=45,
)
if completed.returncode != 0:
    raise SystemExit(f"server exited {completed.returncode}: {completed.stderr.decode(errors='replace')}")

output = completed.stdout
position = 0
responses = {}
while position < len(output):
    separator = output.find(b"\r\n\r\n", position)
    if separator < 0:
        raise SystemExit("truncated LSP response header")
    length = int(output[position:separator].split(b":", 1)[1].strip())
    start = separator + 4
    payload = output[start:start + length]
    if len(payload) != length:
        raise SystemExit("truncated LSP response body")
    message = json.loads(payload)
    if "id" in message:
        responses[message["id"]] = message.get("result")
    position = start + length

if not responses.get(2, {}).get("data") or not responses.get(3, {}).get("data"):
    raise SystemExit("both opened documents must return semantic tokens")
if responses[4] != responses[3]:
    raise SystemExit("editing document A changed document B's token result")
if not responses.get(6, {}).get("data") or responses[6] == responses[2]:
    raise SystemExit("editing document A did not refresh A's token result")
if responses[5] != {"data": []}:
    raise SystemExit("closed document A still returned stale semantic tokens")
print("multi-document OK: isolated snapshots, edits, and close invalidation")
PY
