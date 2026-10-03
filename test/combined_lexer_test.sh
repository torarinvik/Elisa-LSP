#!/usr/bin/env bash
# Q04/A03: the analysis snapshot's lexer pass must provide both parser tokens
# and comment spans. This probe compares the new combined entry point with the
# two legacy streams on the same source, including CRLF, strings, an f-string,
# and comments. It also prevents the LSP from silently falling back to the
# comment-only entry point.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ELISAC_BIN="${ELISAC:-$HOME/.elisac/elisac-stage0}"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-$ROOT/../Elisa-compiler}"

[[ -x "$ELISAC_BIN" ]] || { echo "combined lexer SKIP: compiler missing: $ELISAC_BIN" >&2; exit 2; }
[[ -d "$COMPILER_ROOT/src/lexer" ]] || { echo "combined lexer SKIP: frontend missing: $COMPILER_ROOT" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "combined lexer SKIP: clang missing" >&2; exit 2; }

# The worker must consume the combined API. A comment-only call here would
# restore the old second whole-source lex even if the direct API probe passed.
if rg -n 'frontend_tokenize_comments_with_length' "$ROOT/src"; then
    echo "combined lexer FAILED: LSP source still calls the legacy comment-only lexer" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

python3 - "$COMPILER_ROOT" "$WORK/probe.elisa" <<'PY'
import pathlib
import sys

compiler_root, probe_path = sys.argv[1:]
runtime = (pathlib.Path(compiler_root) / "elisacore_std/elisacore_runtime.elisa").as_posix()

source = '# leading comment\\r\\ndef sample() -> i64:\\r\\n    text: dstr = "literal # is not a comment"\\r\\n    interpolated: dstr = f"value {{1 + 2}}" # trailing comment\\r\\n    return 1 # final comment\\r\\n'
source_literal = source.replace('"', '\\"')

probe = f'''include "{runtime}"
include "{pathlib.Path(compiler_root).as_posix()}/src/lexer/lexer.elisa"

def token_equal(left: Lexer::Token, right: Lexer::Token) -> bool:
    return left.line == right.line and left.column == right.column and left.start == right.start and left.length == right.length and left.suffix_length == right.suffix_length and left.kind == right.kind and left.flags.has_suffix == right.flags.has_suffix

def main() -> int:
    source: cstr = "{source_literal}"
    source_len: usize = Lexer::cstring_length(source)
    combined: Lexer::FrontendTokenBatch = Lexer::frontend_tokenize_expanded_unit_with_comments(source, source, source_len)
    expanded: darray[Lexer::Token] = Lexer::frontend_tokenize_expanded_unit(source, source, source_len)
    legacy_comments: darray[Lexer::Token] = Lexer::frontend_tokenize_comments_with_length(source, source, source_len)

    # The combined main stream is the parser-compatible stream byte-for-byte;
    # this catches accidental changes to EOF, indentation, suffix, or f-string
    # token metadata while the side channel is being added.
    return 10 if combined.tokens.count != expanded.count
    index: mutable usize = 0
    while index < expanded.count:
        return 11 if not token_equal(combined.tokens[index], expanded[index])
        index <- index + 1

    # The comment side channel must preserve exactly the legacy comment spans;
    # comments inside quoted text and the f-string are intentionally absent.
    return 12 if combined.comments.count != legacy_comments.count
    return 13 if combined.comments.count == 0
    index <- 0
    while index < legacy_comments.count:
        return 14 if not token_equal(combined.comments[index], legacy_comments[index])
        index <- index + 1
    return 0
'''
pathlib.Path(probe_path).write_text(probe, encoding="utf-8")
PY

if ! "$ELISAC_BIN" -emit obj -O2 -o "$WORK/probe.o" "$WORK/probe.elisa" >"$WORK/compile.log" 2>&1; then
    echo "combined lexer FAILED: probe did not compile" >&2
    tail -n 30 "$WORK/compile.log" >&2
    exit 1
fi

# The lexer-only object can still reference the optional allocation-observer
# hooks exported by the full LSP. Weak no-op fallbacks keep this direct probe
# independent of the server executable and make it safe to run headlessly.
python3 - "$WORK/fallback.c" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(r'''
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__) || defined(__clang__)
#define ELISA_WEAK __attribute__((weak))
#else
#define ELISA_WEAK
#endif
ELISA_WEAK uint32_t elisa_profile_allocation_negotiate(uint32_t version) { (void)version; return 0; }
ELISA_WEAK uint32_t elisa_profile_region_layout_negotiate(uint32_t version) { (void)version; return 0; }
ELISA_WEAK void elisa_profile_region_layout_v1(uintptr_t a, size_t b, uintptr_t c, uintptr_t d, size_t e) { (void)a; (void)b; (void)c; (void)d; (void)e; }
ELISA_WEAK void elisa_profile_allocation_event_v1(uint32_t a, uintptr_t b, size_t c, uintptr_t d, size_t e, uintptr_t f, size_t g) { (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; }
''', encoding="utf-8")
PY

clang -O2 -fno-builtin -o "$WORK/probe" "$WORK/probe.o" "$WORK/fallback.c"
if ! "$WORK/probe"; then
    echo "combined lexer FAILED: combined and legacy token streams differ" >&2
    exit 1
fi

echo "combined lexer OK: one frontend pass preserves parser tokens and comment spans"
