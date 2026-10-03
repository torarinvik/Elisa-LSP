# Troubleshooting

## Build failures

**`error: no Elisa compiler found.`**
`build.sh` looks for `$ELISAC`, then `$HOME/.elisac/elisac-stage0`, then
`$HOME/.elisac/elisac`. Set one explicitly:

```bash
ELISAC="$HOME/.elisac/elisac-stage0" bash build.sh
```

**`error: ... is a stage1 self-hosted compiler.`**
The latest fresh stage1 product at compiler source fingerprint `ecd23…`
declines 1,887 functions in the LSP compilation unit before object emission at
`-O0`, `-O1`, and `-O2`. Use the supported stage0 backend for release builds
while the compiler backend issue is unresolved; see `docs/development.md` for
exact product and source fingerprints.

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
4. **Semantic tokens look colorless.** Check the initialize response's
   `semanticTokensProvider.legend`. Clients that omit semantic-token
   capabilities or advertise the complete Elisa list receive the custom
   48-type legend; other clients receive the standard subset they advertised.
   The mapping is documented in `docs/semantic-token-schema.json`. A client
   that advertises only unsupported categories may receive an empty token list.

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

- `python3 test/bench.py --sizes 100,1000 --out /tmp/elisa-bench.json` records
  open, edit, cached-token, hover, and startup measurements with build and host
  provenance. CPU and peak RSS cover each server process, including setup; the
  reported wall time covers the named operation. These measurements are
  baselines, not pass/fail thresholds.
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
- **Ranged `didChange` entries** use the incremental sync mode advertised by
  the server. Each range is interpreted against the snapshot produced by the
  preceding change in the same notification; malformed, out-of-bounds, or
  encoding-splitting ranges reject the complete notification. Check that the
  client sends monotonically increasing document versions and uses the
  negotiated UTF-16 (default) or UTF-8 character units.
- **Duplicate `initialize`** after a successful one returns `InvalidRequest`.
- **Session timeout settings** use
  `initializationOptions: {"elisa":{"analysisTimeoutMs": N}}` or a
  `workspace/didChangeConfiguration` notification with the same namespaced
  shape. `N` must be an integer from 100 through 300,000; invalid initialize
  values return `InvalidParams`, while invalid notifications leave the last
  accepted value unchanged. The effective value is visible in the private
  `$/elisa/stats` result under `configuration.analysis_timeout_ms`.

## Reporting a bug

Include:

1. Output of `python3 -c "import json;print(json.load(open('build/manifest.json')))"`.
2. The client name/version and which capabilities it negotiated (the
   `initialize` result).
3. A minimal Elisa source file that reproduces it.
4. Sanitized server output. The server does not log by default; if you add
   logging, keep it on stderr and strip any source text before sharing.
