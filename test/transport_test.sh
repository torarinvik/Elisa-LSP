#!/usr/bin/env bash
# T01: buffered, bounded input framing.
# - one message split at every byte boundary (including multibyte UTF-8)
# - several frames delivered in one write (pipelining / read-ahead)
# - case-insensitive Content-Length; strict value grammar
# - malformed, empty, overflowing, conflicting, missing, zero-length, and
#   truncated frames are controlled nonzero exits (never hangs, never a
#   successful-exit misinterpretation)
# - oversized headers rejected without unbounded allocation
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]

def body(o):
    return json.dumps(o, separators=(",", ":")).encode()
def frame(o):
    b = body(o)
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def run(payload, timeout=20):
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=timeout)
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

INIT = {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
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

# 4. Malformed / empty / overflowing / conflicting / zero-length lengths.
def raw_header_frame(header, payload=b""):
    return header + b"\r\n\r\n" + payload
bad_cases = {
    "garbage suffix": raw_header_frame(b"Content-Length: 5x", b"hello"),
    "empty value": raw_header_frame(b"Content-Length:"),
    "spaces only": raw_header_frame(b"Content-Length:   "),
    "overflow": raw_header_frame(b"Content-Length: 99999999999999999999999", b"x"),
    "missing": raw_header_frame(b"X-Other: 1", b"{}"),
    "zero length": raw_header_frame(b"Content-Length: 0"),
    "conflicting dup": raw_header_frame(b"Content-Length: 2\r\nContent-Length: 3", b"{}"),
}
for name, payload in bad_cases.items():
    rc, out = run(payload)
    assert rc != 0, f"{name}: expected nonzero exit, got {rc} (out={out[:120]!r})"
    assert out == b"", f"{name}: framing error must not emit a response frame: {out[:120]!r}"

# 5. Truncated header and truncated body at EOF.
rc, _ = run(b"Content-Length: 10\r\n\r\nabc")           # body short
assert rc != 0, "truncated body must be a framing error"
rc, _ = run(b"Content-Length: 10\r\nX-Other")           # header cut mid-line
assert rc != 0, "truncated header must be a framing error"

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

print("transport OK: split-at-every-byte, pipelining, strict bounded framing")
PY
