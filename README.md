# Elisa LSP

A language server for the Elisa language that speaks LSP over stdio. It embeds
the real Elisa compiler frontend for lexing, parsing, and semantic checking, so
diagnostics and highlighting come from the compiler itself rather than
re-implemented rules.

## Status

Early but honest. The foundation — transport, lifecycle, document versioning,
coordinates, diagnostics, semantic tokens — is implemented and regression
tested (see `test/`). Navigation and editing features are being added only as
the compiler exposes trustworthy symbol identity.

| Capability | State | Notes |
|---|---|---|
| `textDocument/semanticTokens/full` | Working | 48 Elisa-specific token types; UTF-16 or UTF-8 per negotiation; multiline spans split per line |
| `textDocument/publishDiagnostics` | Working | Exact compiler ranges, versioned pushes, dedup + cap, related locations for redeclarations |
| `textDocument/documentSymbol` | Working | Flat `SymbolInformation` or hierarchical `DocumentSymbol`; respects `symbolKind.valueSet` |
| `textDocument/foldingRange` | Working | Indentation regions, comment runs, doc blocks; line-only |
| `textDocument/hover` | Partial | Loop-header capture lists only; general hover awaits exact occurrence identity |
| `textDocument/didOpen` / `didChange` / `didClose` | Working | Full synchronization only; multi-change lists validated transactionally |
| Lifecycle (`initialize`/`shutdown`/`exit`) | Working | Explicit state machine; correct exit codes; `serverInfo` |
| Navigation, completion, rename, formatting | Not implemented | Deliberately gated until symbol identity is exact |

Capabilities are advertised only when implemented and tested; see
`docs/feature-manifest.json` for the authoritative status.

## Build

Requirements: macOS or Linux, a **stage0** `elisacore` compiler, an adjacent
Elisa compiler checkout (for the frontend include), `clang`, and `python3`.

```bash
export ELISAC="$HOME/.elisac/elisac-stage0"
export ELISA_COMPILER_ROOT="/path/to/Elisa-compiler"   # default: ../Elisa-compiler
bash build.sh            # release (-O2); --debug for -O0
bash test/run_all.sh
```

The build writes `build/manifest.json` recording the compiler revision, LSP
revision, clang version, and target. See `docs/development.md` for details,
including why the stage1 self-hosted compiler is not used.

## Running

Point your editor at `build/elisa-lsp`. It reads LSP frames on stdin and writes
them on stdout; logs and compiler chatter never go to stdout.

JetBrains (LSP4IJ): configure a language server for `*.elisa` with the command
`/absolute/path/to/build/elisa-lsp`. The client palette in
`docs/highlight-palette.md` maps the 48 token types.

Generic clients (Neovim, VS Code, Emacs): any client that accepts a stdio LSP
command works. The server negotiates UTF-8 positions only when the client
offers it first, otherwise UTF-16. See `docs/troubleshooting.md` if startup or
features misbehave.

## Limitations

- Single-file analysis: `include`/module resolution and unsaved-dependency
  awareness are not implemented yet.
- Full document sync only: ranged/incremental `didChange` entries are rejected
  rather than misinterpreted.
- Hover is the loop-header specialization only.
- Analysis is synchronous: a very large edit blocks other requests until it
  completes. Large files are usable but not yet instant.
- Symbol identity is line/name based; navigation and rename are intentionally
  unadvertised until the frontend exposes exact occurrence spans.

## Documentation

- `docs/development.md` — toolchain, build, tests, and the module contracts
  (transport, coordinates, sync, diagnostics, storage).
- `docs/feature-manifest.json` — implemented methods and their tests.
- `docs/semantic-token-schema.json` — the token legend and standard fallbacks.
- `docs/highlight-taxonomy.md`, `docs/highlight-palette.md` — the token
  taxonomy and colors.
- `docs/troubleshooting.md` — common failures and what to check.
