#!/usr/bin/env bash
# JSON module smoke: parse a JSON-RPC document and assert navigated values.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ELISAC="${ELISAC:-$HOME/.elisac/elisac}"
command -v clang >/dev/null 2>&1 || { echo "error: missing clang" >&2; exit 2; }

FIX="$ROOT/test/json_smoke.elisa"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

cat > "$WORK/driver.c" <<'EOF'
#include "json_smoke.h"
#include <stdint.h>
#include <stdio.h>
int main(void) {
    const char *s = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{\"a\":[10,20,30]}}";
    size_t n = 0; while (s[n]) n++;
    uint64_t id = 0, ac = 0, a1 = 0; uint8_t mok = 0;
    json_probe_export((uint8_t *)s, n, &id, &mok, &ac, &a1);
    printf("%llu %u %llu %llu\n", (unsigned long long)id, (unsigned)mok,
           (unsigned long long)ac, (unsigned long long)a1);
    return 0;
}
EOF

"$ELISAC" -emit header -o "$WORK/json_smoke.h" "$FIX" >/dev/null
"$ELISAC" -emit obj -O2 -o "$WORK/json_smoke.o" "$FIX" >/dev/null

link_flags=(-O2 -I "$WORK" "$WORK/driver.c" "$WORK/json_smoke.o" -o "$WORK/run")
[[ "$(uname -s)" == "Darwin" ]] && link_flags=(-Wl,-undefined,dynamic_lookup "${link_flags[@]}")
[[ "$(uname -s)" == "Linux" ]] && link_flags=(-no-pie "${link_flags[@]}")
clang "${link_flags[@]}"

got="$("$WORK/run")"
want="7 1 3 20"
if [[ "$got" != "$want" ]]; then
    echo "json smoke FAILED: got [$got] want [$want]" >&2
    exit 1
fi
echo "json smoke OK: id=7 method=initialize a=[_,20,_] count=3"
