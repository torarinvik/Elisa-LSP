# Elisa LSP development

Supported toolchain: stage0 `elisacore` + host clang + python3 (B01).

## Quick start (clean checkout)

```bash
# 1. Provide the compiler (stage0, full backend):
export ELISAC="$HOME/.elisac/elisac-stage0"
# 2. Provide the adjacent compiler checkout for the frontend include
#    (default: ../Elisa-compiler relative to this repo):
export ELISA_COMPILER_ROOT="/path/to/Elisa-compiler"
# 3. Build + test:
bash build.sh            # release (-O2)
bash test/run_all.sh
```

`bash build.sh --debug` builds `-O0` for faster iteration. `BUILD_PROFILE=debug|release`
overrides the flag form. `bash build.sh --profile=O1` selects an explicit opt level
(only `O0`/`O2` are validated; others build but are not gated).

## Why stage0, not stage1

`Elisa-compiler/bin/elisac-stage1*` are self-hosted snapshots whose backend is
incomplete. They decline LSP constructs that stage0 accepts:

- `match` with range patterns (`push_utf8` in `src/json.elisa`)
- packed-enum `match` (`extract_id`, `request_text_value` in `src/main.elisa`)
- indexed `mutable&` assignment (`read_line`)

`build.sh` rejects stage1 binaries with an actionable error. If you must probe
stage1, compile minimal reproducers under `/tmp` — do not change the LSP build
to accommodate its gaps.

## Layout

- `src/main.elisa` — stdio framing, dispatch, lifecycle, document store, hover
- `src/json.elisa` — strict-ish JSON values + deferred string decoding
- `src/diagnostics.elisa` — frontend adapter (`Semantic::check` → publishDiagnostics)
- `src/semtokens.elisa` — token legend, classification, delta encoding
- `src/diagnostics.elisa:19` includes the frontend via
  `../../Elisa-compiler/src/semantic/semantic.elisa`. That relative path is the
  pinned-checkout mechanism: it resolves against `ELISA_COMPILER_ROOT`
  (default adjacent checkout). The exact compiler revision is recorded in
  `build/manifest.json` on every build.

## Build details (B01)

- `build.sh` is the only supported build entry; `project.json` holds the
  canonical `entry`/`opt`, and `build.sh` reads them (profile flags override
  `opt` for that invocation with a printed note).
- Compilation goes to a `mktemp` directory; `build/elisa-lsp` and
  `build/elisa-lsp.o` are replaced atomically only after compile+link succeed,
  so a failed build never leaves a stale binary behind.
- Stage0 objects reference optional profiling hooks
  (`elisa_profile_*`); `build.sh` generates a weak-symbol fallback C file and
  links `object + fallback` with host clang (`-fno-builtin`). The runtime
  itself is already inside the object — do NOT link
  `Elisa-compiler/build/runtime/elisacore_runtime.o` (duplicate symbols).
- Every build writes `build/manifest.json`: timestamp, profile/opt, entry,
  `ELISAC` path, `compiler_root` + `compiler_rev`, `lsp_rev`, clang version,
  target triple, os/arch. A dirty working tree prints a warning (binary
  includes uncommitted changes).
- Missing `ELISAC`, missing compiler checkout, or missing clang fail before
  compiling with an actionable message.

## Testing

- `bash test/run_all.sh` — canonical entry: builds are assumed fresh; runs
  every `test/*_test.sh` + `test/json_smoke.sh`, fails on first failure,
  refuses to run when `build/elisa-lsp` is missing or older than `src/`.
- `test/lsp_client.py` — shared framed subprocess client (Content-Length
  framing, typed-ID matching, deadlock-free drain); new protocol tests should
  use it instead of hand-rolled shell framing.
- Existing shell tests remain supported during migration; they validate
  happy paths + selected regressions, not Unicode/transport/workspace
  conformance (see IMPLEMENTATION_PLAN.md B02).

## Sync policy (D02)

The server advertises full synchronization (`textDocumentSync: 1`) and means
it: `didChange` validates **every** `contentChanges` entry in order and uses
the last. Any entry carrying `range`/`rangeLength`, a missing/non-string
`text`, or an empty change list rejects the whole notification without
mutating the store. Stale/equal versions are likewise ignored (D01), and
`didChange` for a never-opened URI is dropped. Incremental sync is **not**
advertised until the reference-model tests for it pass — a fragment must
never be mistaken for the whole document.

## Diagnostic ranges (G01)

`src/diagnostics.elisa` maps `Semantic::Diagnostic.pos` (1-based byte
columns) to LSP UTF-16 code units and clamps both ends inside the source
snapshot. Real frontend spans render exactly; span-less findings fall back to
the bounded line extent. The server never emits `character: 999`. Line
numbers beyond EOF clamp to the last line; inverted ends collapse to start.

## Diagnostic publication (G02)

Pushes carry the client document `version` so the client can order them.
Identical repeats for the same version are suppressed (duplicate `didOpen`
sends one push, not two). Output is capped at 200 findings with a visible
severity-4 hint (`"... N more diagnostics omitted ..."`) instead of silent
truncation, and exact duplicates never appear twice. Close publishes an empty
array with the last known version, transferring the file back to disk-backed
ownership. The publish path re-checks the document generation before sending,
so a stale analysis can never overwrite newer findings once analysis moves
off the event loop.

## Source coordinates (U01/U02)

`src/positions.elisa` (`module Positions`) is the one coordinate API: byte
offsets internally, UTF-16 line/character only at the protocol boundary.
Diagnostics, semantic tokens, and hover all route through it. Tokens convert
starts via per-line byte→unit mapping and lengths via span unit counts, so
non-ASCII lines (CJK, emoji, combining marks) slice exactly. `test/positions_test.sh`
decodes every token and diagnostic range of a Unicode fixture through a single
UTF-16 helper — one basis, all providers.

## URI identity (D03)

`request_uri` only unescapes JSON. Lookup identity comes from `uri_canonical`
in `src/main.elisa`: schemes lowercased, `file` authorities normalized
(`localhost` dropped, others kept distinct and never resolved), remainder
percent-decoded (`%XX`, malformed sequences kept literal), `#fragment`
stripped. Responses echo the client's incoming spelling; storage and lookup
use the canonical bytes. Paths keep their case and symlinks are not resolved
(filesystem-aware aliasing belongs to W02). `untitled:` and unknown schemes
are opaque in-memory overlays — never fetched. `test/uri_test.sh` pins the
equivalence classes and the no-accidental-alias rule.

## Capability negotiation (P03)

`initialize` params are parsed once into a session profile
(`negotiate_utf8`, `negotiate_hover_markdown` in `src/main.elisa`) and
threaded to diagnostics, tokens, and hover — one branch point, no per-handler
disagreement. Position encodings honor client preference order (first of
utf-8/utf-16 wins, default UTF-16); the server advertises `positionEncoding`
only when UTF-8 wins. Token/diagnostic columns follow the session mode via
`Positions::line_unit_length/byte_col_to_units/span_unit_length`. Hover sends
`plaintext` only when the client lists formats without `markdown`. Unknown or
absent capabilities keep safe defaults. `test/capabilities_test.sh` pins the
order rules, byte/unit columns, hover kinds, and fallbacks.

## Strict protocol numerics (J02)

`Json::is_int_text/is_int_num/as_i64_checked` (in `src/json.elisa`) accept
only canonical integers with i64-overflow rejection. Versions tristate to
absent (-1, legacy accept), malformed (-2, notification rejected outright),
or value — so `1.5` can never coerce to 15 and poison staleness logic, and
overflows can never masquerade as unversioned. Hover lines use the same
checked parse (anything non-integer hovers null). `test/numerics_test.sh`
pins rejection plus post-reject recovery.

## Document symbols (F02)

`src/features/document_symbols.elisa` renders the frontend's file symbol
table as an outline. Only symbols with `line > 0` (real file content) are
emitted — prelude/primitive scope is excluded. Shape follows the session:
flat `SymbolInformation` by default, hierarchical `DocumentSymbol` (with
`children`) only when the client sets
`hierarchicalDocumentSymbolSupport`. `selectionRange` is the exact name span
when the symbol's byte `offset` validates inside its own line, else the line
extent; the enclosing `range` is the declaration line (declaration end lines
and enum variants await A02). The client's `symbolKind.valueSet` is honored by
clamping each category through fallbacks, and `Unknown` kinds are omitted
rather than guessed. Floors: `test/document_symbols_test.sh`.

## Transport framing (T01)

Input is buffered, not read one byte per syscall. `transport_fill` keeps a
reusable read buffer whose unconsumed tail survives across messages, so a
single `read` may deliver several frames, part of a frame, or a split
multibyte UTF-8 sequence without mis-framing (`read_message` in
`src/main.elisa`). Bounds and strictness: header names are case-insensitive,
`Content-Length` values must be pure digits (no `5x`, no empty value) and are
overflow-checked; conflicting duplicate lengths, missing lengths, zero-length
bodies, truncated headers/bodies, and oversized headers/bodies (16 KiB
header / 64 lines / 16 MiB body) are controlled nonzero exits with no output
frame. Clean EOF between messages is exit 0. Floors: `test/transport_test.sh`
(split at every byte, pipelining, malformed-length matrix, large-body refill).

## Region/lifetime constraints

The frontend's region system rejects storing a function-local container into
caller-owned storage (`docs`: AutoRegionStoreEscape). Copy bytes, not
containers:

```elisa
# BAD: out.extend(caps) where caps is local and out is caller-owned
# GOOD:
for b in caps:
    out.push(b)
```

`build.sh` surfaces these as frontend errors (e.g. `src/main.elisa:390`);
see `Elisa-compiler/src/semantic/check_auto_region_escape.elisa`.

## Platforms

Validated candidates: macOS (arm64, Homebrew clang 23) and Linux. Other
platforms build at your own risk — `build.sh` warns but proceeds. Windows
support is explicitly out of scope until transport/paths/watcher/linker gaps
are closed (R04).
