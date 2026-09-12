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

FIX="$ROOT/test/json_smoke.elisa"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# Pure-Elisa probe (no C driver): avoids C-ABI runtime-init fragility that
# segfaulted the old header/obj + driver.c approach. Absolute includes keep the
# temp file outside the tree buildable without -I support.
cat > "$WORK/probe.elisa" <<EOF
include "$ROOT/../Elisa-compiler/elisacore_std/elisacore_runtime.elisa"
include "$ROOT/src/json.elisa"
def main() -> int can[Console.Write, Memory.Allocate, Console.Format, Abort.Panic]:
    src: sview = sview("{\\"jsonrpc\\":\\"2.0\\",\\"id\\":7,\\"method\\":\\"initialize\\",\\"params\\":{\\"a\\":[10,20,30]}}", 0, -1)
    root: Json::Value = Json::parse(src)
    id: mutable i64 = 0
    mok: mutable i64 = 0
    ac: mutable i64 = 0
    a1: mutable i64 = 0
    if Json::get(root, "id") is idv:
        id <- Json::as_i64(idv)
    if Json::get(root, "method") is mv:
        mok <- 1 if string_view_eq(Json::as_str(mv), "initialize") == 1
    if Json::get(root, "params") is pv:
        if Json::get(pv, "a") is av:
            match av:
                Json::Value.Arr(items):
                    ac <- items.count.i64()
                    a1 <- Json::as_i64(items[1]) if items.count >= 2
                _:
                    pass
    print(id)
    print(mok)
    print(ac)
    print(a1)
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
want="7 1 3 20"
if [[ "$got" != "$want" ]]; then
    echo "json smoke FAILED: got [$got] want [$want]" >&2
    exit 1
fi
echo "json smoke OK: id=7 method=initialize a=[_,20,_] count=3"
