# Elisa LSP

A language server for the Elisa language that speaks LSP over stdio. It embeds
the real Elisa compiler frontend for lexing, parsing, and semantic checking, so
diagnostics and highlighting come from the compiler itself rather than
re-implemented rules.

## Status

This is an early language server with a tested stdio protocol foundation,
versioned open-document snapshots, Unicode-aware ranges, compiler-backed
diagnostics, and several editor features. The exact supported surface is kept
in `docs/feature-manifest.json` and checked by `test/manifest_test.sh`.

| Capability | State | Notes |
|---|---|---|
| `textDocument/semanticTokens/full` and `/range` | Working | Stable 48-type Elisa legend for compatible clients, standard fallbacks for generic clients; UTF-16 by default or UTF-8 when negotiated |
| `textDocument/publishDiagnostics` | Working | Compiler ranges, document versions, duplicate suppression, a visible cap, optional related locations |
| `textDocument/documentSymbol` | Working | Flat `SymbolInformation` or hierarchical `DocumentSymbol`; respects `symbolKind.valueSet` |
| `textDocument/foldingRange` and `selectionRange` | Working | Indentation/comment folds; nested word, line, block, and document selections |
| `textDocument/hover` | Working, limited | Declarations and parameter/local bindings, plus loop-header capture details; semantic facts are still a limited summary |
| `textDocument/definition` | Limited | Exact same-file links to unique top-level functions and parameter/local bindings; nested shadowing follows `BindingId` |
| `textDocument/references` | Limited | Exact same-file unique-function edges and parameter/local binding occurrences; declaration inclusion follows `includeDeclaration` |
| `textDocument/documentHighlight` | Limited | Exact same-file function and parameter/local highlights; declarations, reads, and direct `<-` assignment targets have kinds; other assignment forms remain conservative |
| `textDocument/completion` | Limited | Incomplete same-file function/type/constant, exact-owner parameter, and root-body local candidates with prefix filtering and exact full-token edits; nested-scope locals/imports/members remain limited |
| `textDocument/prepareRename` / `textDocument/rename` | Limited | Exact same-file parameters and locals only; rename edits are versioned and reject any new spelling already present in the source |
| `textDocument/didOpen` / `didChange` / `didClose` | Working | Full and incremental changes; ordered batches validate transactionally in UTF-16 or UTF-8 units |
| Lifecycle (`initialize`/`initialized`/`shutdown`/`exit`) | Working | Explicit state machine and documented process exit behavior |
| `textDocument/signatureHelp` | Limited | One positional signature for unique same-file functions; conservative recovery while typing an unmatched call |
| Formatting | Not implemented | Not advertised; requires lossless syntax/trivia and safe-edit support |

Capabilities are advertised only when implemented and tested; see
`docs/feature-manifest.json` for the authoritative status.

## Build

Requirements: a compatible stage0 Elisa compiler, an Elisa compiler checkout
for frontend includes, clang, and python3. The current Darwin/arm64 release
uses the compiler optimization-integration snapshot recorded in
docs/development.md and passes the canonical suite 81/81. The Linux/aarch64
release and suite results are historical for an earlier compiler input and
must be rerun against the current pin; other platforms remain unvalidated. The
stage1 optimizer candidate is not yet compatible with the complete LSP source
unit. See docs/development.md for exact compiler, artifact, and platform
evidence.

```bash
export ELISAC="$HOME/.elisac/elisac-stage0"
export ELISA_COMPILER_ROOT="/path/to/Elisa-compiler"   # default: ../Elisa-compiler
bash build.sh            # release (-O2); --debug for -O0
bash test/run_all.sh
```

The build writes schema-version 3 `build/manifest.json` with source, toolchain,
and build-pipeline fingerprints, compiler/frontend revision, linker, target,
and selected profile. Compiler source filenames are stable for identical
inputs because builds reuse a content-addressed read-only source snapshot.
Freshness checks reject changes to `build.sh`, `project.json`, or
`scripts/build_hashes.py` until the server is rebuilt.
See `docs/development.md` for the supported profiles, why the stage1 self-hosted
compiler is not used, and how to record a fresh Darwin/Linux host-validation
report with `scripts/platform_validation.py`.

## Running

Point your editor at `build/elisa-lsp`. It reads LSP frames on stdin and writes
them on stdout; logs and compiler chatter never go to stdout.

For bounded diagnostics, set `ELISA_LSP_LOG_LEVEL=info` (or `debug` for
document generation events). Stderr output is capped by
`ELISA_LSP_LOG_MAX_BYTES` (65,536 bytes by default), and never includes source
text or URIs. The private `$/elisa/status` request reports the active limits,
compiler/frontend contract, protocol compatibility, and logging budget without
inspecting workspace files.

Headless performance measurements run without VS Code or Electron:
`python3 test/bench.py --out bench/results.json`. The harness refuses a stale
LSP artifact; rebuild after source changes. Add
`--dimensions source_size,symbols,unicode_density,edit_burst` for the opt-in
one-axis corpus, or `--dimensions dependency_fanout` for the explicitly
labelled multi-document surrogate while project dependency resolution remains
unfinished. `--allow-stale` is diagnostic-only and must not be used for
comparisons.

For opt-in per-stage diagnostics, set `ELISA_LSP_TIMINGS=1` and use the
headless `test/timing_test.sh` probe; timing output is bounded and never
requires VS Code or Electron.

JetBrains (LSP4IJ): configure a language server for `*.elisa` with the command
`/absolute/path/to/build/elisa-lsp`. The client palette in
`docs/highlight-palette.md` maps the 48 token types.

Generic clients (Neovim, VS Code, Emacs): any client that accepts a stdio LSP
command works. The server negotiates UTF-8 positions only when the client
offers it first, otherwise UTF-16. See `docs/troubleshooting.md` if startup or
features misbehave.

## Limitations

- Cross-file project analysis is incomplete: dependency invalidation,
  unsaved include/module overlays, and workspace-wide diagnostics are not
  implemented yet.
- Analysis is synchronous: a large edit blocks other requests until analysis
  completes. The current 5,000-function benchmark still takes several seconds
  for a clean open on the recorded development host.
- Definition and references support a narrow, safe subset. References return
  same-document locations only for unique top-level unqualified functions;
  cross-file search, overloads, shadowed names, and module members are not
  resolved. Completion currently returns `isIncomplete: true` and suggests
  same-file declarations, parameters, and declaration-backed locals within
  function and nested indentation blocks; local visibility ends at an outdent.
  Imports, members, workspace results, parser-provided scope ranges, and
  context-sensitive recovery remain open. Rename is
  limited to exact same-file parameters and locals; wider symbol and type
  renames await complete symbol identity.
- The line-start index is rebuilt by provider operations rather than retained
  on each document snapshot; repeated position queries and incremental editing
  still have room for optimization.
- Custom semantic-token names need a client palette. See
  `docs/semantic-token-schema.json` and `docs/highlight-palette.md`.

## Documentation

- `docs/development.md` — toolchain, build, tests, and the module contracts
  (transport, coordinates, sync, diagnostics, storage).
- `docs/workspace-and-configuration.md` — workspace roots, include-path
  ownership, unsaved-buffer precedence, settings precedence, and URI schemes.
- `docs/feature-manifest.json` — implemented methods and their tests.
- `docs/unsupported-constructs.json` — compiler-rejected spellings and
  compiler-accepted constructs that current LSP providers deliberately decline,
  with separate regression ownership and compiler provenance.
- `docs/semantic-token-schema.json` — the token legend and standard fallbacks.
- `docs/highlight-taxonomy.md`, `docs/highlight-palette.md` — the token
  taxonomy and colors.
- `docs/known-issues.md` — release-facing supported/experimental/unavailable status.
- `docs/troubleshooting.md` — common failures and what to check.
