#!/usr/bin/env bash
# JSON module smoke: parse a JSON-RPC document and assert navigated values.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Same toolchain discovery as build.sh: explicit ELISAC wins, else stage0.
ELISAC="${ELISAC:-$HOME/.elisac/elisac-stage0}"
if [[ ! -x "$ELISAC" ]]; then
  echo "error: no Elisa compiler at '$ELISAC' (set ELISAC=\$HOME/.elisac/elisac-stage0)" >&2
  exit 2
fi
if [[ "$(basename "$ELISAC")" == elisac-stage1* ]]; then
  echo "error: stage1 backend declines JSON smoke constructs; use stage0 elisacore" >&2
  exit 2
fi
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

FIX="$ROOT/test/json_smoke.elisa"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# Pure-Elisa probe (no C driver): avoids C-ABI runtime-init fragility that
# segfaulted the old header/obj + driver.c approach. Absolute includes keep the
# temp file outside the tree buildable without -I support.
cat > "$WORK/probe.elisa" <<EOF
include "$COMPILER_ROOT/elisacore_std/elisacore_runtime.elisa"
include "$ROOT/src/json.elisa"
def parsed_i64(value: Json::Value) -> i64:
    match Json::as_i64_result(value):
        Json::I64ParseOutcome.Valid(parsed):
            return parsed
        Json::I64ParseOutcome.Invalid:
            return -999

def parsed_lsp_integer(value: Json::Value) -> i64:
    match Json::as_lsp_integer_result(value):
        Json::I64ParseOutcome.Valid(parsed):
            return parsed
        Json::I64ParseOutcome.Invalid:
            return -999

def parsed_lsp_uinteger(value: Json::Value) -> i64:
    match Json::as_lsp_uinteger_result(value):
        Json::I64ParseOutcome.Valid(parsed):
            return parsed
        Json::I64ParseOutcome.Invalid:
            return -999

def lsp_integer_is_valid(value: Json::Value) -> i64:
    match Json::as_lsp_integer_result(value):
        Json::I64ParseOutcome.Valid(_):
            return 1
        Json::I64ParseOutcome.Invalid:
            return 0

def string_outcome(value: Json::Value) -> i64:
    match Json::as_str_result(value):
        Json::StringParseOutcome.Valid(_):
            return 1
        Json::StringParseOutcome.Null:
            return 2
        Json::StringParseOutcome.WrongType:
            return 3

def is_empty_string(value: Json::Value) -> i64:
    match Json::as_str_result(value):
        Json::StringParseOutcome.Valid(text):
            return 1 if sview_len(text) == 0 else 0
        Json::StringParseOutcome.Null | Json::StringParseOutcome.WrongType:
            return 0

def main() -> int can[Console.Write, Memory.Allocate, Console.Format, Abort.Panic]:
    src: sview = sview("{\\"jsonrpc\\":\\"2.0\\",\\"id\\":7,\\"method\\":\\"initialize\\",\\"params\\":{\\"a\\":[10,20,30]}}", 0, -1)
    root: mutable Json::Value
    match Json::parse(src):
        Json::ParseOutcome.Parsed(parsed_root):
            root <- parsed_root
        Json::ParseOutcome.Rejected(_):
            return 1
    id: mutable i64 = 0
    mok: mutable i64 = 0
    ac: mutable i64 = 0
    a1: mutable i64 = 0
    if Json::get(root, "id") is idv:
        id <- parsed_i64(idv)
    if Json::get(root, "method") is mv:
        match Json::as_str_result(mv):
            Json::StringParseOutcome.Valid(method):
                mok <- 1 if string_view_eq(method, "initialize") == 1
            Json::StringParseOutcome.Null | Json::StringParseOutcome.WrongType:
                pass
    if Json::get(root, "params") is pv:
        if Json::get(pv, "a") is av:
            match av:
                Json::Value.Arr(items):
                    ac <- items.count.i64()
                    a1 <- parsed_i64(items[1]) if items.count >= 2
                _:
                    pass
    print(id)
    print(mok)
    print(ac)
    print(a1)

    syntax_src: sview = sview("{\\"n\\":01}", 0, -1)
    syntax_error: mutable Json::ValidationError = Json::ValidationError{offset: 0, category: Json::ValidationCategory.Encoding}
    syntax_ok: bool = Json::validate(syntax_src, syntax_error)
    syntax_failed: mutable i64 = 1
    syntax_failed <- 0 if syntax_ok
    print(syntax_failed)
    print(syntax_error.offset.i64())
    match syntax_error.category:
        Json::ValidationCategory.Syntax:
            print(1)
        _:
            print(0)

    invalid_bytes: mutable darray[u8] = []
    invalid_bytes.push(123)
    invalid_bytes.push(34)
    invalid_bytes.push(120)
    invalid_bytes.push(34)
    invalid_bytes.push(58)
    invalid_bytes.push(34)
    invalid_bytes.push(0x80)
    encoding_src: sview = bytes_view_range_ref(invalid_bytes, 0, invalid_bytes.count)
    encoding_error: mutable Json::ValidationError = Json::ValidationError{offset: 0, category: Json::ValidationCategory.Syntax}
    encoding_ok: bool = Json::validate(encoding_src, encoding_error)
    encoding_failed: mutable i64 = 1
    encoding_failed <- 0 if encoding_ok
    print(encoding_failed)
    print(encoding_error.offset.i64())
    match encoding_error.category:
        Json::ValidationCategory.Encoding:
            print(1)
        _:
            print(0)

    deep_bytes: mutable darray[u8] = []
    deep_i: mutable i64 = 0
    while deep_i < 258:
        deep_bytes.push(91)
        deep_i <- deep_i + 1
    deep_i <- 0
    while deep_i < 258:
        deep_bytes.push(93)
        deep_i <- deep_i + 1
    deep_src: sview = bytes_view_range_ref(deep_bytes, 0, deep_bytes.count)
    resource_error: mutable Json::ValidationError = Json::ValidationError{offset: 0, category: Json::ValidationCategory.Syntax}
    resource_ok: bool = Json::validate(deep_src, resource_error)
    resource_failed: mutable i64 = 1
    resource_failed <- 0 if resource_ok
    print(resource_failed)
    print(resource_error.offset.i64())
    match resource_error.category:
        Json::ValidationCategory.ResourceLimit:
            print(1)
        _:
            print(0)

    duplicate_src: sview = sview("{\\"x\\":1,\\"x\\":2}", 0, -1)
    duplicate_first: mutable i64 = 0
    match Json::parse(duplicate_src):
        Json::ParseOutcome.Parsed(duplicate_root):
            if Json::get(duplicate_root, "x") is duplicate_value:
                duplicate_first <- 1 if parsed_i64(duplicate_value) == 1
        Json::ParseOutcome.Rejected(_):
            pass
    print(duplicate_first)
    print(parsed_i64(Json::Value.Num(sview("-2", 0, -1))))
    print(parsed_i64(Json::Value.Num(sview("-9223372036854775808", 0, -1))))
    print(parsed_i64(Json::Value.Num(sview("9223372036854775807", 0, -1))))
    print(parsed_i64(Json::Value.Num(sview("9223372036854775808", 0, -1))))
    print(parsed_i64(Json::Value.Num(sview("-9223372036854775809", 0, -1))))
    print(parsed_lsp_integer(Json::Value.Num(sview("-2147483648", 0, -1))))
    print(parsed_lsp_integer(Json::Value.Num(sview("2147483647", 0, -1))))
    print(parsed_lsp_integer(Json::Value.Num(sview("2147483648", 0, -1))))
    print(parsed_lsp_integer(Json::Value.Num(sview("-2147483649", 0, -1))))
    print(parsed_lsp_uinteger(Json::Value.Num(sview("0", 0, -1))))
    print(parsed_lsp_uinteger(Json::Value.Num(sview("2147483647", 0, -1))))
    print(parsed_lsp_uinteger(Json::Value.Num(sview("2147483648", 0, -1))))
    print(parsed_lsp_uinteger(Json::Value.Num(sview("-1", 0, -1))))
    print(is_empty_string(Json::Value.Str(sview("", 0, 0))))
    print(is_empty_string(Json::Value.Num(sview("0", 0, -1))))
    print(parsed_lsp_integer(Json::Value.Num(sview("-999", 0, -1))))
    print(lsp_integer_is_valid(Json::Value.Num(sview("-999", 0, -1))))
    print(lsp_integer_is_valid(Json::Value.Num(sview("2147483648", 0, -1))))
    print(string_outcome(Json::Value.Null))
    print(string_outcome(Json::Value.Num(sview("0", 0, -1))))
    absent_is_distinct: mutable i64 = 1
    if Json::get(root, "absent") is absent_value:
        absent_is_distinct <- 0
    print(absent_is_distinct)
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

got="$("$WORK/run" | tr '\n' ' ' | sed 's/ *$//')"
want="7 1 3 20 1 6 1 1 6 1 1 257 1 1 -2 -9223372036854775808 9223372036854775807 -999 -999 -2147483648 2147483647 -999 -999 0 2147483647 -999 -999 1 0 -999 1 0 2 3 1"
if [[ "$got" != "$want" ]]; then
    echo "json smoke FAILED: got [$got] want [$want]" >&2
    exit 1
fi
echo "json smoke OK: parse tree plus syntax/encoding/resource offsets and categories"
