#!/usr/bin/env bash
# P01/P02: envelope validation + lifecycle state machine.
# - Every valid request gets exactly one response; notifications get none.
# - Unknown methods with id -> MethodNotFound; without id -> silence.
# - Pre-initialize non-init requests -> ServerNotInitialized.
# - Duplicate initialize -> InvalidRequest; post-shutdown requests ->
#   InvalidRequest; exit-notification status follows whether shutdown occurred.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def fb(b):
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def run(msgs, timeout=15):
    payload = b"".join(msgs) if isinstance(msgs, list) else msgs
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=timeout)
    return p

def frames(buf):
    out = []
    pos = 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        assert sep >= 0, "truncated header"
        ln = int(buf[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        out.append(json.loads(buf[start:start+ln]))
        pos = start+ln
    return out

# 1. Unknown request after init -> exactly one MethodNotFound; unknown notification -> silence.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}})
m += frame({"jsonrpc":"2.0","method":"initialized","params":{}})
m += frame({"jsonrpc":"2.0","id":2,"method":"nosuch/method","params":{}})
m += frame({"jsonrpc":"2.0","method":"nosuch/notify","params":{}})
m += frame({"jsonrpc":"2.0","id":3,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 0, f"orderly exit must be 0, got {p.returncode}"
msgs = frames(p.stdout)
by_id = {x["id"]: x for x in msgs if "id" in x}
assert by_id[2].get("error",{}).get("code") == -32601, f"unknown request must be MethodNotFound: {by_id.get(2)}"
assert 3 in by_id and "result" in by_id[3], "shutdown must respond"
assert not any(x.get("method")=="nosuch/notify" for x in msgs), "notifications must not produce responses"
assert len([x for x in msgs if x.get("id")==2]) == 1, "exactly-once for unknown request"

# 2. Pre-initialize tokens request -> ServerNotInitialized, no crash.
m = frame({"jsonrpc":"2.0","id":1,"method":"textDocument/semanticTokens/full",
           "params":{"textDocument":{"uri":"file:///x.elisa"}}})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 1, f"exit-without-shutdown must be 1, got {p.returncode}"
msgs = frames(p.stdout)
assert msgs[0].get("error",{}).get("code") == -32002, f"pre-init must be ServerNotInitialized: {msgs}"

# 3. Duplicate initialize -> InvalidRequest, second response still exactly-once.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}})
m += frame({"jsonrpc":"2.0","method":"initialized","params":{}})
m += frame({"jsonrpc":"2.0","method":"initialized","params":{}})
m += frame({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{}}})
m += frame({"jsonrpc":"2.0","id":3,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 0
by_id = {x["id"]: x for x in frames(p.stdout) if "id" in x}
assert "result" in by_id[1] and by_id[2].get("error",{}).get("code") == -32600, f"duplicate init: {by_id}"

# 4. Post-shutdown requests (including a second shutdown) are InvalidRequest;
#    non-exit notifications are dropped without doing document work.
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}})
m += frame({"jsonrpc":"2.0","id":2,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","id":3,"method":"textDocument/hover",
            "params":{"textDocument":{"uri":"file:///x.elisa"},"position":{"line":0,"character":0}}})
m += frame({"jsonrpc":"2.0","id":4,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","id":5,"method":"$/elisa/stats","params":[]})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":"file:///after-shutdown.elisa","languageId":"Elisa","version":1,"text":"invalid syntax"}}})
m += frame({"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":3}})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 0
shutdown_msgs = frames(p.stdout)
by_id = {x["id"]: x for x in shutdown_msgs if "id" in x}
assert by_id[3].get("error",{}).get("code") == -32600, f"post-shutdown must be InvalidRequest: {by_id.get(3)}"
assert by_id[4].get("error",{}).get("code") == -32600, f"duplicate shutdown must be InvalidRequest: {by_id.get(4)}"
assert by_id[5].get("error",{}).get("code") == -32600, f"private requests must also stop after shutdown: {by_id.get(5)}"
assert not any(x.get("method") == "textDocument/publishDiagnostics" for x in shutdown_msgs), \
    f"post-shutdown document notifications must not run: {shutdown_msgs}"

# 5. String vs numeric IDs are distinct keys (typed IDs).
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}})
m += frame({"jsonrpc":"2.0","id":"1","method":"nosuch/method","params":{}})
m += frame({"jsonrpc":"2.0","id":1,"method":"nosuch/other","params":{}})
m += frame({"jsonrpc":"2.0","id":9,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
by_id = {(type(x["id"]).__name__, x["id"]): x for x in frames(p.stdout) if "id" in x}
assert ("int",1) in by_id and ("str","1") in by_id, f"typed IDs not distinguished: {list(by_id)}"

# 6. Envelope validation happens before dispatch. Escapes are decoded, invalid
# IDs and params are rejected, and inbound server responses are ignored.
bad_envelopes = [
    b'{"jsonrpc":"9.9","id":1,"method":"$/elisa/stats"}',
    b'{"id":2,"method":"$/elisa/stats"}',
    b'{"jsonrpc":"2.0","id":null,"method":"$/elisa/stats"}',
    b'{"jsonrpc":"2.0","id":1.5,"method":"$/elisa/stats"}',
    b'{"jsonrpc":"2.0","id":3,"method":7}',
    b'{"jsonrpc":"2.0","id":4}',
    b'[]',
]
prefix = frame({"jsonrpc":"2.0","id":20,"method":"initialize","params":{"capabilities":{}}})
payload = prefix + b"".join(fb(m) for m in bad_envelopes)
payload += fb(b'{"jsonrpc":"2.0","id":5,"method":"$/elisa/stats","params":null}')
payload += frame({"jsonrpc":"2.0","id":16,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.elisa"}}})
payload += frame({"jsonrpc":"2.0","id":17,"method":"textDocument/semanticTokens/range",
                  "params":{"textDocument":{"uri":"file:///x.elisa"},
                            "range":{"start":{"line":2,"character":0},"end":{"line":1,"character":0}}}})
payload += frame({"jsonrpc":"2.0","id":18,"method":"textDocument/selectionRange",
                  "params":{"textDocument":{"uri":"file:///x.elisa"},"positions":[{"line":-1,"character":0}]}})
# A method key, method value, and protocol version may all use equivalent
# escapes; the response must echo a JSON string ID with its embedded quote.
payload += fb(b'{"jsonrpc":"2\\u002e0","id":"quoted\\\"id","metho\\u0064":"$/elisa\\/stats","params":{}}')
# Request-only methods without IDs are notifications and must never generate a
# response or change lifecycle state. Response-shaped input has no pending peer.
payload += fb(b'{"jsonrpc":"2.0","method":"textDocument/hover","params":{}}')
payload += fb(b'{"jsonrpc":"2.0","id":90,"result":null}')
payload += fb(b'{"jsonrpc":"2.0","id":91,"error":{"code":-1,"message":"x"}}')
payload += fb(b'{"jsonrpc":"2.0","id":92,"result":null,"error":{"code":-1,"message":"malformed response"}}')
# Duplicate critical members (including escaped-equivalent keys) are ambiguous.
payload += fb(b'{"jsonrpc":"2.0","id":8,"method":"$/elisa/stats","metho\\u0064":"shutdown"}')
payload += fb(b'{"jsonrpc":"2.0","id":8,"i\\u0064":9,"method":"$/elisa/stats"}')
payload += fb(b'{"jsonrpc":"2.0","jsonrpc":"2.0","id":94,"method":"$/elisa/stats"}')
payload += fb(b'{"jsonrpc":"2.0","id":93,"method":"$/elisa/stats","params":{},"params":{}}')
payload += frame({"jsonrpc":"2.0","id":99,"method":"shutdown"})
payload += frame({"jsonrpc":"2.0","method":"exit"})
p = run(payload)
assert p.returncode == 0, f"envelope matrix exit={p.returncode}, stderr={p.stderr!r}"
env_msgs = frames(p.stdout)
responses = [m for m in env_msgs if "id" in m]
errors = {m["id"]: m.get("error", {}).get("code") for m in responses if m.get("id") is not None and "error" in m}
assert errors.get(1) == -32600 and errors.get(2) == -32600, f"version and missing-version invalid: {env_msgs}"
assert errors.get(3) == -32600 and errors.get(4) == -32600, f"malformed IDs invalid: {env_msgs}"
assert errors.get(5) == -32602, f"scalar params must be InvalidParams: {env_msgs}"
assert errors.get(16) == -32602 and errors.get(17) == -32602 and errors.get(18) == -32602, \
    f"malformed nested method params must be InvalidParams: {env_msgs}"
assert any(m.get("id") == "quoted\"id" and "result" in m for m in env_msgs), f"escaped envelope or string ID failed: {env_msgs}"
assert any(m.get("id") == 8 and m.get("error", {}).get("code") == -32600 for m in env_msgs), f"duplicate member invalid: {env_msgs}"
assert errors.get(94) == -32600 and errors.get(93) == -32600, \
    f"duplicate jsonrpc and params members must be rejected: {env_msgs}"
null_invalids = [m for m in responses if m.get("id") is None and m.get("error", {}).get("code") == -32600]
assert len(null_invalids) == 4, f"null, fractional, array, and duplicate IDs must each get one InvalidRequest: {null_invalids}"
assert not any(m.get("id") in (90, 91, 92) for m in env_msgs), f"unmatched response-shaped input must be ignored: {env_msgs}"
assert len([m for m in env_msgs if m.get("id") == 8]) == 1, f"duplicate ID member must not be echoed ambiguously: {env_msgs}"

# Request-only methods without IDs do not run a response-producing handler or
# mutate lifecycle state. A later valid initialize and shutdown still work.
m = fb(b'{"jsonrpc":"2.0","method":"initialize","params":{"capabilities":{}}}')
m += frame({"jsonrpc":"2.0","id":21,"method":"initialize","params":{"capabilities":{}}})
m += fb(b'{"jsonrpc":"2.0","method":"shutdown"}')
m += frame({"jsonrpc":"2.0","id":22,"method":"textDocument/hover",
            "params":{"textDocument":{"uri":"file:///x.elisa"},"position":{"line":0,"character":0}}})
m += frame({"jsonrpc":"2.0","id":23,"method":"shutdown"})
m += fb(b'{"jsonrpc":"2.0","method":"exit"}')
p = run(m)
assert p.returncode == 0, f"request notifications changed lifecycle: {p.returncode}, {p.stderr!r}"
transition_msgs = frames(p.stdout)
assert any(m.get("id") == 21 and "result" in m for m in transition_msgs), transition_msgs
assert any(m.get("id") == 22 and "result" in m for m in transition_msgs), transition_msgs
assert any(m.get("id") == 23 and "result" in m for m in transition_msgs), transition_msgs
assert len(transition_msgs) == 3, f"request notifications must not get replies: {transition_msgs}"

# A rejected initialize does not enter the running state, and an invalid
# shutdown request does not prevent subsequent normal work.
m = frame({"jsonrpc":"2.0","id":30,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","id":31,"method":"initialize","params":{"capabilities":[]}})
m += fb(b'{"jsonrpc":"2.0","id":29,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8"],"positionEncodings":["utf-16"]}}}}')
m += frame({"jsonrpc":"2.0","id":36,"method":"initialize",
            "params":{"capabilities":{},"workspaceFolders":[{"uri":"file:///missing-name"}]}})
m += fb(b'{"jsonrpc":"2.0","id":37,"method":"initialize","params":{"capabilities":{},"workspaceFolders":[{"name":"one","uri":"file:///one","u\\u0072i":"file:///two"}]}}')
m += frame({"jsonrpc":"2.0","id":38,"method":"initialize",
            "params":{"capabilities":{},"workspaceFolders":[17]}})
m += frame({"jsonrpc":"2.0","id":39,"method":"initialize",
            "params":{"capabilities":{},"workspaceFolders":"file:///root"}})
m += frame({"jsonrpc":"2.0","id":40,"method":"initialize",
            "params":{"capabilities":{},"rootUri":17}})
m += frame({"jsonrpc":"2.0","id":32,"method":"initialize",
            "params":{"capabilities":{},"workspaceFolders":[{"name":"Project","uri":"file:///project"}]}})
m += frame({"jsonrpc":"2.0","id":33,"method":"shutdown","params":[]})
m += frame({"jsonrpc":"2.0","id":34,"method":"textDocument/hover",
            "params":{"textDocument":{"uri":"file:///x.elisa"},"position":{"line":0,"character":0}}})
m += frame({"jsonrpc":"2.0","id":35,"method":"shutdown"})
m += fb(b'{"jsonrpc":"2.0","method":"exit"}')
p = run(m)
assert p.returncode == 0, f"invalid lifecycle params changed state: {p.returncode}, {p.stderr!r}"
lifecycle_msgs = frames(p.stdout)
lifecycle_by_id = {x.get("id"): x for x in lifecycle_msgs if "id" in x}
assert lifecycle_by_id[30].get("error",{}).get("code") == -32602, lifecycle_msgs
assert lifecycle_by_id[31].get("error",{}).get("code") == -32602, lifecycle_msgs
assert lifecycle_by_id[29].get("error",{}).get("code") == -32602, lifecycle_msgs
for invalid_workspace_id in (36, 37, 38, 39, 40):
    assert lifecycle_by_id[invalid_workspace_id].get("error",{}).get("code") == -32602, \
        f"malformed workspace root {invalid_workspace_id} must be InvalidParams: {lifecycle_msgs}"
assert "result" in lifecycle_by_id[32], f"valid initialize after rejection: {lifecycle_msgs}"
assert lifecycle_by_id[33].get("error",{}).get("code") == -32602, lifecycle_msgs
assert "result" in lifecycle_by_id[34] and "result" in lifecycle_by_id[35], lifecycle_msgs

# Pre-initialize behavior applies to every request, including private controls;
# notifications are dropped (except exit), and an ignored cancellation cannot
# poison a later request with the same ID. An invalid shutdown attempt must not
# advance the lifecycle. initialized is accepted once and remains response-free.
m = frame({"jsonrpc":"2.0","id":41,"method":"textDocument/hover",
           "params":{"textDocument":{"uri":"file:///x.elisa"},"position":{"line":0,"character":0}}})
m += frame({"jsonrpc":"2.0","id":42,"method":"$/elisa/stats","params":{}})
m += frame({"jsonrpc":"2.0","id":43,"method":"nosuch/preinit","params":{}})
m += frame({"jsonrpc":"2.0","id":44,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"initialized"})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":"file:///pre-init.elisa","languageId":"Elisa","version":1,"text":"invalid syntax"}}})
m += frame({"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":47}})
m += frame({"jsonrpc":"2.0","id":45,"method":"initialize","params":{"capabilities":{}}})
m += frame({"jsonrpc":"2.0","method":"initialized"})
m += frame({"jsonrpc":"2.0","method":"initialized"})
m += frame({"jsonrpc":"2.0","id":47,"method":"nosuch/after-init","params":{}})
m += frame({"jsonrpc":"2.0","id":46,"method":"$/elisa/stats","params":{}})
m += frame({"jsonrpc":"2.0","id":48,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 0, f"pre-init lifecycle matrix exit={p.returncode}: {p.stderr!r}"
preinit_msgs = frames(p.stdout)
preinit_by_id = {x.get("id"): x for x in preinit_msgs if "id" in x}
for request_id in (41, 42, 43, 44):
    assert preinit_by_id[request_id].get("error", {}).get("code") == -32002, \
        f"pre-initialize request {request_id} must be ServerNotInitialized: {preinit_msgs}"
assert "result" in preinit_by_id[45], f"pre-init shutdown/notifications must not consume initialize: {preinit_msgs}"
assert preinit_by_id[47].get("error", {}).get("code") == -32601, \
    f"a pre-initialize cancellation notification must be dropped: {preinit_msgs}"
assert preinit_by_id[46].get("result", {}).get("documents") == 0, \
    f"pre-initialize didOpen must not mutate document storage: {preinit_msgs}"
assert "result" in preinit_by_id[48], f"valid shutdown after one initialize must succeed: {preinit_msgs}"
assert len(preinit_msgs) == 8, f"lifecycle notifications must never get responses: {preinit_msgs}"

# Clean EOF is a transport-level orderly stop (also before an initialize
# handshake); an explicit exit notification without shutdown remains failure.
for payload, label in ((b"", "empty input"),
                       (frame({"jsonrpc":"2.0","id":51,"method":"initialize","params":{"capabilities":{}}}), "EOF after initialize")):
    p = run(payload)
    assert p.returncode == 0, f"{label} should close cleanly: {p.returncode}, {p.stderr!r}"

# LSP `integer` IDs use the signed 32-bit domain. Preserve both boundaries,
# reject adjacent values with null response IDs, and validate cancellation IDs.
m = frame({"jsonrpc":"2.0","id":60,"method":"initialize","params":{"capabilities":{}}})
for raw_id in (b"-2147483648", b"2147483647", b"-2147483649", b"2147483648"):
    body = b'{"jsonrpc":"2.0","id":' + raw_id + b',"method":"$/elisa/stats","params":{}}'
    m += fb(body)
m += fb(b'{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":2147483648}}')
m += frame({"jsonrpc":"2.0","id":99,"method":"shutdown"})
m += fb(b'{"jsonrpc":"2.0","method":"exit"}')
p = run(m)
assert p.returncode == 0, f"request-ID bounds matrix exit={p.returncode}: {p.stderr!r}"
id_msgs = frames(p.stdout)
id_by_value = {msg.get("id"): msg for msg in id_msgs if "id" in msg}
assert "result" in id_by_value[-2147483648] and "result" in id_by_value[2147483647], \
    f"signed 32-bit ID boundaries should be echoed: {id_msgs}"
bad_id_errors = [msg for msg in id_msgs if msg.get("id") is None and msg.get("error", {}).get("code") == -32600]
assert len(bad_id_errors) == 2, f"out-of-range request IDs need InvalidRequest/null ID: {id_msgs}"
assert not any(msg.get("method") == "$/cancelRequest" for msg in id_msgs), \
    f"cancellation notifications must remain response-free: {id_msgs}"

# Nested protocol fields are checked before handlers consume them. Escaped
# keys compare by their decoded spelling, and malformed didOpen/didChange
# notifications leave the document store and existing source unchanged.
m = frame({"jsonrpc":"2.0","id":60,"method":"initialize","params":{"capabilities":{}}})
m += fb(b'{"jsonrpc":"2.0","id":61,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.elisa","u\\u0072i":"file:///other.elisa"},"position":{"line":0,"character":0}}}')
m += fb(b'{"jsonrpc":"2.0","id":62,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.elisa"},"position":{"line":0,"l\\u0069ne":1,"character":0}}}')
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///missing-language.elisa","version":1,"text":"def missing() -> i64:\n    return 1\n"}}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///empty-language.elisa","languageId":"","version":1,"text":"def empty() -> i64:\n    return 1\n"}}})
m += frame({"jsonrpc":"2.0","id":63,"method":"$/elisa/stats","params":{}})
doc = "def alpha() -> i64:\n    return 1\n"
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///nested-duplicate.elisa","languageId":"Elisa","version":1,"text":doc}}})
m += fb(b'{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///nested-duplicate.elisa","version":2},"contentChanges":[{"text":"def beta() -> i64:\\n    return 2\\n","text":"def gamma() -> i64:\\n    return 3\\n"}]}}')
m += frame({"jsonrpc":"2.0","id":64,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///nested-duplicate.elisa"},"position":{"line":0,"character":5}}})
m += frame({"jsonrpc":"2.0","id":65,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 0, f"nested parameter validation exit={p.returncode}: {p.stderr!r}"
nested_msgs = frames(p.stdout)
nested_by_id = {x.get("id"): x for x in nested_msgs if "id" in x}
assert nested_by_id[61].get("error", {}).get("code") == -32602, nested_msgs
assert nested_by_id[62].get("error", {}).get("code") == -32602, nested_msgs
assert nested_by_id[63].get("result", {}).get("documents") == 0 and nested_by_id[63]["result"].get("open") == 0, \
    f"didOpen without required languageId or with an empty value must be ignored: {nested_msgs}"
assert nested_by_id[64].get("result", {}).get("contents", {}).get("value") == "def alpha -> i64", \
    f"duplicate contentChanges.text must not mutate the document: {nested_msgs}"
assert "result" in nested_by_id[65], nested_msgs

# Malformed known notifications are ignored without JSON-RPC replies and
# reported through a bounded stderr counter. The log stays free of client data.
m = frame({"jsonrpc":"2.0","id":70,"method":"initialize","params":{"capabilities":{}}})
m += frame({"jsonrpc":"2.0","method":"initialized"})
for _ in range(12):
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{}})
m += frame({"jsonrpc":"2.0","id":71,"method":"$/elisa/stats","params":{}})
m += frame({"jsonrpc":"2.0","id":72,"method":"shutdown"})
m += frame({"jsonrpc":"2.0","method":"exit"})
p = run(m)
assert p.returncode == 0, f"malformed notification log case exit={p.returncode}: {p.stderr!r}"
logged_msgs = frames(p.stdout)
assert len(logged_msgs) == 3, f"malformed notifications must not produce responses: {logged_msgs}"
assert sum("ignored malformed notification" in line for line in p.stderr.decode().splitlines()) == 8
assert sum("further malformed notifications suppressed" in line for line in p.stderr.decode().splitlines()) == 1
assert "textDocument" not in p.stderr.decode() and "file://" not in p.stderr.decode(), \
    f"bounded logs must not contain request/source data: {p.stderr!r}"

print("protocol OK: envelope, lifecycle, exit codes, typed IDs")
PY
