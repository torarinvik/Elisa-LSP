#!/usr/bin/env bash
# A01 frontend-contract fixture: compile and exercise the frontend adapter
# against the pinned compiler. If the frontend surface changes (renamed field,
# renumbered `ref_kind`, moved enum registries), this fails in the adapter's
# terms — a localized contract break, not a scattered feature regression.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ELISAC="${ELISAC:-$HOME/.elisac/elisac-stage0}"
[[ -x "$ELISAC" ]] || { echo "error: no compiler at $ELISAC (set ELISAC)" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "error: missing clang" >&2; exit 2; }

COMPILER_ROOT="${ELISA_COMPILER_ROOT:-$ROOT/../Elisa-compiler}"
[[ -d "$COMPILER_ROOT/src/semantic" ]] || { echo "error: compiler checkout not found at $COMPILER_ROOT" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

cat > "$WORK/probe.elisa" <<EOF
include "$COMPILER_ROOT/elisacore_std/elisacore_runtime.elisa"
include "$COMPILER_ROOT/src/semantic/semantic.elisa"
include "$ROOT/src/frontend_adapter.elisa"

def main() -> int can[Console.Write, Memory.Allocate, Console.Format, Abort.Panic]:
    text: cstr = "def f(p: i64) -> i64:\n    local: i64 = p\n    return local\n"
    buf: mutable darray[u8] = []
    buf.extend(sview(text, 0, -1))
    buf.push(0)
    src: u8& = &buf[0]
    len: usize = buf.count - 1
    tokens: darray[Token] = Lexer::frontend_tokenize_with_length(src, src, len)
    file: Ast::File = frontend_parser_parse_file(src, tokens)
    table: Semantic::SymbolTable = Semantic::check(file)
    # Contract facts the rest of the server relies on.
    v: i64 = frontend_contract_version()
    param_kind: i64 = occurrence_kind_at(table, 1, "p")
    local_kind: i64 = occurrence_kind_at(table, 2, "local")
    missing_kind: i64 = occurrence_kind_at(table, 1, "no_such_name")
    f: i64 = symbol_index_of(table, "f")
    scount: usize = symbol_count(table)
    dcount: usize = diagnostic_count(table)
    has_f: mutable i64 = 1
    has_f <- 0 if f >= 0
    has_syms: mutable i64 = 0
    has_syms <- 1 if scount > 0
    clean: mutable i64 = 0
    clean <- 1 if dcount == 0
    print(v)
    print(param_kind)
    print(local_kind)
    print(missing_kind)
    print(has_f)
    print(has_syms)
    print(clean)
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
# version=1, param=1, local=2, unknown=-1, has_f=0, symbols>0=1, clean=1
want="1 1 2 -1 0 1 1"
if [[ "$got" != "$want" ]]; then
  echo "frontend contract FAILED: got [$got] want [$want]" >&2
  exit 1
fi
echo "frontend contract OK: v1; ref_kind param=1 local=2; symbol/diagnostic accessors"
