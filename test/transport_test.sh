#!/usr/bin/env bash
# T01: buffered, bounded input framing.
# - one message split at every byte boundary (including multibyte UTF-8)
# - several frames delivered in one write (pipelining / read-ahead)
# - case-insensitive Content-Length; strict value grammar
# - malformed, empty, overflowing, conflicting, and missing lengths
#   truncated frames are controlled nonzero exits (never hangs, never a
#   successful-exit misinterpretation)
# - oversized headers rejected without unbounded allocation
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, os, subprocess, sys
srv = sys.argv[1]

def body(o):
    return json.dumps(o, separators=(",", ":")).encode()
def frame(o):
    b = body(o)
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def run(payload, timeout=20, extra_env=None):
    env = os.environ.copy() if extra_env is not None else None
    if extra_env is not None:
        env.update(extra_env)
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=timeout, env=env)
    return p.returncode, p.stdout

def frames(buf):
    out, pos = [], 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        assert sep >= 0, "truncated response header"
        ln = int(buf[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        out.append(json.loads(buf[start:start+ln]))
        pos = start+ln
    return out

INIT = {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
EXIT = {"jsonrpc":"2.0","method":"exit"}
SHUT = {"jsonrpc":"2.0","id":9,"method":"shutdown"}

# 1. Byte-at-a-time fragmentation, including a multibyte UTF-8 document.
doc = 'def f() -> void:\n    x: dstr = "héllo 🌍"\n'
msgs = [INIT,
        {"jsonrpc":"2.0","method":"textDocument/didOpen",
         "params":{"textDocument":{"uri":"file:///split.elisa","languageId":"Elisa","version":1,"text":doc}}},
        SHUT, EXIT]
payload = b"".join(frame(m) for m in msgs)
p = subprocess.Popen([srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
for i in range(len(payload)):
    p.stdin.write(payload[i:i+1])
    p.stdin.flush()
p.stdin.close()
out = p.stdout.read()
rc = p.wait(timeout=20)
assert rc == 0, f"fragmented session exited {rc}: {p.stderr.read()[:400]!r}"
ms = frames(out)
ids = [m["id"] for m in ms if "id" in m]
assert ids == [1, 9], f"fragmented framing lost/duplicated responses: {ids}"

# 2. Pipelined: two requests in ONE write; both answered in order.
one_write = frame(INIT) + frame({"jsonrpc":"2.0","id":2,"method":"nosuch/method","params":{}}) + frame(SHUT) + frame(EXIT)
rc, out = run(one_write)
assert rc == 0
ms = frames(out)
by_id = {m["id"]: m for m in ms if "id" in m}
assert 1 in by_id and 2 in by_id and by_id[2].get("error", {}).get("code") == -32601, by_id

# 3. Case-insensitive header name is accepted.
b = body(INIT)
b_shut = body(SHUT)
b_exit = body(EXIT)
lower = (b"content-length: " + str(len(b)).encode() + b"\r\n\r\n" + b
         + b"content-length: " + str(len(b_shut)).encode() + b"\r\n\r\n" + b_shut
         + b"content-length: " + str(len(b_exit)).encode() + b"\r\n\r\n" + b_exit)
rc, out = run(lower)
assert rc == 0 and any(m.get("id") == 1 for m in frames(out)), \
    f"lowercase headers must be accepted (rc={rc})"

# Optional Content-Type supports the LSP JSON-RPC media type and both current
# and historical UTF-8 charset spellings. Header names/parameters are
# case-insensitive and surrounding horizontal whitespace is tolerated.
typed_headers = (
    b"Content-Length: " + str(len(b)).encode() + b"\r\n"
    + b"cOnTeNt-TyPe:\tAPPLICATION/VSCODE-JSONRPC ; CHARSET = \"UTF-8\" \t\r\n\r\n" + b
    + frame(SHUT) + frame(EXIT)
)
rc, out = run(typed_headers)
assert rc == 0 and any(m.get("id") == 1 for m in frames(out)), \
    f"valid explicit UTF-8 Content-Type must be accepted (rc={rc})"
legacy_utf8 = (b"Content-Length: " + str(len(b)).encode() + b"\r\n"
               + b"Content-Type: application/vscode-jsonrpc; charset=utf8\r\n\r\n" + b
               + frame(SHUT) + frame(EXIT))
rc, out = run(legacy_utf8)
assert rc == 0 and any(m.get("id") == 1 for m in frames(out)), \
    f"legacy utf8 charset spelling must be accepted (rc={rc})"

# Identical duplicate lengths are deliberately tolerated; conflicting values
# below are rejected because the body boundary would be ambiguous.
identical = (b"Content-Length: " + str(len(b)).encode() + b"\r\n"
             + b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
             + frame(SHUT) + frame(EXIT))
rc, out = run(identical)
assert rc == 0 and any(m.get("id") == 1 and "result" in m for m in frames(out)), \
    f"identical duplicate lengths should be tolerated (rc={rc})"

# 4. Malformed / empty / overflowing / conflicting lengths.
def raw_header_frame(header, payload=b""):
    return header + b"\r\n\r\n" + payload
bad_cases = {
    "garbage suffix": raw_header_frame(b"Content-Length: 5x", b"hello"),
    "empty value": raw_header_frame(b"Content-Length:"),
    "spaces only": raw_header_frame(b"Content-Length:   "),
    "overflow": raw_header_frame(b"Content-Length: 99999999999999999999999", b"x"),
    "missing": raw_header_frame(b"X-Other: 1", b"{}"),
    "conflicting dup": raw_header_frame(b"Content-Length: 2\r\nContent-Length: 3", b"{}"),
    "wrong content type": raw_header_frame(b"Content-Length: 2\r\nContent-Type: text/plain", b"{}"),
    "unsupported charset": raw_header_frame(b"Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-16", b"{}"),
    "unsupported content encoding": raw_header_frame(b"Content-Length: 2\r\nContent-Encoding: gzip", b"{}"),
    "header without colon": raw_header_frame(b"Content-Length: 2\r\nNot-A-Field", b"{}"),
    "non-ascii header": raw_header_frame(b"Content-Length: 2\r\nX-Name: \xff", b"{}"),
    "bare LF header": b"Content-Length: 2\n\n{}",
}
for name, payload in bad_cases.items():
    rc, out = run(payload)
    assert rc != 0, f"{name}: expected nonzero exit, got {rc} (out={out[:120]!r})"
    assert out == b"", f"{name}: framing error must not emit a response frame: {out[:120]!r}"

# A zero-byte body is a complete frame containing invalid JSON, so it receives
# ParseError and the following messages remain synchronized.
zero_body = b"Content-Length: 0\r\n\r\n"
rc, out = run(frame(INIT) + zero_body + frame(SHUT) + frame(EXIT))
assert rc == 0, f"zero-length JSON body must not terminate the session (rc={rc})"
zero_msgs = frames(out)
zero_errors = [m for m in zero_msgs if m.get("error", {}).get("code") == -32700]
assert len(zero_errors) == 1 and zero_errors[0]["error"]["data"] == {"offset": 0, "category": "syntax"}, \
    f"zero-length body should receive a structured ParseError: {zero_msgs}"
assert any(m.get("id") == 1 and "result" in m for m in zero_msgs), zero_msgs
assert any(m.get("id") == 9 and "result" in m for m in zero_msgs), zero_msgs

# 5. Truncated header and truncated body at EOF.
rc, _ = run(b"Content-Length: 10\r\n\r\nabc")           # body short
assert rc != 0, "truncated body must be a framing error"
rc, _ = run(b"Content-Length: 10\r\nX-Other")           # header cut mid-line
assert rc != 0, "truncated header must be a framing error"
# A malformed boundary followed by a plausible frame must fail immediately;
# the parser must never hunt body bytes for a later apparent header.
rc, out = run(b"Content-Length: 5x\r\n\r\nhello" + frame(INIT))
assert rc != 0 and out == b"", "malformed framing must fail closed without scanning for a later frame"

# The declared body cap is checked before allocating/reading the body.
rc, out = run(b"Content-Length: 16777217\r\n\r\n")
assert rc != 0 and out == b"", "a body above the 16 MiB default must fail before allocation"

# Configured bounds are validated at startup. A bad override is reported on
# stderr before any input is processed; a valid smaller body cap takes effect.
rc, out = run(b"", extra_env={"ELISA_LSP_MAX_BODY_BYTES": "0"})
assert rc == 2 and out == b"", f"invalid transport bounds need a controlled config failure (rc={rc})"

larger_than_override = {"jsonrpc": "2.0", "id": 2, "method": "x/ignored",
                        "params": {"padding": "p" * 1500}}
rc, out = run(frame(INIT) + frame(larger_than_override), extra_env={"ELISA_LSP_MAX_BODY_BYTES": "1024"})
assert rc == 1 and [m.get("id") for m in frames(out)] == [1], \
    f"configured small body limit was not applied (rc={rc}, frames={frames(out)})"

# A single line without LF must be rejected as soon as the header byte budget
# is crossed, without waiting for client EOF or allocating until termination.
overlong = subprocess.Popen([srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert overlong.stdin is not None
overlong.stdin.write(b"X-Long: " + b"a" * 32768)
overlong.stdin.flush()
try:
    overlong_rc = overlong.wait(timeout=3)
except subprocess.TimeoutExpired:
    overlong.kill()
    overlong.wait(timeout=3)
    raise AssertionError("unterminated oversized header line was not bounded")
assert overlong_rc != 0, f"single overlong header line should fail (rc={overlong_rc})"
if overlong.stdin is not None:
    overlong.stdin.close()
if overlong.stdout is not None:
    overlong.stdout.close()
if overlong.stderr is not None:
    overlong.stderr.close()

# 6. Oversized header (many lines) rejected without unbounded work.
many = b"".join(b"X-Pad-%d: %s\r\n" % (i, b"a"*40) for i in range(200))
rc, _ = run(many + b"\r\n")
assert rc != 0, "oversized header must be rejected"

# 7. Body larger than one transport chunk frames correctly (refill + read-ahead).
big = 'def f0() -> void:\n    pass\n' + ("# " + "z"*80 + "\n")*400
bigmsgs = [INIT,
           {"jsonrpc":"2.0","method":"textDocument/didOpen",
            "params":{"textDocument":{"uri":"file:///big.elisa","languageId":"Elisa","version":1,"text":big}}},
           {"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
            "params":{"textDocument":{"uri":"file:///big.elisa"}}},
           SHUT, EXIT]
rc, out = run(b"".join(frame(m) for m in bigmsgs), timeout=60)
assert rc == 0, f"large body exited {rc}"
ms = frames(out)
tok = [m for m in ms if m.get("id") == 2]
assert tok and tok[0]["result"].get("data"), "large body must tokenize"

# A client that closes stdout must not kill the server with SIGPIPE. The
# writer records EPIPE and the synchronous main loop exits with status 1.
closed = subprocess.Popen([srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
assert closed.stdin is not None and closed.stdout is not None
closed.stdin.write(frame(INIT))
closed.stdin.flush()
closed.stdout.close()
closed.stdin.close()
closed_rc = closed.wait(timeout=10)
assert closed_rc == 1, f"closed output pipe should be a controlled exit 1, got {closed_rc}"
if closed.stderr is not None:
    closed.stderr.close()

print("transport OK: split-at-every-byte, pipelining, strict bounded framing")
PY
