#!/usr/bin/env bash
# D03: file-URI component decoding and lexical OS-path conversion. The probe
# runs both POSIX and Windows grammars on the same host; no filesystem access
# or symlink resolution is involved.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ELISAC="${ELISAC:-$HOME/.elisac/elisac-stage0}"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-$ROOT/../Elisa-compiler}"
[[ -x "$ELISAC" ]] || { echo "error: no Elisa compiler at '$ELISAC'" >&2; exit 2; }
[[ "$(basename "$ELISAC")" != elisac-stage1* ]] || { echo "error: file-URI probe requires stage0" >&2; exit 2; }
[[ -d "$COMPILER_ROOT/elisacore_std" ]] || { echo "error: compiler runtime not found at '$COMPILER_ROOT'" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "error: missing clang" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

python3 - "$ROOT" "$COMPILER_ROOT" "$WORK/probe.elisa" "$WORK/cases.json" <<'PY'
import json
import sys

root, compiler_root, probe_path, cases_path = sys.argv[1:]

# The explicit platform flag makes this a cross-platform grammar test even on
# Darwin: POSIX authorities are refused, while Windows authorities become UNC
# roots and drive-qualified URI forms are converted to backslash paths.
cases = [
    (False, "file:///tmp/caf%C3%A9%20space.elisa", "/tmp/café space.elisa"),
    (False, "FILE://LOCALHOST/etc/%E2%98%83.elisa", "/etc/☃.elisa"),
    (False, "file:/var/lib/main.elisa", "/var/lib/main.elisa"),
    (False, "file:///a%2Fb.elisa", "/a/b.elisa"),
    (False, "file://", "/"),
    (False, "file://localhost", "/"),
    (False, "file://server/share/main.elisa", None),
    (False, "file:relative/main.elisa", None),
    (False, "file:///tmp/%ZZ.elisa", None),
    (False, "file:///tmp/%00.elisa", None),
    (False, "file:///tmp/main.elisa?query", None),
    (False, "file:///tmp/main.elisa#fragment", None),
    (True, "file:///C:/Users/A%20B/%CE%B1.elisa", r"C:\Users\A B\α.elisa"),
    (True, "file:///c|/work/main.elisa", r"c:\work\main.elisa"),
    (True, "file://C:/work/main.elisa", r"C:\work\main.elisa"),
    (True, "file://localhost/C:/work/main.elisa", r"C:\work\main.elisa"),
    (True, "file://Server/share/a%20b.elisa", r"\\Server\share\a b.elisa"),
    (True, "file://Server", "\\\\Server\\"),
    (True, "file:/tmp/a.elisa", r"\tmp\a.elisa"),
    (True, "file:C:/work/main.elisa", r"C:\work\main.elisa"),
    (True, "file:///tmp/a%5Cb.elisa", r"\tmp\a\b.elisa"),
    (True, "file:C:relative.elisa", None),
    (True, "file:///tmp/a:b.elisa", None),
    (True, "file:///tmp/a%3Fb.elisa", None),
    (True, "file://server/share/a%00b.elisa", None),
]

packed = []
for windows, uri, expected in cases:
    raw = uri.encode("utf-8")
    assert len(raw) < 256
    packed.extend((1 if windows else 0, len(raw), *raw))

runtime = compiler_root.replace('"', '\\"') + "/elisacore_std/elisacore_runtime.elisa"
uri_module = (root + "/src/uri.elisa").replace('"', '\\"')
source = f'''include "{runtime}"
include "{uri_module}"

def main() -> int can[Console.Write, Memory.Allocate, Console.Format, Abort.Panic]:
    bytes_blob: mutable darray[u8] = [{", ".join(map(str, packed))}]
    output: mutable darray[u8] = []
    cursor: mutable usize = 0
    case_count: i64 = {len(cases)}
    case_no: mutable i64 = 0
    while case_no < case_count:
        windows: bool = bytes_blob[cursor] == 1
        cursor <- cursor + 1
        uri_len: usize = bytes_blob[cursor].usize()
        cursor <- cursor + 1
        uri: u8& = &bytes_blob[cursor]
        converted: mutable darray[u8] = []
        ok: bool = Uri::file_uri_to_path(uri, uri_len, windows, converted)
        status: i64 = 1 if ok else 0
        print(status)
        print(converted.count.i64())
        for b in converted:
            print(b.i64())
        cursor <- cursor + uri_len
        case_no <- case_no + 1
    return 0
'''
with open(probe_path, "w", encoding="utf-8") as stream:
    stream.write(source)
with open(cases_path, "w", encoding="utf-8") as stream:
    json.dump([(windows, uri, expected) for windows, uri, expected in cases], stream)
PY

"$ELISAC" -emit obj -O2 -o "$WORK/probe.o" "$WORK/probe.elisa" >/dev/null
cat > "$WORK/fallback.c" <<'EOF'
#include <stddef.h>
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
EOF
clang -O2 -fno-builtin -o "$WORK/probe" "$WORK/probe.o" "$WORK/fallback.c"

python3 - "$WORK/probe" "$WORK/cases.json" <<'PY'
import json
import subprocess
import sys

probe, cases_path = sys.argv[1:]
cases = json.load(open(cases_path, encoding="utf-8"))
values = [int(token) for token in subprocess.run(
    [probe], capture_output=True, text=True, timeout=20, check=True
).stdout.split()]
cursor = 0
for index, (_, uri, expected) in enumerate(cases):
    assert cursor + 2 <= len(values), (index, uri, values[cursor:])
    ok = values[cursor]
    count = values[cursor + 1]
    cursor += 2
    assert count >= 0 and cursor + count <= len(values), (index, uri, count)
    actual = bytes(values[cursor:cursor + count]).decode("utf-8")
    cursor += count
    if expected is None:
        assert ok == 0 and count == 0, (index, uri, ok, actual)
    else:
        assert ok == 1 and actual == expected, (index, uri, ok, actual, expected)
assert cursor == len(values), (cursor, len(values), values[cursor:])
print("URI path OK: strict file decoding, UTF-8/space paths, POSIX authorities, Windows drives and UNC syntax")
PY
