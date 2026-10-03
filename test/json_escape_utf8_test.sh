#!/usr/bin/env bash
# Directly exercise the diagnostic JSON string encoder with malformed UTF-8.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ELISAC="${ELISAC:-$HOME/.elisac/elisac-stage0}"
[[ -x "$ELISAC" ]] || { echo "error: no Elisa compiler at '$ELISAC'" >&2; exit 2; }
[[ "$(basename "$ELISAC")" != elisac-stage1* ]] || { echo "error: use stage0 elisacore" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "error: missing clang" >&2; exit 2; }
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-$ROOT/../Elisa-compiler}"
if [[ "$COMPILER_ROOT" != /* ]]; then
  COMPILER_ROOT="$ROOT/$COMPILER_ROOT"
fi
COMPILER_ROOT="$(cd -- "$COMPILER_ROOT" 2>/dev/null && pwd -P || true)"
[[ -f "$COMPILER_ROOT/elisacore_std/elisacore_runtime.elisa" ]] || {
  echo "error: compiler runtime not found at '$COMPILER_ROOT' (set ELISA_COMPILER_ROOT)" >&2
  exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

cat > "$WORK/probe.elisa" <<EOF
include "$COMPILER_ROOT/elisacore_std/elisacore_runtime.elisa"
include "$ROOT/src/json.elisa"
include "$ROOT/src/json_writer.elisa"

def main() -> int can[Console, Memory.Allocate, Abort.Panic]:
    out: mutable darray[u8] = []
    out.push(91)
    out.push(34)

    overlong3: mutable darray[u8] = []
    overlong3.push(0xE0)
    overlong3.push(0x82)
    overlong3.push(0x80)
    json_escape_utf8(out, bytes_view_range_ref(overlong3, 0, overlong3.count))
    out.push(34)
    out.push(44)
    out.push(34)

    overlong4: mutable darray[u8] = []
    overlong4.push(0xF0)
    overlong4.push(0x80)
    overlong4.push(0x90)
    overlong4.push(0x80)
    json_escape_utf8(out, bytes_view_range_ref(overlong4, 0, overlong4.count))
    out.push(34)
    out.push(44)
    out.push(34)

    valid_boundaries: mutable darray[u8] = []
    valid_boundaries.push(0xC2)
    valid_boundaries.push(0x80)
    valid_boundaries.push(0xE0)
    valid_boundaries.push(0xA0)
    valid_boundaries.push(0x80)
    valid_boundaries.push(0xF0)
    valid_boundaries.push(0x90)
    valid_boundaries.push(0x80)
    valid_boundaries.push(0x80)
    json_escape_utf8(out, bytes_view_range_ref(valid_boundaries, 0, valid_boundaries.count))
    out.push(34)
    out.push(44)
    out.push(34)

    surrogate: mutable darray[u8] = []
    surrogate.push(0xED)
    surrogate.push(0xA0)
    surrogate.push(0x80)
    json_escape_utf8(out, bytes_view_range_ref(surrogate, 0, surrogate.count))
    out.push(34)
    out.push(44)
    out.push(34)

    too_high: mutable darray[u8] = []
    too_high.push(0xF4)
    too_high.push(0x90)
    too_high.push(0x80)
    too_high.push(0x80)
    json_escape_utf8(out, bytes_view_range_ref(too_high, 0, too_high.count))
    out.push(34)
    out.push(44)
    out.push(34)

    stray_continuations: mutable darray[u8] = []
    stray_continuations.push(0x80)
    stray_continuations.push(0xBF)
    json_escape_utf8(out, bytes_view_range_ref(stray_continuations, 0, stray_continuations.count))
    out.push(34)
    out.push(44)
    out.push(34)

    invalid_continuations: mutable darray[u8] = []
    invalid_continuations.push(0xC2)
    invalid_continuations.push(65)
    invalid_continuations.push(0xE2)
    invalid_continuations.push(0x82)
    invalid_continuations.push(66)
    invalid_continuations.push(0xF0)
    invalid_continuations.push(0x90)
    invalid_continuations.push(0x80)
    invalid_continuations.push(67)
    json_escape_utf8(out, bytes_view_range_ref(invalid_continuations, 0, invalid_continuations.count))
    out.push(34)
    out.push(44)
    out.push(34)

    truncated_2: mutable darray[u8] = []
    truncated_2.push(0xC2)
    json_escape_utf8(out, bytes_view_range_ref(truncated_2, 0, truncated_2.count))
    out.push(34)
    out.push(44)
    out.push(34)

    truncated_3: mutable darray[u8] = []
    truncated_3.push(0xE2)
    truncated_3.push(0x82)
    json_escape_utf8(out, bytes_view_range_ref(truncated_3, 0, truncated_3.count))
    out.push(34)
    out.push(44)
    out.push(34)

    truncated_4: mutable darray[u8] = []
    truncated_4.push(0xF0)
    truncated_4.push(0x90)
    truncated_4.push(0x80)
    json_escape_utf8(out, bytes_view_range_ref(truncated_4, 0, truncated_4.count))
    out.push(34)
    out.push(44)
    out.push(34)

    max_scalar: mutable darray[u8] = []
    max_scalar.push(0xF4)
    max_scalar.push(0x8F)
    max_scalar.push(0xBF)
    max_scalar.push(0xBF)
    json_escape_utf8(out, bytes_view_range_ref(max_scalar, 0, max_scalar.count))
    out.push(34)
    out.push(44)
    out.push(34)

    special_text: mutable darray[u8] = []
    special_text.push(81)
    special_text.push(34)
    special_text.push(92)
    special_text.push(10)
    special_text.push(9)
    special_text.push(1)
    special_text.push(0xF0)
    special_text.push(0x9F)
    special_text.push(0x8C)
    special_text.push(0x8D)
    json_escape_utf8(out, bytes_view_range_ref(special_text, 0, special_text.count))
    out.push(34)
    out.push(44)
    json_push_i64(out, -2)
    out.push(44)
    json_push_i64(out, -9223372036854775808)
    out.push(44)
    json_push_i64(out, 9223372036854775807)
    out.push(44)
    json_push_i64(out, 0)
    out.push(44)
    json_push_i64(out, 2147483648)
    out.push(93)

    written: mutable usize = 0
    while written < out.count:
        n: isize = write(1, (&out[written]).cast[void&], out.count - written) can Console
        if n <= 0:
            return 1
        written <- written + n.usize()
    return 0
EOF

"$ELISAC" -emit obj -O2 -o "$WORK/probe.o" "$WORK/probe.elisa" >/dev/null
cat > "$WORK/fallback.c" <<'EOF'
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__) || defined(__clang__)
#define ELISA_WEAK __attribute__((weak))
#else
#define ELISA_WEAK
#endif
ELISA_WEAK uint32_t elisa_profile_allocation_negotiate(uint32_t version) { (void)version; return 0; }
ELISA_WEAK uint32_t elisa_profile_region_layout_negotiate(uint32_t version) { (void)version; return 0; }
ELISA_WEAK void elisa_profile_region_layout_v1(uintptr_t a,size_t b,uintptr_t c,uintptr_t d,size_t e){(void)a;(void)b;(void)c;(void)d;(void)e;}
ELISA_WEAK void elisa_profile_allocation_event_v1(uint32_t a,uintptr_t b,size_t c,uintptr_t d,size_t e,uintptr_t f,size_t g){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;}
EOF
clang -O2 -fno-builtin -o "$WORK/run" "$WORK/probe.o" "$WORK/fallback.c"

"$WORK/run" | python3 -c 'import json, sys; actual=json.load(sys.stdin); expected=["\ufffd"*3, "\ufffd"*4, "\u0080\u0800\U00010000", "\ufffd"*3, "\ufffd"*4, "\ufffd"*2, "\ufffdA\ufffd\ufffdB\ufffd\ufffd\ufffdC", "\ufffd", "\ufffd"*2, "\ufffd"*3, "\U0010ffff", "Q\"\\\n\t\x01\U0001f30d", -2, -9223372036854775808, 9223372036854775807, 0, 2147483648]; assert actual == expected, (actual, expected); print("JSON writer OK: malformed UTF-8, scalar boundaries, controls, escaping and signed i64 values")'
