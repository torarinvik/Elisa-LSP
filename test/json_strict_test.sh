#!/usr/bin/env bash
# J01: malformed JSON bodies receive a JSON-RPC ParseError (id null) instead of
# being silently coerced or crashing; valid bodies still dispatch; hostile
# nesting is bounded.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
def fb(b):
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
def run(payload):
    p = subprocess.run([srv], input=payload, capture_output=True, timeout=30)
    return p
def frames(buf):
    out, pos = [], 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        assert sep >= 0, "truncated header"
        ln = int(buf[pos:sep].split(b":",1)[1].strip())
        start = sep+4
        out.append(json.loads(buf[start:start+ln]))
        pos = start+ln
    return out

init = fb(json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}).encode())
shut = fb(json.dumps({"jsonrpc":"2.0","id":9,"method":"shutdown"}).encode())
ex   = fb(json.dumps({"jsonrpc":"2.0","method":"exit"}).encode())

# 1. Each malformed body yields exactly one ParseError with id null.
bads = [b'{bad', b'{"a":}', b'[1,2', b'{"x":1}trailing', b'"unterminated',
        b'{"n":01}', b'{}extra', b'nan', b'{"a":1,}', b'\x00', b'  ', b'-']
invalid_utf8 = [
    b'{"x":"\x80"}',                  # isolated continuation
    b'{"x":"\xc0\xaf"}',              # overlong encoding
    b'{"x":"\xe2\x82"}',              # truncated three-byte scalar
    b'{"x":"\xed\xa0\x80"}',          # UTF-8 encoding of a surrogate
    b'{"x":"\xf4\x90\x80\x80"}',      # above U+10FFFF
    b'{"x":"\\uD800"}',                  # unpaired high JSON surrogate
    b'{"x":"\\uDC00"}',                  # unpaired low JSON surrogate
    b'{"x":"\\uD800\\u0041"}',         # high surrogate + non-low code unit
]
too_many_values = b"[" + b"null," * 200000 + b"null]"
truncation_source = '{"jsonrpc":"2.0","id":7,"method":"$/elisa/stats","params":{"s":"UTF-8 🌍","a":[1,true,null]}}'.encode("utf-8")
truncations = [truncation_source[:i] for i in range(len(truncation_source))]
all_bads = bads + invalid_utf8 + [too_many_values] + truncations
payload = [init]
for b in all_bads:
    payload.append(fb(b))
payload += [shut, ex]
p = run(b"".join(payload))
assert p.returncode == 0, f"exit {p.returncode}, stderr={p.stderr[-1000:]!r}, stdout tail={p.stdout[-500:]!r}"
ms = frames(p.stdout)
errs = [m for m in ms if m.get("error", {}).get("code") == -32700]
assert len(errs) == len(all_bads), f"expected {len(all_bads)} ParseErrors, got {len(errs)}: {ms}"
for e in errs:
    assert e.get("id") is None, f"ParseError id must be null: {e}"
    assert "jsonrpc" in e and e["jsonrpc"] == "2.0", e
    detail = e.get("error", {}).get("data")
    assert isinstance(detail, dict) and isinstance(detail.get("offset"), int), \
        f"ParseError must expose structured offset detail: {e}"
    assert detail.get("category") in {"encoding", "syntax", "resourceLimit"}, e

assert errs[5]["error"]["data"] == {"offset": 6, "category": "syntax"}, \
    f"leading-zero JSON number should identify its first invalid byte: {errs[5]}"
encoding_error = errs[len(bads)]
assert encoding_error["error"]["data"] == {"offset": 6, "category": "encoding"}, \
    f"invalid UTF-8 should report its first invalid byte: {encoding_error}"
value_limit_index = len(bads) + len(invalid_utf8)
value_limit_error = errs[value_limit_index]["error"]["data"]
assert value_limit_error["category"] == "resourceLimit", f"value budget category missing: {errs[value_limit_index]}"
assert 0 < value_limit_error["offset"] < len(too_many_values), value_limit_error
truncation_errors = errs[value_limit_index + 1:]
assert len(truncation_errors) == len(truncations), \
    f"every-byte truncation matrix incomplete: {len(truncation_errors)} / {len(truncations)}"
for truncated, response in zip(truncations, truncation_errors):
    detail = response["error"]["data"]
    assert detail["offset"] <= len(truncated), (truncated, detail)

# 2. Valid JSON still dispatches (initialize + shutdown answered).
assert any(m.get("id") == 1 and "result" in m for m in ms), "initialize must still work"
assert any(m.get("id") == 9 and "result" in m for m in ms), "shutdown must still work"

# 3. Hostile nesting is rejected (bounded), not a crash or hang.
deep = b"[" * 5000 + b"]" * 5000
p = run(init + fb(deep) + shut + ex)
assert p.returncode == 0, f"deep nesting must not crash: rc={p.returncode}"
ms = frames(p.stdout)
assert any(m.get("error", {}).get("code") == -32700 for m in ms), "deep nesting must be a ParseError"
deep_error = next(m for m in ms if m.get("error", {}).get("code") == -32700)
assert deep_error["error"]["data"]["category"] == "resourceLimit", deep_error

# 4. Valid nested JSON within the bound is accepted.
ok_nested = fb(json.dumps({"jsonrpc":"2.0","id":2,"method":"$/elisa/stats","params":{"a":[1,{"b":[True,None]}],"s":"x"}}).encode())
p_unicode = fb(json.dumps({"jsonrpc":"2.0","id":3,"method":"$/elisa/stats","params":{"s":"héllo 🌍"}}, ensure_ascii=False).encode("utf-8"))
escaped_unicode = fb(b'{"jsonrpc":"2.0","id":5,"method":"$/elisa/stats","params":{"s":"\\uD83C\\uDF0D"}}')
escaped_key = fb(b'{"jsonrpc":"2.0","id":4,"metho\\u0064":"initialize","params":{"capabilities":{}}}')
p = run(init + ok_nested + p_unicode + escaped_unicode + escaped_key + shut + ex)
ms = frames(p.stdout)
assert any(m.get("id") == 2 and "result" in m for m in ms), f"valid nesting must dispatch: {ms}"
assert any(m.get("id") == 3 and "result" in m for m in ms), "valid multi-byte UTF-8 must dispatch"
assert any(m.get("id") == 5 and "result" in m for m in ms), "valid escaped surrogate pair must dispatch"
assert any(m.get("id") == 4 and "error" in m and m["error"]["code"] == -32600 for m in ms), \
    "escaped-equivalent method key must dispatch as initialize and reject duplicate init"

print(f"json strict OK: {len(all_bads)} malformed bodies -> ParseError(id null), UTF-8, depth and value counts bounded")
PY
