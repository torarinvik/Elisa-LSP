#!/usr/bin/env bash
# J03: deterministic differential JSON corpus. Python's stdlib serializer and
# parser generate/check valid JSON values embedded in JSON-RPC params; the LSP
# must parse and dispatch every one. Curated invalid bodies must be ParseError.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json
import random
import subprocess
import sys

srv = sys.argv[1]
rng = random.Random(0xE11A_2026)


def frame(body):
    if not isinstance(body, bytes):
        body = body.encode("utf-8")
    return b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body


def frames(buf):
    out, pos = [], 0
    while pos < len(buf):
        sep = buf.find(b"\r\n\r\n", pos)
        assert sep >= 0, f"truncated output header at {pos}: {buf[pos:pos+100]!r}"
        header = buf[pos:sep].split(b"\r\n")
        lengths = [line.split(b":", 1)[1].strip() for line in header if line.lower().startswith(b"content-length:")]
        assert len(lengths) == 1, f"bad output Content-Length: {header!r}"
        length = int(lengths[0])
        start = sep + 4
        end = start + length
        assert end <= len(buf), f"truncated output body: need {length}, have {len(buf)-start}"
        out.append(json.loads(buf[start:end].decode("utf-8")))
        pos = end
    return out


unicode_strings = [
    "", "plain ASCII", 'quote " slash / backslash \\\\', "line\nbreak\ttab\r",
    "café", "🌍🚀", "𝄞 and \u2028 separators", "nul\u0000control",
    "\b\f\n\r\t", "\"\\/",
]
number_edges = [0, -0, 1, -1, 2**53 - 1, -(2**53), 2**31, -(2**31),
                1.0, -0.0, 1e-300, 1e-7, 1e20, -1.23456789012345e+123]


def random_value(depth=0):
    # The recursion bound is intentionally well below the server's depth cap;
    # generated values stay useful for parser coverage without testing limits.
    kinds = ["null", "bool", "int", "float", "str"]
    if depth < 5:
        kinds += ["array", "object", "array", "object"]
    kind = rng.choice(kinds)
    if kind == "null":
        return None
    if kind == "bool":
        return bool(rng.getrandbits(1))
    if kind == "int":
        return rng.randint(-(2**53), 2**53)
    if kind == "float":
        return rng.choice(number_edges) if rng.random() < 0.65 else rng.uniform(-1e6, 1e6)
    if kind == "str":
        if rng.random() < 0.6:
            return rng.choice(unicode_strings)
        return "".join(rng.choice("abcXYZ012 \\\"\n\té🌍𝄞") for _ in range(rng.randrange(0, 28)))
    if kind == "array":
        return [random_value(depth + 1) for _ in range(rng.randrange(0, 6))]
    keys = ["a", "escaped\\\"key", "slash/key", "café", "🌍", "nested", "0"]
    result = {}
    for _ in range(rng.randrange(0, 6)):
        result[rng.choice(keys) + (str(rng.randrange(4)) if rng.random() < 0.3 else "")] = random_value(depth + 1)
    return result


corpus = [
    None, True, False, 0, -1, 1234567890123, -0.0, 1e-300, 1e20,
    "", "UTF-8: héllo 🌍 𝄞", "escapes: \\\" / \b\f\n\r\t",
    [], {}, [None, True, False, -17, 2.5, "nested 🌍"],
    {"plain": "value", "nested": {"array": [1, {"z": None}]}, "emoji🌍": "ok"},
]
corpus.extend(random_value() for _ in range(96))

messages = [frame(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities":{}}}, separators=(",", ":")).encode())]
expected_ids = []
for index, value in enumerate(corpus, start=100):
    # Mix compact output with raw UTF-8 and ASCII-only escaped Unicode. Both
    # spellings represent the same Python value and are accepted JSON.
    ensure_ascii = (index % 2 == 0)
    request = {"jsonrpc": "2.0", "id": index, "method": "$/elisa/stats",
               "params": {"seed": 0xE11A_2026, "case": index, "corpusValue": value}}
    body = json.dumps(request, ensure_ascii=ensure_ascii, allow_nan=False,
                      separators=(",", ":")).encode("utf-8")
    parsed = json.loads(body.decode("utf-8"))
    assert parsed["params"]["corpusValue"] == value, f"Python roundtrip mismatch for case {index}"
    messages.append(frame(body))
    expected_ids.append(index)

malformed = [
    b"{", b'{"x":}', b"[1,]", b'{"x":"\\x"}', b"01", b"true false",
    b'{"x":"\\uD800"}', b'{"x":"\\uDC00"}',
    b'{"x":"\x80"}', b'{"x":"\xc0\xaf"}',
]
messages.extend(frame(body) for body in malformed)
messages.append(frame(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "shutdown"}, separators=(",", ":")).encode()))
messages.append(frame(json.dumps({"jsonrpc": "2.0", "method": "exit"}, separators=(",", ":")).encode()))

proc = subprocess.run([srv], input=b"".join(messages), capture_output=True, timeout=45)
assert proc.returncode == 0, f"server exit={proc.returncode}, stderr={proc.stderr[:2000]!r}"
responses = frames(proc.stdout)
by_id = {msg["id"]: msg for msg in responses if "id" in msg and msg["id"] is not None}
assert len(by_id) == len(responses) - len(malformed), f"unexpected or duplicate response IDs: {responses}"
assert "result" in by_id[1], f"initialize failed: {by_id.get(1)}"
assert "result" in by_id[2], f"shutdown failed: {by_id.get(2)}"
for req_id in expected_ids:
    response = by_id.get(req_id)
    assert response is not None, f"valid Python JSON case {req_id} received no response"
    assert "result" in response and "error" not in response, \
        f"valid Python JSON case {req_id} did not dispatch successfully: {response}"

parse_errors = [msg for msg in responses if msg.get("error", {}).get("code") == -32700]
assert len(parse_errors) == len(malformed), \
    f"expected {len(malformed)} malformed bodies to produce ParseError; got {len(parse_errors)}: {responses}"
assert all(msg.get("id") is None for msg in parse_errors), parse_errors
assert not any(msg.get("error", {}).get("code") == -32700 for req_id, msg in by_id.items() if req_id in expected_ids), \
    "a Python-accepted corpus request was rejected as malformed"

print(f"json differential OK: {len(corpus)} seeded Python JSON values dispatched; {len(malformed)} malformed bodies -> ParseError")
PY

# Request dispatch alone cannot prove the decoded value is preserved. Exercise
# the Elisa parser, deferred string decoder, and production JSON writer as one
# seeded round trip, then use Json::parse's typed outcome on invalid roots.
ELISAC="${ELISAC:-$HOME/.elisac/elisac-stage0}"
[[ -x "$ELISAC" ]] || { echo "error: no Elisa compiler at '$ELISAC'" >&2; exit 2; }
[[ "$(basename "$ELISAC")" != elisac-stage1* ]] || { echo "error: use stage0 elisacore for JSON property probe" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "error: missing clang" >&2; exit 2; }

python3 - "$ROOT" "$ELISAC" <<'PY'
import json
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
elisac = sys.argv[2]
compiler_root = Path(os.environ.get("ELISA_COMPILER_ROOT", root.parent / "Elisa-compiler"))
rng = random.Random(0xD3C0_DE02)

curated = [
    "", "plain ASCII", 'quotes " and \\', "/slash/", "line\nbreak\r\ntab\t",
    "controls: \b\f\n\r\t\u0000\u001f", "café", "e\u0301", "🌍🚀",
    "𝄞 U+2028\u2028 U+2029\u2029", "\u0080\u07ff\u0800\uffff",
]
alphabet = list("abcXYZ012 /\\\"'")
pool = alphabet + ["\n", "\r", "\t", "\b", "\f", "\u0000", "é", "界", "🌍", "🚀", "𝄞", "\u2028", "\u2029", "\u0301"]
values = list(curated)
for _ in range(192):
    values.append("".join(rng.choice(pool) for _ in range(rng.randrange(0, 73))))

valid_sources = []
for value in values:
    valid_sources.append(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    valid_sources.append(json.dumps(value, ensure_ascii=True, separators=(",", ":")))
expected_values = [value for value in values for _ in range(2)]

invalid_sources = [
    "{", '{"x":}', "[1,]", '{"x":"\\x"}', "01", "true false",
    '{"x":"\\uD800"}', '{"x":"\\uDC00"}', '{"x":"\\uD800\\u0041"}',
    '"unterminated', "-", "[", '{"x":1,}',
]
for _ in range(96):
    doc = json.dumps({"seed": rng.randrange(-(2**53), 2**53), "s": "🌍" + rng.choice(values)},
                     ensure_ascii=bool(rng.getrandbits(1)), separators=(",", ":"))
    # Missing the final object brace and trailing junk must both be rejected.
    invalid_sources.extend((doc[:-1], doc + "x"))

valid_json = "[" + ",".join(valid_sources) + "]"
invalid_json = json.dumps(invalid_sources, ensure_ascii=True, separators=(",", ":"))

def elisa_string(text):
    # The inner JSON serializer expresses controls as backslash escapes.
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'

probe = f'''include "{compiler_root}/elisacore_std/elisacore_runtime.elisa"
include "{root}/src/json.elisa"
include "{root}/src/json_writer.elisa"

def main() -> int can[Console.Write, Memory.Allocate, Abort.Panic]:
    src: sview = sview({elisa_string(valid_json)}, 0, -1)
    parsed: mutable Json::Value
    match Json::parse(src):
        Json::ParseOutcome.Parsed(value):
            parsed <- value
        Json::ParseOutcome.Rejected(_):
            return 1
    output: mutable darray[u8] = []
    output.push(91)
    match parsed:
        Json::Value.Arr(items):
            i: mutable usize = 0
            while i < items.count:
                decoded: mutable darray[u8] = []
                Json::decode_into(items[i], decoded)
                if i > 0:
                    output.push(44)
                output.push(34)
                if decoded.count > 0:
                    json_escape_utf8(output, bytes_view(decoded))
                output.push(34)
                i <- i + 1
        _:
            return 2
    output.push(93)
    written: mutable usize = 0
    while written < output.count:
        n: isize = write(1, (&output[written]).cast[void&], output.count - written) can Console
        if n <= 0:
            return 3
        written <- written + n.usize()
    newline: mutable u8 = 10
    write(1, (&newline).cast[void&], 1) can Console

    bad_src: sview = sview({elisa_string(invalid_json)}, 0, -1)
    bad_values: mutable Json::Value
    match Json::parse(bad_src):
        Json::ParseOutcome.Parsed(value):
            bad_values <- value
        Json::ParseOutcome.Rejected(_):
            return 4
    bad_count: mutable i64 = 0
    match bad_values:
        Json::Value.Arr(items):
            i: mutable usize = 0
            while i < items.count:
                candidate: mutable darray[u8] = []
                Json::decode_into(items[i], candidate)
                candidate_src: sview = bytes_view(candidate)
                match Json::parse(candidate_src):
                    Json::ParseOutcome.Rejected(_):
                        bad_count <- bad_count + 1
                    Json::ParseOutcome.Parsed(_):
                        return 5
                i <- i + 1
        _:
            return 6
    count_bytes: mutable darray[u8] = []
    json_push_i64(count_bytes, bad_count)
    written <- 0
    while written < count_bytes.count:
        n: isize = write(1, (&count_bytes[written]).cast[void&], count_bytes.count - written) can Console
        if n <= 0:
            return 7
        written <- written + n.usize()
    return 0
'''

fallback = r'''#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__) || defined(__clang__)
#define ELISA_WEAK __attribute__((weak))
#else
#define ELISA_WEAK
#endif
ELISA_WEAK uint32_t elisa_profile_allocation_negotiate(uint32_t v) { (void)v; return 0; }
ELISA_WEAK uint32_t elisa_profile_region_layout_negotiate(uint32_t v) { (void)v; return 0; }
ELISA_WEAK void elisa_profile_region_layout_v1(uintptr_t a,size_t b,uintptr_t c,uintptr_t d,size_t e){(void)a;(void)b;(void)c;(void)d;(void)e;}
ELISA_WEAK void elisa_profile_allocation_event_v1(uint32_t a,uintptr_t b,size_t c,uintptr_t d,size_t e,uintptr_t f,size_t g){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;}
'''

with tempfile.TemporaryDirectory(prefix="elisa-json-property-") as tmp:
    tmp = Path(tmp)
    (tmp / "probe.elisa").write_text(probe, encoding="utf-8")
    (tmp / "fallback.c").write_text(fallback, encoding="utf-8")
    subprocess.run([elisac, "-emit", "obj", "-O2", "-o", str(tmp / "probe.o"), str(tmp / "probe.elisa")], check=True)
    subprocess.run(["clang", "-O2", "-fno-builtin", "-o", str(tmp / "probe"), str(tmp / "probe.o"), str(tmp / "fallback.c")], check=True)
    proc = subprocess.run([str(tmp / "probe")], capture_output=True, timeout=30)
    assert proc.returncode == 0, f"Elisa JSON property probe exited {proc.returncode}; stderr={proc.stderr[-1000:]!r}"
    lines = proc.stdout.splitlines()
    assert len(lines) == 2, f"expected encoded values plus invalid-root count: {proc.stdout[:200]!r}"
    decoded = json.loads(lines[0].decode("utf-8"))
    for index, (actual, expected) in enumerate(zip(decoded, expected_values)):
        assert actual == expected, f"round-trip mismatch at case {index}: {actual!r} != {expected!r}"
    assert len(decoded) == len(expected_values), f"round-trip count {len(decoded)} != {len(expected_values)}"
    assert int(lines[1]) == len(invalid_sources), f"invalid roots accepted as Parsed: {lines[1]!r} / {len(invalid_sources)}"

print(f"json Elisa properties OK: {len(expected_values)} seeded parse/decode/encode round trips; {len(invalid_sources)} invalid roots rejected")
PY
