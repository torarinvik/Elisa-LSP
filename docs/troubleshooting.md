# Troubleshooting

## Build failures

**`error: no Elisa compiler found.`**
`build.sh` looks for `$ELISAC`, then `$HOME/.elisac/elisac-stage0`, then
`$HOME/.elisac/elisac`. Set one explicitly:

```bash
ELISAC="$HOME/.elisac/elisac-stage0" bash build.sh
```

**`error: ... is a stage1 self-hosted compiler.`**
The stage1 backend declines constructs this server uses (range matches,
packed-enum matches). Use a stage0 `elisacore`; see `docs/development.md`.

**`error: Elisa compiler checkout not found.`**
The frontend is included from an adjacent checkout. Set:

```bash
ELISA_COMPILER_ROOT="/path/to/Elisa-compiler" bash build.sh
```

**Frontend API drift** (errors mentioning renamed fields or missing
functions in `src/semantic/`): the pinned frontend changed. Run
`bash test/frontend_contract_test.sh`; it fails in the adapter's terms
(`src/frontend_adapter.elisa`) and names the broken assumption. Update the
adapter and bump `frontend_contract_version`, or pin the compiler revision
recorded in `build/manifest.json`.

## Server starts but the editor shows nothing

1. **Was the file opened?** Diagnostics and tokens require
   `textDocument/didOpen`; the server does not scan the workspace.
2. **Did `initialize` succeed?** Check the `initialize` response for
   `capabilities`. If it is an error, the client sent a malformed request.
3. **Position encoding mismatch.** The server uses UTF-16 unless the client
   offers `general.positionEncodings` with `utf-8` first. If ranges look
   shifted, the client and server disagree about encoding — report both
   versions with a minimal file.
4. **Semantic tokens look colorless.** The legend is Elisa-specific
   (48 types). A client that only knows standard token types needs the
   `standard_fallback` mapping in `docs/semantic-token-schema.json`; such
   clients are not yet auto-negotiated (tracked as H01).

## The server exits unexpectedly

Framing corruption is a controlled nonzero exit, not a crash. The server
never scans for a resynchronization point, so a malformed frame ends the
session. If this happens with a real editor, capture the first frames the
client sent (a client bug or a proxy rewriting the stream is the usual
cause). Clean EOF between messages exits with status 0; `exit` without a
prior `shutdown` exits 1, per LSP.

## Editing feels slow

Analysis is synchronous and runs the full frontend on every `didChange`. A
multi-thousand-line file can take a moment. Things to check:

- `python3 test/bench.py --sizes=100,1000` reports per-size timings with
  your machine's provenance.
- `$/elisa/stats` (a private request) returns `storage_bytes`, `live_bytes`,
  `documents`, `open`; storage should plateau, not grow across editing.
- Large generated files (very long lines, thousands of declarations) are the
  slowest case; the frontend check dominates.

## Malformed client configuration

- **Unknown methods** return `MethodNotFound` once initialized; notifications
  are ignored silently. `ServerNotInitialized` before `initialize` completes.
- **Malformed versions** (fractional, overflowing, or non-numeric
  `textDocument.version`) reject the whole notification rather than mutating
  the document; fix the client to send integers.
- **Ranged `didChange` entries** are rejected because only full sync is
  advertised. Configure the client for full document synchronization.
- **Duplicate `initialize`** after a successful one returns `InvalidRequest`.

## Reporting a bug

Include:

1. Output of `python3 -c "import json;print(json.load(open('build/manifest.json')))"`.
2. The client name/version and which capabilities it negotiated (the
   `initialize` result).
3. A minimal Elisa source file that reproduces it.
4. Sanitized server output. The server does not log by default; if you add
   logging, keep it on stderr and strip any source text before sharing.
