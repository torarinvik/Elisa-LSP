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

`bash build.sh --debug` builds the `debug` profile (`-O0`) and
`bash build.sh --release` builds the `release` profile (`-O2`). `BUILD_PROFILE`
selects a named profile only when no command-line profile was supplied;
command-line options take precedence. `bash build.sh --profile O1` selects the
`O1` profile. The profile names and opt levels come from `project.json`, and
the build rejects unknown profiles or invalid opt levels.

## Current compiler and stage1 optimizer candidate

As of 2026-10-06, the LSP release uses the latest clean `Elisa-compiler`
frontend on `origin/main`, commit
`23a0e16a854cddec3016746a0cb9480db0c4db22`, with source fingerprint
`7338d4fedc8e35739a974a0c289159d0fa3cbc54a9657e827029d6b8ac734ffb`. The
supported Go stage0 backend is built from current Elisa-core `origin/main`,
commit `4a68f508b90634b548f5e0728da4147853560248`, executable SHA-256
`615cb2ff887a06147579048ee4319dd7d3def55af0c13f7eae208721e3025b74`. Its
build metadata reports Go 1.27.1 and a clean source tree. The compiler binary
and frontend source are pinned independently in `build/manifest.json`; release
objects use `-O2 -fno-builtin -Wl,-v`.

This current-main pair supersedes the earlier clean d4 optimization-integration
snapshot (`d4b40e36770d89973de1b8df93f8e0bcd091ae6a`, fingerprint
`32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`). That
snapshot added owner-indexed lookup chains, memoized O(1) collection-stack
lookup, and narrower enum/module visits, and its measurements remain a useful
historical comparison. The d4 values below are historical records; current
compiler compatibility and release evidence must use the manifest-pinned
23a0/4a68 tuple.

The initial d4 refresh artifact was built at 2026-10-06T01:19:00Z with
-O2 -fno-builtin -Wl,-v. The supported Go stage0 compiler source revision is
f84b9c1034f708f69d048bd6cafb813e88c8210f and its executable SHA-256 is
5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e. The LSP
input hash is
290af215e13e0afaac86096fd00937bd7e9b68511d3b9165f80c14a1a58164e6; the
624-file compiler-emitted include closure has SHA-256
7c2004430d029ca074e5fa0f759b0ec005249defbcb7607c61917c9ddbf6f269, the
object SHA-256 is
0dacf17b346e92d9188e814d8b4d83c9d950aa715a930e30289e88d8ce19423c, and the
executable SHA-256 is
526f86af0ef327308b81fc4245e057f41a4f58ebe24ff86d9e01c482d1155ac0. Strict
freshness passes, compiler_dirty=false, and the canonical test/run_all.sh suite
passed 81/81 on this exact compiler and LSP input. The compiler upgrade added
diagnostic kinds, so src/diagnostic_codes.elisa now covers 641 kinds and
docs/diagnostic-span-coverage.json records 1,093 constructors; the
unsupported-language audit still passes all 19 compiler probes. The stage0
build emits new struct-padding and effect-analysis warnings for included
compiler/LSP source; these are visible in the build output and remain to be
triaged. A controlled source-compiler comparison used the same current LSP implementation and stage0 binary against clean compiler snapshots 6b475d8 and d4b40e3; the only LSP source difference is the generated diagnostic adapter matching 640 versus 641 compiler kinds. On the 5,000-function, 302,780-byte fixture with three independent samples, d4b40e3 medians were 0.925 s clean open, 0.787 s edit, and 0.829 s hover, versus 1.108 s, 1.212 s, and 0.960 s on 6b475d8. Cached-token median was 0.035 s versus 0.029 s, and process peak RSS was 113.5 MiB versus 111.4 MiB. Both 20-cycle storage soaks ended with 0 tracked live bytes. The measurements suggest faster open/edit/hover in this workload, with a 6 ms cached-token increase and 2.1 MiB higher peak RSS; three samples on one Darwin host are directional evidence, not a stable release threshold. Raw reports: bench/current-compiler-d4b40e3-2026-10-06.json and bench/compiler-6b475d-control-2026-10-06.json. Stage1 parity and current-pin Linux validation
remain open.

The latest release artifact was rebuilt at `2026-10-06T05:33:36Z` against the
clean d4 compiler/frontend snapshot and the supported Go stage0 binary
(`5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`) with
`-O2 -fno-builtin -Wl,-v`. Its manifest records compiler source fingerprint
`32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`, LSP
inputs `38c1ccfb6e6da468cb066e479ef7658ca52b095b8d42ab203989a6738ea9d93f`, a
624-file include closure
`43340afc74e1305d1face12a4cc0053abf0913dee74adb6c506d0aa5223ff177`, object
SHA-256 `e235047b2cf23525dffe5815dc43d5e1051bdb649ad24fef4a452a2165183f50`,
and executable SHA-256
`f0fff9b4e94516dbe7e6b91f2cc893468c125a8cb460ed6b2928d97f9a808690`. The
compiler source is clean and strict freshness passes. This build moves analysis
to an isolated one-shot child while the parent continues to accept framed
input, cancellation, edits, status requests, and shutdown; it publishes only
results matching the current document snapshot. Hover requests wait for a
pending semantic snapshot while retaining lexical fallback behavior when
analysis is unavailable. The canonical suite passes `81/81` against this exact
artifact and manifest-pinned compiler/frontend inputs.

After the references-sort and document-highlight follow-up, the current LSP
artifact was rebuilt at `2026-10-06T01:57:18Z` against the same clean d4
compiler/frontend snapshot and supported Go stage0 SHA-256
`5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e` with
`-O2 -fno-builtin -Wl,-v`. Its LSP input hash is
`2804d1ea45a7eab26795f36da51578e0aed73276d9be9d17163d4d25e6101b3f`, the
624-file include-closure hash is
`78eeb60f329f6124a65c288e56411c4f21fc8d9aad9865ad1609229d7f7fa152`, object
SHA-256 is `ecc076437cf4c9127e4847ba752aed552f0c9ada896d3405fdb2ea2782211924`,
and executable SHA-256 is
`95257d0cd3ef71a606ee7155a98de331fcc3872ddfa6e2776cf51e0517279790`. Strict
freshness and the full canonical suite pass on this exact artifact (`81/81`).
The compiler source is clean; the LSP input is marked dirty in the manifest
because the implementation is still in the working tree.

The current artifact adds explicit search-coverage metadata to the private
`$/elisa/status` response. It was rebuilt at `2026-10-06T02:12:55Z` from that
same clean d4 compiler snapshot using the supported stage0 SHA-256
`5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e` and
`-O2 -fno-builtin -Wl,-v`. Its LSP input hash is
`7a155e8d642d7ccdf923e7e67b67f42e6227bbea5ecc1b7078b87d6d989e96b2`; the
624-file include-closure hash is
`9578cd683e3a14ef85ee02e9f7ea267709ddced506c5368bf3a2c003a2f98d4d`, object
SHA-256 is `aa20c8da27cc3c0109e2736dff7d3cb88c8766b66b562f848c02d51bb5ff81ed`,
and executable SHA-256 is
`26d9ad374c6df1b640365cab3189665b85736294d9df62a800e6eb61ce115b71`. Strict
freshness and the complete canonical suite pass for this exact artifact
(`81/81`).

After adding the H04 immutable-constant name index, the latest d4 release was
rebuilt at `2026-10-06T02:39:06Z` using the same clean compiler snapshot and
supported stage0 SHA-256
`5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, with
`-O2 -fno-builtin -Wl,-v`. Its LSP input hash is
`f9d1a3143d58a0cf7a8c9b0de5e735685aa08cbd0262f08630d0316a69ba2a92`; the
624-file include-closure hash is
`09b6568c62e7ed97a517469a4296eb87043ea512a846862f4da795cfcfc9aa1f`, object
SHA-256 is `c1ce202fdf85bdbbbcce1e3f5e86eb96b49e9651742e24c0fee07e04aba65a81`,
and executable SHA-256 is
`be2ed3ade90e60d9e5b078097014312cfcb851fe8c5521b7690329c0b60cc182`. Strict
freshness and the canonical suite pass on this exact artifact (`81/81`). The
new index replaces per-identifier scans of immutable-constant names with one
per-analysis hash-chain build and exact-byte collision checks. Its matched
three-sample benchmark records open-to-diagnostics medians of 430.763 ms to
235.458 ms at 2,048 constants and 1,663.331 ms to 898.263 ms at 4,096; these
measurements include frontend analysis and cache construction and are
directional results from one Darwin/arm64 host. See
`bench/semantic-token-const-index-2026-10-06.json`.

The current H02 slice indexes compiler DefinitionReference edges once and uses
exact source positions to classify resolved function references before
contextual-keyword fallbacks. Tests cover a function named get in an f-string,
a function named fn called as a value, and fn(...) -> T => ... lambda syntax.
Nested f-strings expand recursively to depth 16; remaining inner text is emitted
as one string span to keep semantic-token processing bounded. The compiler
occurrence index includes the tested nested parameter use: focused regressions
verify definition and references from that use, plus exact declaration/use
rename edits under UTF-8 and UTF-16. Broader pattern-binding and cross-file
provider parity remain open. Completion offers exact declaration-backed
locals in nested indentation blocks while suppressing them after an outdent or
in a sibling branch; the compiler does not yet expose scope-end positions.

The previous stage1 compatibility probe is recorded in
`bench/compiler-upgrade-latest-541-stage1-2026-10-05-build-only.json`; it ran on
an earlier compiler source fingerprint and declined 2,108 backend operations
before object emission. It does not qualify stage1 for source fingerprint
`8188a8bc`.

**Previous stage1 probe (2026-10-01, superseded):** Stage1 product SHA-256
`c9120725bde202e70ea9ff94c9b87ab2026770eb5b29e95bfc1bc285f76eb9cf` passed
freshness for that older compiler tree, but a disposable build-only probe
declined 1,918 backend operations before object emission. Tests and benchmarks
were skipped. The report is
`bench/compiler-upgrade-local-d8b5-stage1-2026-10-01-build-only.json`.

A previous full stage1 gate on the earlier `ce52ba2c` compiler snapshot passed
its stage0 build, canonical suite (`81/81`), and benchmark, then declined 1,905
operations in the candidate backend. That report and its benchmark data are
historical for the earlier input and should not be read as current measurements.
The gate's three-sample p95 baseline used 100 functions / 5,680 bytes and 1,000
functions / 58,780 bytes; the raw report is
`bench/compiler-upgrade-latest-main-ce52-stage1-2026-10-01.json`. Its original
normalized p95 map was empty due to an extractor bug, now fixed and
regression-tested. The harness fails closed when measurements are missing or
scenario sets differ. No optimizer speedup is claimed without a controlled
same-input comparison.

Earlier Darwin/arm64 stage0 artifact (2026-09-29, superseded): the release build completed at 2026-09-29T21:55:31Z
with O2, no-builtin lowering, and the verbose linker probe. Its 577-file
compiler-emitted include closure has SHA-256
13baf101c64fd6cc23586554c3a65cfd446d58a2faf1a49ea61dc8b1cfafc7c7; the object
SHA-256 is 5b390c506bad330416d8369b24e7cc9e8de980179370501fc90d0bf4743372a1,
and the executable SHA-256 is
d363102b69c5eb8bd0f52708ace99d7a87f916317f56798fc44a84c0288ff10c. The
freshness check passes and the canonical suite passes 78/78.

Earlier Linux/aarch64 stage0 artifact (2026-09-30, superseded): the release build completed at
2026-09-30T01:02:04Z. Its object SHA-256 is
f39e96b56c64700362a52ef6ad784f754826c16332250ca9be7db1e79971479c and its
executable SHA-256 is
0b08ee63a2e6f99303db102368a25c8cc972c2a11a7db29216fb9767222697f9. The
platform report records clang 19.1.7 targeting aarch64-unknown-linux-gnu, the
same 577-file include-closure hash, a passing freshness check, and 78/78
canonical tests with no failure markers:
bench/platform-validation-Linux-aarch64.json.

After the D01 document-record regrouping, another Darwin/arm64 stage0 artifact
was built at `2026-09-30T01:57:09Z`; it is superseded by the current artifact
above. It used compiler source fingerprint
`4c48ea7e85d65af62bdfc83f3e351151f1f354d4ef9e735d9ea755751b8fdb98` and stage0
binary SHA-256 `8982ace0e827d99ab1ac5539a3bce2a7896d1950fed8ef72d2d2bab6eeebbfd8`.
Its LSP input hash is
`75baf33a62670e7b6693d03e23ab2bc3ff26d6d5ab0afabf8ce49e1a91e26cff`, its
577-file include-closure hash is
`10bd2d6000a591638480596faaaff0e0ab897f772316cf5e1b47240345b98e78`, its
object SHA-256 is `24e8f11bbc69775eea90e442b0cf41868cfb3a3a5b450e86660aaaab75d99b53`,
and its executable SHA-256 is
`b62ecea98d54fb6271b84fb875f353142d43febf62db1d100f29e30a189bbb7d`. Strict
freshness passes. Eighteen focused D01 and provider regressions pass on this
input, including forced URI collisions and storage compaction. The canonical
`bash test/run_all.sh` suite also passes 78/78 on this exact Darwin input. Its
first run exposed a stale flat-field match in the failure-injection test; that
fixture now mutates the nested fields, passes alone, and passes in the canonical
rerun. The Linux 78/78 report above uses the preceding LSP input hash; rerun the
Linux host gate before assigning full cross-platform release status to this
newer input.

Historical stage1 compile probe (2026-09-30, superseded by the current gate
above): the product was `../Elisa-compiler-latest/bin/elisac-stage1`, SHA-256
017f7ccac250c6780c7cbd6ada877be81d899b163a37bc7217b1d5ec1240b6b4. The
compiler freshness assertion passed for that compiler snapshot. That product
included helper-scratch reuse,
counted-fill reserve inference, bounded stack placement, and optional proven
alias-scope optimizations. A compile-only run of the disposable LSP upgrade gate
still fails to emit an object. The five diagnostics are two u8-versus-sview
argument errors at compiler parser_machine_laws.elisa:62, a sview field given
an integer at compiler check_call_argument_exclusivity.elisa:397, an invalid
zero representation for a non-null reference at src/frontend_adapter.elisa:304,
and an Abort effect target that is not a parameter at src/main.elisa:1380.
The record is bench/compiler-upgrade-latest-stage1-compile-probe-2026-09-30.json.
Because the candidate produces no LSP object, it has not reached protocol parity
or latency/RSS measurement. Keep the tested stage0 backend until a stage1 build
emits the object, passes the complete suite, and meets the measured performance
budget; freshness alone does not qualify its optimizations.

The earlier disposable stage0 build for source fingerprint `c009…` reported
73/75 tests, while the direct artifact for that older tuple passed 75/75. Its
gate report retained only the bounded log tail, so its failed test names cannot
be recovered. The gate now records failed test names before temporary logs are
removed. Do not interpret the old disposable baseline's partial result as
stage1 parity evidence.

Keep the supported release build on the configured stage0 path until a fresh
candidate builds and passes the complete protocol/provider suite and calibrated
benchmarks. The upgrade gate records compiler/source/artifact identities and
benchmark distributions; run it without skip options for qualification.
`ELISA_COMPILER_ROOT` selects included frontend and standard-library sources,
while `ELISAC` selects the backend. Probe stage1 only in disposable copies.
Earlier
75/75 results in historical progress entries refer only to their dated source
and compiler tuples.

The previous historical artifact was built at `2026-09-15T05:35:07Z` with
frontend revision `8d7db0561d0f72c1f548fa6a73d071c86b2fe57f` and stage0 SHA-256
`51f5f5f1f33c65f71bb6a17acae8fcc45c74009ff27f6209a93a06ecd3d39b62`. Its
manifest records LSP input fingerprint
`e537bb1cd86f25eb18ec89417951e2aabb563ef7cca014af43d2c3241a1f5be4`, compiler
source fingerprint `429c49c0960305dd9e559437c64d331548a83b7d0e4f082f73307954a936c52b`,
and artifact SHA-256
`3b21df091a4141519cebdc2cc9e8db7d27b0ee37231d7b5abfa107fb2ad3087f`. Treat
these as historical provenance, not as a fresh artifact for the latest compiler.

The previously fully-suite-verified release artifact was built at `2026-09-29T01:46:10Z` on
Darwin/arm64 with `-O2 -fno-builtin -Wl,-v`, compiler/frontend revision
`54360bf68398b4da8d63b82a3ad2979667798aa2`, compiler-source SHA-256
`ecd23c2e0a2f0ce74760bbf0e4200f06fa3405c5af9383ab70b8d13e2e4b4eb3`, and the
frozen stage0 copy SHA-256
`850a8979e17bd28f1cb91e3c88665f6707b71d83e263f280dbd152458184ea6e` (Go
1.27.1, source revision `e42bbdfe8a1b8123c3c4bfd096d64eb4c97c8b11`). Its
LSP-input SHA-256 is
`8bfc1e7b361e1ea2cf43dbedadd199d73199ad232fc55d4430766a226d8609fc`, object
SHA-256 `fdb478a3f4efc7c991b528e4afa83065429df8136e87843d7fef5c7b40bf390e`,
and executable SHA-256
`a8bf51ecb72fc2d518f651720bdc80ca10d47e37a1587f8c27f2047f0115cba6`. The
manifest's compiler-emitted include closure contains 577 files and has
SHA-256 `5a04387c3f3714e6d1b5d8f686b83941f8e0874f8cacb7440e0f4c45e3b25a27`.
The manifest freshness check passed. The canonical suite passed `76/76` for
that exact compiler/input/artifact tuple, including the 19-probe
unsupported-construct audit, frontend-contract v6, worker fault/isolation,
failed-analysis recovery, and manifest tests. The later expanded
storage-reclamation test passes separately on both release and debug builds.
One later canonical rerun against the 01:46 artifact under concurrent compiler builds ended `pass=73
fail=3`, with timeouts in the client fragmentation/pipelining self-test, the
output-stall subprocess test, and the expanded storage soak. All three passed
when rerun individually (storage on both release and debug); the cause of the
suite-only timeouts is unconfirmed. Repeat the complete suite on an otherwise
idle host before treating that rerun as a stable all-green result.

The 2026-09-29 artifact hashes, stage1 probes, and 77/77 suite entries retained
in IMPLEMENTATION_PLAN.md are historical checkpoints for their exact immutable
source tuples. The compiler source fingerprint then moved through ecd23…,
df93…, and bfa304… during API compatibility work; those records do not describe
the current checkout. Use the 2026-09-30 source fingerprint, stage0 artifacts,
and 78/78 results in the current section above for release claims.

The benchmark record bench/stage0-current-2026-09-28.json is a historical
three-process control for the previous c009… source/artifact tuple: clean-open
median 2.576 s, edit 2.766 s, cached semantic tokens 0.623 s, and hover 0.790 s.
Its sample ranges are wide; do not treat those values as a threshold or as a
measurement of the current artifact.

The disposable upgrade gate is:

```bash
python3 scripts/compiler_upgrade_gate.py \
  --baseline-compiler "$HOME/.elisac/elisac-stage0" \
  --baseline-frontend "$PWD/../Elisa-compiler" \
  --candidate-compiler /path/to/candidate/elisac-stage1 \
  --candidate-frontend /path/to/candidate/Elisa-compiler \
  --out bench/compiler-upgrade-gate.json
```

It builds each candidate in a temporary copy, runs the canonical protocol and
provider corpus, collects multi-sample benchmark distributions, and writes
compiler/source/artifact provenance, bounded log tails, and failed test names
to the report. The stage1 opt-in
used internally by the gate is disposable; `build.sh` still rejects a stage1
name for ordinary release builds. A nonzero gate result, a compile/test failure,
or a configured latency regression leaves the supported stage0 artifact in
place.

## Unsupported language constructs (B03)

`docs/unsupported-constructs.json` is the machine-readable boundary between
compiler language support and LSP provider support. It deliberately has two
lists. `compiler_rejected` contains removed spellings and invalid language
shapes that the current compiler must reject with a directed diagnostic.
`lsp_provider_limits` contains constructs that the compiler accepts but the
listed providers do not yet identify safely, such as cross-file module members,
overloads, shadowed bindings, and member or variant targets. Those providers
return their documented `null` or `[]` no-match shape; semantic tokens and
compiler diagnostics can still handle the same source.

At the protocol boundary, compiler parse/check findings and recoverable syntax
remain normal analysis snapshots with the compiler's diagnostics. Provider
limits do not create synthetic compiler diagnostics: the affected provider
returns its documented no-match result, while other safe providers may still
answer. A frontend, worker, or retained-snapshot contract failure is a server
analysis failure instead; the LSP clears derived caches, marks that version
`Failed`, and returns JSON-RPC `InternalError` for analysis-backed requests.
The next accepted version can recover normally. `test/incomplete_source_test.sh`,
`test/unsupported_constructs_test.sh`, and
`test/failed_analysis_request_test.sh` cover these distinct paths.

The lists must not be collapsed into one generic “unsupported” bucket. A
compiler probe failure is frontend or toolchain drift and must be investigated
before changing an LSP claim. A provider golden-test failure with unchanged
compiler provenance is an LSP regression. The inventory records the exact
frontend source fingerprint and backend binary used for verification, and the
test runner compares both with the fresh build manifest so a probe cannot
silently use an older compiler.

The current inventory was re-audited on 2026-10-01 against local compiler HEAD
`d8b5d305ec99a9d2238e035b871d9fd4e9835603`, source fingerprint
`56868fba124d5f56905635d2529b3e70acbd22033a0a3ce5ff7225330cbb5393`, and
manifest-pinned stage0 SHA-256
`2fc31c130863b41ac07d250c4bfa25ee5c73f45f8faefb8e696b5bbf7176c408`. All 18
compiler-rejected entries (19 probes) retain their expected diagnostics. The
view-provenance commit from `origin/main` is included in this newer source
snapshot; the complete inventory provenance is recorded in
`docs/unsupported-constructs.json`.

Run the focused audit directly with the same toolchain as the server:

```bash
export ELISAC="$HOME/.elisac/elisac-stage0"
export ELISA_COMPILER_ROOT="$PWD/../Elisa-compiler"
bash test/unsupported_constructs_test.sh
```

When the compiler or its optimised backend changes, rebuild the server first,
rerun this test against the compiler pinned by `build/manifest.json`, and update
the recorded provenance only after every probe and provider test passes. A
construct may move from the compiler list to a provider-limit list only when
the compiler now accepts it; it may move out of the provider list only after a
provider has exact semantic identity, positive and negative tests, and a
manifest entry.

## Host-platform validation

`build.sh` accepts Darwin and Linux as validation candidates, but the operating
system name alone never proves support. Run the host validation command on each
machine that is being considered for release:

```bash
python3 scripts/platform_validation.py \
  --compiler "$ELISAC" \
  --frontend "$ELISA_COMPILER_ROOT" \
  --build --tests \
  --out "bench/platform-validation-$(uname -s)-$(uname -m).json"
```

The runner executes a fresh release build, checks the resulting artifact with
`scripts/check_build_freshness.py`, and runs the canonical `test/run_all.sh`
suite using the same explicit compiler and frontend inputs. It records the host
OS/architecture, clang target and version, compiler/frontend hashes, manifest
identity, bounded command tails, and elapsed times. Reports are marked
`validated` only when all three gates pass: the fresh build, the freshness
check, and the full test suite. Omitting either `--build` or `--tests` produces
an `incomplete` report; a stale artifact or failed command produces `failed`.
The runner does not cross-compile or infer Linux support from a macOS result.

For CI, add the platform requirement flag to make a job fail if it runs on the
wrong host. Keep one report per OS/architecture with release evidence.
Darwin/arm64 and Linux/aarch64 both have fresh stage0 builds, passing freshness
checks, and canonical suites at 78/78 for the source hashes recorded above. The
newest LSP input has a fresh Darwin build and a canonical 78/78 result; its Linux
host gate remains to be rerun. The Linux report is
`bench/platform-validation-Linux-aarch64.json`.

## Layout

- `src/main.elisa` — stdio framing, dispatch, document lifecycle and analysis orchestration
- `src/documents.elisa` — URI-keyed document records, open-document indexing, source and line-index storage
- `src/json.elisa` — strict-ish JSON values + deferred string decoding
- `src/json_writer.elisa` — shared bounded JSON string escaping for arbitrary byte spans
- `src/diagnostics.elisa` — frontend adapter (`Semantic::check` → publishDiagnostics)
- `src/semtokens.elisa` — token legend, classification, delta encoding
- `src/features/references.elisa` — exact same-document references from retained resolver edges
- `src/features/document_highlight.elisa` — exact function and parameter/local highlights from retained resolver records
- `src/diagnostics.elisa:19` includes the frontend via
  `../../Elisa-compiler/src/semantic/semantic.elisa`. That relative path is the
  pinned-checkout mechanism: it resolves against `ELISA_COMPILER_ROOT`
  (default adjacent checkout). The exact compiler revision is recorded in
  `build/manifest.json` on every build.

## Build details (B01)

- `build.sh` is the supported build entry. `project.json` owns the entry,
  object/executable paths, default profile, and profile-to-opt mapping; the
  script validates those settings and fails instead of falling back to a
  different source or optimization level. Invoke it from any working
  directory. An explicit relative `ELISAC` path is resolved against the
  invoking directory before the build changes directories.
- Compilation and linking happen in a unique temporary directory under
  `build/`, on the same filesystem as the published artifacts. The compiler
  reads a content-addressed source snapshot at
  `build/.elisa-lsp-source-v1.<lsp-sha256>.<compiler-sha256>/source/`; repeated
  builds with identical inputs reuse the same absolute source paths, including
  paths embedded in compiler diagnostics and panic reports. Files and
  directories in that snapshot are read-only. The selected frontend checkout
  is copied into `Elisa-compiler` at the existing `../../Elisa-compiler`
  include location; the live checkout is never rewritten. The snapshot hash is
  checked before compilation and again before publication. The executable,
  object, and manifest are each renamed into place only after compile, link,
  and manifest generation succeed. A compile or link failure preserves the
  last successful artifacts; always honor the build command's exit status
  before running tests. A per-repository OS advisory lock serializes builds
  from staging through promotion, preventing concurrent invocations from
  interleaving the object, executable, and manifest; waiting builds announce
  that serialization.
- Stage0 objects reference optional profiling hooks
  (`elisa_profile_*`); `build.sh` generates a weak-symbol fallback C file and
  links `object + fallback` with host clang (`-fno-builtin`). The runtime
  itself is already inside the object — do NOT link
  `Elisa-compiler/build/runtime/elisacore_runtime.o` (duplicate symbols).
- Every build writes schema-version 3 `build/manifest.json` with a UTC
  timestamp, selected profile and flags, executable/object SHA-256 hashes,
  LSP source-tree hash and revision/dirty-state fingerprint, the compiler
  executable path and SHA-256, compiler checkout revision and source-tree
  fingerprint, frontend entry/revision, clang and native linker versions,
  target triple, OS/architecture, and a build-pipeline fingerprint covering
  `build.sh`, `project.json`, and `scripts/build_hashes.py`. The build checks
  that this fingerprint is unchanged before publishing; the freshness gate
  rejects older manifests and changes to any of those build-defining inputs.
  It also records `include_closure`, the compiler-emitted `-emit deps-json`
  closure for the configured entry as normalized logical paths and per-file
  content hashes. The freshness gate recomputes that same closure when the
  pinned compiler and checkout are available, so edits to unrelated compiler
  sources do not invalidate an otherwise unchanged LSP artifact. Legacy or
  test compilers without `deps-json` use the compiler-matching recursive
  include parser, then a conservative source-tree fingerprint if the graph
  cannot be proven.
  `stage0_provenance` is separate from `compiler_rev` and `frontend_rev`: when
  the selected stage0 is a Go executable and `go version -m` can inspect it,
  the object records its embedded module, source revision and commit time,
  dirty-at-build flag, Go version, and GOOS/GOARCH. Go is only an optional
  metadata reader; a fake, non-Go, or uninspectable compiler still builds and
  gets `metadata_available: false` with the provenance fields set to null.
  The selected compiler's SHA-256 remains the exact identity check either way.
  The object also records the canonical source rebuild command
  `go build -C <stage0-source-root>/compiler -o <stage0-output>/elisac-stage0 ./src`.
  Check out the recorded `source_revision` in the stage0 source repository and
  use the recorded Go version and target to reproduce it. A true
  `source_dirty_at_build` means the revision alone is insufficient to recreate
  that binary; do not confuse it with `compiler_dirty`, which describes the
  separate Elisa frontend checkout. The build does not rebuild stage0 or
  modify either compiler checkout. Dirty-state fingerprints and source hashes
  describe the files used even when either checkout has uncommitted changes.
- Sanitizers are intentionally not claimed as supported: the current stage0
  object-emission CLI exposes no instrumentation flag, and adding sanitizer
  flags only to clang's link step would instrument the fallback C shim but not
  the Elisa object. The manifest records this limitation explicitly.
- An invalid explicit `ELISAC` path fails rather than silently selecting a
  different compiler. Missing compiler checkout or clang also fails before
  compilation with an actionable message. The build checks the selected
  compiler's filename for the known stage1 naming pattern; stage0 remains the
  required backend for this target.

## Testing

- `bash test/run_all.sh` — canonical entry for the full suite. It first runs
  the isolated build-script, POSIX transport, and Python harness checks; it then
  requires a server executable whose artifact, current LSP source/project,
  compiler checkout, stage0, and build-pipeline hashes match the manifest
  before any protocol tests run. Rebuild with `bash build.sh` after a mismatch.
  Tests that compile temporary server variants then use the exact `ELISAC` and
  staged frontend snapshot recorded by that validated manifest, rather than
  silently selecting a different compiler from `~/.elisac` or `PATH`.
  The gate uses
  content fingerprints rather than file modification times, so touching an
  unchanged source file does not invalidate a build. Before launching child
  tests, the runner resolves an existing `ELISA_COMPILER_ROOT` to an absolute
  physical path. Some compiler-backed probes create Elisa files under temporary
  directories, where a relative include root would otherwise resolve against
  `/tmp` rather than the checkout; `test/compiler_root_env_test.sh` covers the
  default, relative-override, and missing-root cases.
- `test/lsp_client.py` — shared framed subprocess client (Content-Length
  framing, typed-ID matching, deadlock-free drain); new protocol tests should
  use it instead of hand-rolled shell framing.
- `test/uri_collision_test.sh` — slower D04 regression that builds a temporary
  source copy with a constant URI hash and checks collision traversal/removal;
  the test transformation never enters the normal server build.
- `test/open_document_metadata_budget_test.sh` — D04 admission regression for
  simultaneous open-document count and aggregate canonical URI bytes,
  including empty overlays and unique-URI churn.
- `test/uri_path_test.sh` — D03 direct URI/path probe for strict percent
  decoding, UTF-8 and space preservation, POSIX authority policy, Windows
  drive spellings, UNC authorities, and unsafe-path rejection.
- Existing shell tests remain supported during migration; they validate
  happy paths + selected regressions, not Unicode/transport/workspace
  conformance (see IMPLEMENTATION_PLAN.md B02).

## Sync policy (D02)

`textDocumentSync` advertises `{openClose, change: 2}`: full **and**
incremental edits. `apply_content_changes` (in `src/main.elisa`) applies a
notification's `contentChanges` in order to a working copy — each ranged entry
is converted against the text produced by the preceding one — and the whole
list is committed only if every entry is well-formed. Entries without a `range`
are full replacements, so full-sync clients still work. An inverted range or
a line index beyond the current document rejects the entire notification
without mutating the document. Per LSP 3.17 `Position`, a character column
beyond an existing line clamps to that line's end; that rule does not make a
nonexistent line an alias for EOF ([Position](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/types/position.md), [Range](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/types/range.md)).
The deprecated optional `rangeLength` is checked against the actual removed
span using the negotiated position encoding (UTF-16 code units by default or
UTF-8 bytes when negotiated). A mismatch rejects the entire notification;
`rangeLength` without `range` is malformed, and the field never supplies or
overrides range endpoints.
`test/incremental_sync_test.sh` is the reference model: a sequenced edit
session must converge to the same analysis as opening the final text fresh.

An unexpected `didOpen` for a URI that is already open is treated as a new
document lifetime: its complete source and version replace the prior snapshot,
and the internal generation advances even if the client reuses the same
version. Clients should still follow the normal open/change/close lifecycle;
this recovery policy prevents old asynchronous work from crossing a duplicate
open boundary. `test/documents_test.sh` covers a same-version duplicate open
whose contents differ.

Saving is intentionally a no-op for the current standalone, open-buffer server.
The advertised sync profile omits `save`, `willSave`, and `willSaveWaitUntil`,
so clients should not send `textDocument/didSave` or `textDocument/willSave`.
If either notification arrives anyway, it is ignored: optional `didSave.text`
does not replace the editor overlay, trigger analysis, or publish diagnostics,
and the server does not read or write the file. The accepted buffer remains
authoritative until a later `didChange` or `didClose`. Disk-backed project
indexing must define save and file-watch invalidation before using saved files.
`test/documents_test.sh` sends both notifications with deliberately divergent
save text, checks that the existing symbols/tokens remain unchanged and no
notification is emitted, then verifies that the next valid `didChange` applies.

## Malformed-output guard

`src/json_writer.elisa` owns shared JSON serialization helpers. `json_escape_utf8`
escapes every outgoing string, including diagnostics, hover, URIs, workspace
paths, and error messages. It copies only shortest-form UTF-8 scalar values (no invalid
continuations, overlong encodings, surrogates, or values above U+10FFFF); each
malformed byte becomes an escaped U+FFFD. Quotes, backslashes, and C0 controls
are escaped before framing. `json_push_i64` serializes signed values without
the non-negative-only behavior of the frontend's `Bytes.push_int`, including
the i64 minimum. Validated request IDs retain their original JSON token spelling
so numeric/string identity is preserved. `test/json_escape_utf8_test.sh`
directly checks malformed scalar forms, Unicode boundaries, JSON metacharacters,
controls, signed integer limits, and Python JSON decoding of the complete output.

## Diagnostic ranges (G01)

`Semantic::Diagnostic.pos.offset/end_offset` are half-open physical byte
offsets; its line and column fields are 1-based, with `end_column` exclusive.
`src/diagnostics.elisa` uses the absolute offsets only when both endpoints are
inside the accepted source snapshot and map back to the same line/column
positions. `src/positions.elisa` then converts them to negotiated LSP units.
Compiler findings carry the stable LSP `source` label `elisa`; the server's
synthetic truncation hint uses `elisa-lsp`. Every compiler `DiagnosticKind` is
also emitted as a stable machine-readable `code` of the form
`ELISA-<DiagnosticKind>`. The generated adapter in
`src/diagnostic_codes.elisa` is produced by
`scripts/generate_diagnostic_codes.py` from the pinned frontend enum, and
`test/diagnostic_codes_test.sh` fails if the enum changes without a reviewed
regeneration. These identifiers are independent of wording and severity;
unknown future kinds use the bounded `ELISA-Unknown` fallback until the
adapter is regenerated. The server-owned truncation hint uses the reserved
`ELISA-LSP-DiagnosticsTruncated` code and the `elisa-lsp` source label.
If the offsets are defaulted, stale, or inconsistent, the bounded
line/column span is used; findings without a span fall back to the bounded
line extent. The server never emits `character: 999`. Line numbers beyond EOF
clamp to the last line; inverted ends collapse to start.

## Diagnostic publication (G02)

Pushes carry the client document `version` so the client can order them.
Identical repeats for the same version are suppressed (duplicate `didOpen`
sends one push, not two). Output is capped at 200 findings with a visible
severity-4 hint (`"additional distinct diagnostics omitted (showing first 200)"`)
instead of silent truncation, and exact duplicates never appear twice. Close publishes an empty
array with the last known version, transferring the file back to disk-backed
ownership. The publish path re-checks the document generation before sending,
so a stale analysis can never overwrite newer findings once analysis moves
off the event loop.

## Outgoing provider-range assertions (U02)

Set `ELISA_LSP_VALIDATE_RANGES=1` for debug and protocol-regression runs. The
server then validates every provider payload immediately before framing: ranges
and folding line spans are inside the current open snapshot, endpoints are valid
under the negotiated UTF-8/UTF-16 encoding, nested selection/document-symbol
chains retain valid ranges, URIs resolve to the request document, semantic-token
data has valid source bounds, and direct arrays are ordered by start position.
Invalid retained output is converted to one `InternalError` and logged through
the bounded assertion path. The default is disabled to avoid an extra source scan
on production responses. `test/provider_range_validation_test.sh` enables it for
all current provider suites.

## Source coordinates (U01/U02)

`src/positions.elisa` (`module Positions`) is the one coordinate API: byte
offsets internally, UTF-16 line/character only at the protocol boundary.
Diagnostics, semantic tokens, and hover all route through it. Tokens convert
starts via per-line byte→unit mapping and lengths via span unit counts, so
non-ASCII lines (CJK, emoji, combining marks) slice exactly. `test/positions_test.sh`
decodes every token and diagnostic range of a Unicode fixture through a single
UTF-16 helper — one basis, all providers.

## URI identity (D03)

The complete user-facing workspace, project, overlay, settings, and URI
contract is in [`docs/workspace-and-configuration.md`](workspace-and-configuration.md).
The sections below retain the implementation-level details and test anchors.

`request_uri` only unescapes JSON. `Uri::parse` in `src/uri.elisa` records
scheme, authority, path, query, and fragment as byte spans in the original URI;
it also reports malformed percent escapes without rejecting the URI. The
separate `Uri::canonical_key` conversion drives lookup: schemes are
lowercased; for `file:` URIs the whole authority is lowercased and `localhost`
is dropped; non-reserved percent escapes in authority, path, and query are
decoded bytewise, including UTF-8 sequences. Reserved escapes stay encoded
with uppercase hex, so `%2F` remains distinct from `/`; malformed escapes stay
literal. Query text remains part of identity and `#fragment` is omitted.
`file:/path` and `file:///path` retain their different authority structures.
Responses echo the client's incoming spelling; storage and lookup use the
canonical bytes. This is lexical URI identity only: paths keep their case, no
URI is converted to an OS path, and filesystem case behavior, symlinks, and
physical-file aliases are not resolved. `untitled:` and other non-file schemes
remain in-memory overlays — the server never fetches them. The deterministic
component and alias cases are covered by `test/uri_test.sh`.

When a future filesystem-backed feature needs an operating-system path, it
must call `Uri::file_uri_to_path` rather than reinterpret the canonical key.
That conversion is explicit about the target grammar (POSIX or Windows): it
strictly decodes percent escapes, retains UTF-8 and spaces, rejects NUL and
malformed escapes, rejects query/fragment metadata, refuses non-local POSIX
authorities, and maps Windows drive forms (`/C:/`, `/C|/`, and `C:/`) plus
remote authorities to UNC paths. It does not normalize `.`/`..`, fold path
case, resolve symlinks, or touch the filesystem. An OS path can therefore be
used by a later file operation without changing URI lookup identity or client
spelling. Both grammars and rejection cases are exercised by
`test/uri_path_test.sh`. The host-specific alias evidence is collected by
`test/filesystem_identity_test.sh`, which probes a private temporary directory
without changing the LSP's lexical identity rules. Case policy is recorded per
volume (`sensitive`, `insensitive`, or `unknown`) rather than inferred from an
OS name. A future W02 resolver may attach a separate physical file identity
only after a successful case/realpath/file-identity query: unknown, missing,
permission-denied, unsupported, and symlink-cycle results stay distinct and
fail closed. Physical identity can deduplicate reads/index entries, but the
canonical URI remains the source/edit identity and the incoming URI spelling
remains the protocol display identity.

Compiler display paths have the same boundary. `tokenize_frontend_source` uses
the compiler's expanded-unit entry point with the stable display name
`<elisa-lsp>`, while the LSP retains the accepted UTF-8 snapshot and maps every
diagnostic, token, symbol, and hover range against its physical lines. A source
`#line` path or line number cannot become a URI lookup key or move a protocol
range outside that snapshot; the regression is
`test/source_identity_test.sh`.

The analysis worker uses the compiler-backed
`Lexer::frontend_tokenize_expanded_unit_with_comments` entry point for this
snapshot. It returns the parser-compatible token stream and the lexer comment
side channel from one machine pass; the LSP passes the token array into parsing
and checking, then merges the returned comment spans into semantic tokens. The
legacy `frontend_tokenize_comments_with_length` entry point remains available
to other compiler clients, but the LSP must not call it for an accepted
snapshot because doing so would re-lex the complete source. The direct
token/comment equivalence and the no-fallback source check live in
`test/combined_lexer_test.sh`.

## Capability negotiation (P03)

`initialize` params are parsed once into a session profile
(`negotiate_utf8`, `semtok_negotiate_profile`, and
`negotiate_hover_markdown` in `src/main.elisa`/`src/semtokens.elisa`) and
threaded to diagnostics, tokens, and hover — one branch point, no per-handler
disagreement. Position encodings honor client preference order (first of
utf-8/utf-16 wins, default UTF-16); the server advertises `positionEncoding`
only when UTF-8 wins. Token/diagnostic columns follow the session mode via
`Positions::line_unit_length/byte_col_to_units/span_unit_length`. Hover sends
`plaintext` only when the client lists formats without `markdown`. Unknown or
absent capabilities keep safe defaults.

`textDocument.definition.linkSupport` is validated once during initialize.
Clients setting it to `true` receive `LocationLink[]`; other clients continue
to receive `Location`. Link ranges use the negotiated position encoding and
exact resolver-provided origin and target token spans. Since the resolver does
not yet retain an enclosing declaration-node span, `targetRange` currently
equals `targetSelectionRange`. Malformed or duplicate capability members are
rejected with `InvalidParams`.

Semantic-token analysis always caches the canonical 48 Elisa token indices.
Clients that omit `textDocument.semanticTokens` keep the established custom
legend, as do clients whose `tokenTypes` includes the complete custom list.
Other clients receive only standard token types they advertised and that are
used by `docs/semantic-token-schema.json`'s `standard_fallback` table. The
server maps cached entries into that one session legend and drops entries whose
fallback category is unsupported. Full and range requests use the same map;
range filtering re-encodes after dropped entries so relative positions remain
correct. A present semantic-token capability must contain at most 256 unique
`tokenTypes`, each a nonempty string of at most 128 UTF-8 bytes; malformed
types, duplicate decoded names, and duplicate `tokenTypes` keys make
initialize return `InvalidParams`.
When the capability includes `tokenModifiers`, the same validation applies to
that list. The server negotiates the supported standard modifiers in canonical
order (`declaration`, `definition`, `readonly`, `modification`) and remaps the
canonical cache bitset at the response boundary. `definition` marks concrete
declaration names, `declaration` marks `extern` names, `readonly` comes only
from the compiler's immutable-`const` registry, and `modification` marks direct
identifier/field write targets and `rebind` targets. The server drops
unsupported or unadvertised modifiers and does not infer `static`, `deprecated`,
`abstract`, `async`, documentation, default-library, or Elisa-specific mutable,
unsafe, and ghost modifiers. `test/capabilities_test.sh`,
`test/semantic_range_test.sh`, and `test/semantic_modifiers_test.sh` pin
custom, standard, partial, malformed, modifier, and full/range behavior.

### Session configuration and settings transport

The server has deterministic defaults for settings that affect protocol work.
The analysis worker deadline defaults to 30,000 ms and is bounded to
100–300,000 ms. The process environment variable
`ELISA_LSP_ANALYSIS_TIMEOUT_MS` selects the initial process value. A client
may override that one setting in `InitializeParams.initializationOptions` or
through the standard `workspace/didChangeConfiguration` notification using
the namespaced shape
`{"elisa":{"analysisTimeoutMs":<integer>}}`. The setting is validated as a
signed LSP integer before it is applied; malformed or out-of-range values in
initialize return `InvalidParams`, while malformed notifications are ignored
without changing the previous value. Unknown top-level settings and unknown
members inside the `elisa` object are reserved for other extensions and are
ignored. Applying a valid setting happens at a message boundary and affects
the next analysis operation.

The server does not issue `workspace/configuration` requests yet, so there is
no pending-request table or client-response timeout to maintain. If a future
setting requires that request, add typed request-ID correlation, response
shape validation, cancellation, timeout, and a documented fallback before
advertising the dependency. The validation and notification lifecycle cases
are covered by `test/configuration_test.sh`.

## Signature help (F06 initial slice)

`textDocument/signatureHelp` is advertised with `(` and `,` trigger characters.
During the normal tokenize/parse/check pass, `src/features/signature_help.elisa`
copies an owned signature/call index into the document snapshot while the AST,
semantic resolver edges, and lexer tokens are still available. Requests use
that index and the current text snapshot; they do not reparse. The active
parameter is selected from comma tokens at the call's own delimiter depth, so
nested calls, collection delimiters, multiline arguments, and commas inside
string tokens do not shift the enclosing call's parameter. Document cursor
positions are converted through `Positions` before they are compared with the
retained byte offsets. An unclosed call remains eligible through the current
snapshot end.

This deliberately narrow provider returns one `SignatureInformation` for an
exact resolver edge to a unique, top-level source function. If the compiler
omits an edge for an unmatched call at the end of a broken source snapshot, a
bounded fallback is allowed only for a direct unqualified call whose spelling
has one eligible same-file function declaration, no same-named symbol, module
member, or variant, and no other identifier occurrence anywhere in the file.
The fallback examines at most 32 unmatched open delimiters and intentionally
declines some otherwise valid calls to avoid guessing across local scopes.
Labels and parameter labels currently contain declaration names only. It
returns `null` for named argument lists, overloaded or shadowed/unresolved names,
module and member calls, dynamic callables, constructors, variadics, and
synthetic effect-handler rewrites. It does not yet include parameter
types/default markers, return types, effects, documentation, overload choice,
or parameter-label offset ranges.
Optional `SignatureHelpContext` is shape-checked against the LSP 3.17 fields:
`triggerKind` accepts 1–3, `isRetrigger` is required and boolean, and kind 2
requires a string `triggerCharacter`. Context support is accepted without
changing the single-signature selection policy. The exact subset and decline
cases are pinned in `test/signature_help_test.sh` and
`docs/feature-manifest.json`.

## Completion (F05 bounded slice)

`textDocument/completion` reads declarations and occurrences from the retained
analysis summary; a request does not lex or parse again. It offers same-file
functions, structs, enums, aliases, constants, uniquely named enum variants,
exact-owner parameters, and declaration-backed locals at the current function
body indentation or a nested indentation block. Exact local binder spans and
function owners come from the retained analysis; source lines are scanned from
each binder to the cursor, and the candidate is hidden after an outdent. This
keeps nested locals out of sibling blocks while leaving enclosing locals
visible inside children. The compiler does not yet retain scope-end positions,
so this boundary is inferred from indentation. It filters by the typed prefix, ranks exact-prefix
matches before other prefix matches and then by label, and returns a whole-token
`textEdit` in the negotiated UTF-8 or UTF-16 encoding. Only a visible binding
in the active function replaces a same-named file-level candidate; same-named
locals in other functions do not suppress it. Duplicate global declarations
remain ambiguous.

Optional completion forms are negotiated independently. A unique retained
function signature supplies an escaped argument snippet only when the client
supports snippets. Clients that support insert/replace edits receive separate
insert and full-token replace ranges. Plain function-name edits receive `(` as
a commit character only when supported and when no opening parenthesis follows
the token. Parameter-name `labelDetails` are returned only to capable clients
for a unique retained signature. Ambiguous or missing signatures and
non-function items omit signature-derived fields.

`completionItem/resolve` is advertised for on-demand function detail. A
resolvable item carries data for the canonical URI, document version, and
open-document generation that produced it. Resolve adds `detail` in the form
`name(parameter, ...)` only if that exact snapshot is still open and ready. It
preserves other submitted item fields; missing, malformed, unknown, or stale
data returns the item unchanged. Resolve metadata is omitted for non-functions,
missing signature metadata, and URIs longer than 2,048 bytes. This keeps the
response bounded and prevents an old completion list from resolving against a
new document or a same-version reopen.

The provider declines ordinary quoted strings, comments, and member access and
reports `isIncomplete: true` because imports, workspace symbols, members,
nested-block scopes, f-string interpolation, multiline-string state, and
expected-type ranking are not indexed. Documentation, return types, and
comprehensive parser-context recovery remain open. The focused contract is
covered by `test/completion_test.sh`; the full F05 acceptance gate remains
open.

## Strict protocol numerics (J02)

`Json::as_i64_result`, `as_lsp_integer_result`, and
`as_lsp_uinteger_result` return tagged valid/invalid outcomes; no error sentinel
can collide with a valid number. LSP `integer` fields are bounded to signed
32-bit values and `uinteger` fields to 0 through 2^31−1. `didOpen` and
`didChange` require a valid signed version; negative versions round-trip and
stale/equal updates are rejected by comparison with the accepted version.
Fractional, wrong-typed, missing, and overflowing versions never mutate a
document. Coordinates use the `uinteger` bounds. `test/numerics_test.sh`,
`test/documents_test.sh`, and `test/json_smoke.sh` pin bounds, negative-version
handling, and post-reject recovery.

## Protocol envelopes (P01)

Incoming bodies must be JSON-RPC 2.0 objects with a non-empty decoded `method`.
Present request IDs are accepted only as integer numbers or strings; invalid
IDs are answered with `id:null`, while valid IDs are echoed with their exact
JSON type and string escaping. Generic `params` must be an object or array,
then known methods apply their own required-field checks and return
`InvalidParams` before any handler can mutate state. Duplicate top-level
`jsonrpc`, `method`, `id`, or `params` members are `InvalidRequest`.
Initialize validates every consumed workspace root before changing state:
`workspaceFolders` must be null or an array of objects with one decoded `uri`
and one string `name`; `rootUri` must be null or a nonempty string. Escaped
duplicate keys inside a folder are rejected, and more than 32 folders exceeds
the explicit session bound. A rejected initialize leaves the connection
uninitialized so a corrected request can succeed.

Accepted roots are stored in initialize order after URI canonicalization. The
private `$/elisa/workspace` inspection request resolves a document to the
longest containing root, checks path-segment boundaries, and returns `-1` for
documents outside all roots; a root URI ending in `/` owns its descendant
paths. This is only root bookkeeping, not project configuration or cross-file
semantic isolation. Dynamic workspace-folder changes are not advertised, so a
client must restart the session after changing the folder set. The
`test/workspace_roots_test.sh` regression covers nested roots, trailing slashes,
sibling-prefix rejection, and the legacy `rootUri` fallback.

Method calls without IDs never receive responses. Request-only LSP methods
without IDs are ignored because their handlers currently require a response
context; notification methods are validated and processed only without IDs.
Unknown notifications and response-shaped input are ignored. This server does
not initiate JSON-RPC requests, so it has no pending-response table; clients
must keep IDs unique while their own requests are outstanding. Incoming
requests are dispatched serially and answered before the next message is
handled; the server does not retain a duplicate-ID history, so clients that
violate the outstanding-ID rule can receive indistinguishable response IDs. A
response-shaped message with no matching server request is ignored, even when
its result/error members are malformed. A valid unknown
request after initialization receives `MethodNotFound`; before initialization,
the server reports `ServerNotInitialized`. `test/protocol_test.sh` pins these
choices, including unsupported top-level arrays and escaped-equivalent names.

## Initialization and shutdown lifecycle (P02)

The server follows the lifecycle rules in the official [LSP 3.17 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#initialize)
and [LSP 3.18 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialize).
`src/main.elisa` models the connection as `Uninitialized`, `Initializing`,
`Running`, `Initialized`, `ShutdownRequested`, or `Exited`. The initialize
response is sent before the server enters `Running`; one `initialized`
notification advances it to `Initialized`. Repeated or out-of-order
`initialized` notifications are dropped. The server accepts normal work in
both live states so clients that omit this notification remain compatible.

Before initialization, every request except `initialize` receives
`ServerNotInitialized` (`-32002`), including private `$/` extension requests;
notifications are dropped except for `exit`. Invalid initialize parameters do
not consume the one initialize attempt. A second initialize request receives
`InvalidRequest` (`-32600`). A valid shutdown request responds with `null` and
then enters `ShutdownRequested`. Thereafter all requests, including a second
shutdown, receive `InvalidRequest`, and all notifications except `exit` are
dropped without dispatching providers, document updates, or cancellation. The
shutdown transition clears saved cancellation IDs. An `exit` notification
returns status 0 only after shutdown and status 1 otherwise. Clean EOF remains
a transport-level orderly stop with status 0; malformed or truncated framing
still returns nonzero. The lifecycle matrix and invalid-transition recovery
checks are in `test/protocol_test.sh`.

The POSIX adapter (`src/transport_posix.c`) records the first `SIGINT`,
`SIGTERM`, or `SIGHUP` and makes a blocked stdin wait interruptible. Once the
current synchronous dispatch returns, the server restores its prior signal
handlers and input descriptor flags, then exits with the conventional
`128 + signal` status. The signal handler only writes a `sig_atomic_t`; it does
not log, allocate, or touch document state. Each accepted snapshot runs in a
short-lived child. While draining its result, the parent checks for a pending
termination signal at least every 25 ms and kills and reaps the child before
exiting. The OS reclaims document storage when the server exits. The server and
adapter currently target POSIX hosts; this does not establish Windows support.

## Document symbols (F02)

`src/features/document_symbols.elisa` renders the frontend's file symbol
table as an outline. Only symbols with `line > 0` (real file content) are
emitted — prelude/primitive scope is excluded. Shape follows the session:
flat `SymbolInformation` by default, hierarchical `DocumentSymbol` (with
`children`) only when the client sets
`hierarchicalDocumentSymbolSupport`. Hierarchical output attaches compiler
symbol rows to the nearest source-indented module, preserves source order,
and widens declaration ranges over the corresponding indentation block so
parent ranges contain their children. `selectionRange` uses the compiler's
validated `name_pos` when available, or one unambiguous matching identifier
token from the declaration line; ambiguous/absent evidence falls back to the
line extent. Struct fields and enum variants remain omitted until the
frontend supplies stable declaration positions/identities. The client's
`symbolKind.valueSet` is honored by clamping each category through fallbacks,
and `Unknown` kinds are omitted rather than guessed. Floors:
`test/document_symbols_test.sh`.

## Transport framing (T01)

Input is buffered, not read one byte per syscall. `transport_fill` keeps a
reusable read buffer whose unconsumed tail survives across messages, so a
single `read` may deliver several frames, part of a frame, or a split
multibyte UTF-8 sequence without mis-framing (`read_message` in
`src/main.elisa`). Bounds and strictness: header names are case-insensitive,
terminated by CRLF, and header names/values must be valid ASCII field syntax.
`Content-Length` accepts only decimal digits with optional surrounding spaces
or tabs (no `5x`, sign, or empty value) and is overflow-checked; identical
duplicate lengths are tolerated, conflicting duplicates are rejected. The
optional `Content-Type` accepts `application/vscode-jsonrpc` with an omitted
charset, `charset=utf-8`, or the legacy `charset=utf8`; non-UTF-8 charsets and
non-identity `Content-Encoding` values are rejected. Other syntactically valid
ASCII header fields are ignored. Missing lengths, malformed headers, truncated
headers/bodies, and oversized headers/bodies (16 KiB header / 64 lines / 16 MiB
body) fail closed with a controlled nonzero exit and no output frame. A
zero-length body is a complete frame and receives JSON-RPC ParseError, after
which following frames remain synchronized. Clean EOF between messages is
exit 0. `read` retries interruption; terminal read errors and client-side
closed output pipes return nonzero rather than masquerading as EOF or killing
the process with SIGPIPE. A single unterminated header line is bounded while
it is being read, not after it has been allocated.

Limits have conservative defaults and hard ceilings. Set
`ELISA_LSP_MAX_HEADER_BYTES` (default 16,384; range 256–1,048,576),
`ELISA_LSP_MAX_HEADER_LINES` (default 64; range 2–1,024), or
`ELISA_LSP_MAX_BODY_BYTES` (default 16,777,216; range 1–268,435,456) to adjust
them. `ELISA_LSP_MAX_OPEN_SOURCE_BYTES` (default 268,435,456; range
1–1,073,741,824) caps the aggregate UTF-8 source bytes retained for currently
open documents; NUL terminators are excluded. An over-budget `didOpen` or
`didChange` is ignored before mutation, preserving any previously accepted
snapshot and its version. Values must be unsigned decimal integers; invalid
configuration exits with status 2 and a bounded stderr message before reading
input. The body override is intended for large files and remains capped at
256 MiB. `ELISA_LSP_MAX_OPEN_DOCUMENTS` (default 1,024; range 1–16,384) caps
simultaneously open document records. `ELISA_LSP_MAX_OPEN_URI_BYTES` (default
8,388,608; range 1–67,108,864) caps aggregate URI metadata bytes for those
documents: each entry counts both its canonical lookup key and retained
original URI spelling. Empty-source overlays count against both metadata limits, and
duplicate opens replace an existing lifetime without consuming another slot.
Document-count and URI-byte checks run before a slot is created or the URI
index is changed. Private stats expose the current URI-byte count and both
configured caps. The document and URI-key counts are bounded, though the
document vector and URI hash table retain capacity up to their high-water mark.
`ELISA_LSP_MAX_DERIVED_CACHE_BYTES` (default 67,108,864; range
1,024–1,073,741,824) caps retained reservation capacity for semantic, symbol,
hover, and signature payloads across open documents. A validated result gets a
monotonic access stamp; whole-document least-recently-used eviction clears all
derived payloads and leaves the accepted source/version authoritative. Analysis
runs in a forked one-shot child, so parent-side edits and cache eviction do not
race with frontend reads in the child; the parent aborts obsolete work and checks
snapshot identity before committing. Allocator-retained pages and container
high-water capacity remain outside these logical budgets.

`ELISA_LSP_WRITE_TIMEOUT_MS` sets the maximum time spent writing one complete
LSP frame to stdout (default 15,000 ms; range 100–120,000 ms). The deadline is
monotonic and shared by the `Content-Length` header and response body, so
partial progress does not restart the timeout. While a frame is being written,
stdout is temporarily nonblocking and its original blocking mode is restored
afterward. A stalled client causes a controlled nonzero server exit when the
deadline expires; because a prefix of the frame may already have reached the
client, the server does not attempt to continue with another frame. The server
retains only the response currently being serialized and has no output queue.

`ELISA_LSP_ANALYSIS_TIMEOUT_MS` bounds one accepted document analysis (default
30,000 ms; range 100–300,000 ms). Analysis runs in a fresh POSIX child process;
the same monotonic deadline covers process setup, frontend work, result
serialization, pipe draining, and child reaping. A timeout, abnormal exit,
failed process setup, or malformed result kills/reaps the child and leaves the
accepted text available for source-only providers while semantic providers
report `InternalError` until a later edit succeeds. Failed analysis clears
published diagnostics so old findings are not shown as current. Malformed
packets are rejected after the child exits; a running or timed-out child is
killed and reaped. The parent commits cache spans directly from the validated
packet and sends its diagnostic span without an intermediate payload copy.
Analysis packets are capped at 64 MiB total, and source snapshots above that
limit enter the same failed state without spawning a child. Invalid
configuration exits with status 2 before the server reads input.

The private `$/elisa/stats` result includes a `budgets` object for operational
inspection. `budgets.transport` reports the active header, header-line, body,
and complete-frame write limits; `budgets.documents` pairs current open,
canonical-URI, and source-byte usage with their configured caps;
`budgets.analysis` reports `mode: one_shot_worker`, the number of queued
snapshots, the configured open-document queue ceiling, the current zero-or-one
in-flight child, timeout, and 64 MiB packet cap. `analysis_worker` separately
reports the child packet's retained bytes/capacity and the bounded deferred
request count, body bytes, byte-storage capacity, and 13 MiB logical storage
limit. The `budgets.cache` object reports live and retained derived-cache
bytes, the configured aggregate limit, and whole-snapshot least-recently-used
eviction count. The retained cost includes each cache reservation's capacity,
so replacing a result with a smaller payload still accounts for owned memory.
Eviction clears all derived payloads for the least recently used complete
snapshot and marks that accepted source pending; the next edit or reopen
rebuilds it. Deferred requests own copies of their framed bodies in the bounded
queue and replay only after a matching validated snapshot is committed. These
fields are observability data, not a new client capability.

Floors: `test/transport_test.sh`, `test/output_write_test.sh`,
`test/output_backpressure_test.sh`, `test/transport_limits_test.sh`, and `test/termination_signal_test.sh` (split at every byte, pipelining, content-type and
encoding policy, malformed-length matrix, large-body refill, short writes,
EINTR, EOF, terminal I/O failures, configured limits, stalled-client deadline,
signal interruption, stdout flag restoration, and an unterminated overlong
header; the POSIX adapter tests compile and run without the Elisa server
binary. `test/output_stall_server_test.py` verifies bounded exit with a real
server process and a response larger than the unread stdout pipe.

## Related diagnostic locations (G03)

When the client advertises
`textDocument.publishDiagnostics.relatedInformation`, a finding whose compiler
`Diagnostic` carries a secondary span (`secondary_line > 0`, as
`ModuleRedeclared` does) emits `relatedInformation` pointing at the original
declaration's range, converted through the same coordinate layer. Incapable
clients get the unchanged diagnostic; findings without a secondary span never
fabricate related info. The compiler remains the source of the relation and
the diagnostic wording; the server owns only the LSP framing and a short
presentation label. Floor: `test/related_info_test.sh`.

## Frontend adapter (A01)

`src/frontend_adapter.elisa` is the only module that reaches into the
compiler's `Semantic::SymbolTable` storage layout. It exposes named accessors
(`symbol_name`/`symbol_category`/`symbol_source_line`/`symbol_source_offset`,
`symbol_index_of`/`symbol_declaration_id`, `occurrence_kind_at` with named `OCC_PARAM`/`OCC_LOCAL`
roles decoded from `ref_kind`, enum-variant and definition-edge lookups,
`diagnostic_count`/`diagnostic_at`) and the version 11 contract in
[`docs/frontend-adapter-contract.md`](frontend-adapter-contract.md), which
specifies lex/parse/analyze/query result ownership and source-span lifetimes.
`test/frontend_contract_test.sh` executes the combined lexer wrapper, including
its comment side channel, as well as the parser/checker accessors. Before
providers consume a returned table, `frontend_table_valid` checks parallel
array lengths, supported occurrence roles, every symbol's table-local ID
against its row, optional symbol-name spans, and definition-edge targets/spans
against the accepted source length. It permits
the parser's narrow missing-function-name placeholder only when the row is
empty, zero-width, bounded, and matches a parser error expecting an identifier
at newline or EOF; name indexes and providers skip that empty row, and an edge
cannot target it. Other malformed normal returns mark the document snapshot
Failed, clear its derived caches, publish empty diagnostics for its current
version, and write a rate-limited fixed stderr message. This catches malformed
returned tables and API drift; it cannot recover a panic, abort, or hang inside
`Semantic::check`, which requires the process-isolation work described under
A04. The fixture `test/frontend_contract_test.sh` checks both valid adapter
lookups, this parser-recovery row, and malformed-table rejection. Token
presentation, diagnostic wording, and JSON framing stay outside the adapter.

The worker also assembles one `LspFrontendAnalysisSnapshot` for the analysis
job. It carries the shared token/comment batch, parsed syntax (including
recovery nodes), checked semantic table, symbol and diagnostic sidecars, exact
occurrence positions, source length, adapter-contract version, and an explicit
`Complete`, `Recovered`, or `Rejected` outcome. The snapshot is a shallow,
job-local view: the source, tokens, and AST owners remain in the same lexical
scope through all provider projections, and the parent receives only validated,
owned packet payloads. Snapshot validation checks contract/source identity,
that `Complete` has no parser errors and `Recovered` has parser errors, and
that sidecar shapes agree after the adapter validates the underlying semantic
arrays and source spans. The contract fixture constructs both a clean and a
recovered snapshot and checks the associated diagnostics and completeness
state.

If the accepted open snapshot enters `Failed` because a returned table violates
that contract, semantic tokens, signature help, definition, references,
document highlights, and document symbols return JSON-RPC `InternalError` rather
than presenting the failure as a valid empty result. Requests for unopened
documents keep their normal empty/null result, and source-only folding and
selection requests can still use the accepted text. A later valid edit rebuilds
the analysis and re-enables semantic providers. Hover keeps its lexical fallback
while semantic data is unavailable. This request-level recovery only applies
after the checker returns; containment of a panic, abort, or hang still requires
the A04 worker boundary.

## Multiline tokens (H03)

The LSP semantic-token format has no multiline tokens: a token's `length`
applies to its start line only. `semtok_normalize` in `src/semtokens.elisa`
splits any span wider than its start line (multiline comments/strings) into
valid per-line pieces that preserve order, never overlap, and exclude a CRLF's
CR. Floors: `test/multiline_tokens_test.sh` (LF, CRLF, and Unicode cases).

## Semantic precedence (H02)

A resolved param/local binding (from the frontend occurrence log, via the
adapter) is authoritative for an identifier and is consulted before the
keyword/type spelling classifier, so a contextual keyword legally used as a
name (`get`, `of`, `at`) keeps its binding kind, and a local that shadows a
top-level type is tinted as that local. Member access after `.` remains a
field/method decision (also fixed before spelling). Effect-list identifiers
and real keyword tokens are unaffected. Floors: `test/precedence_test.sh`.

## Performance pipeline (H04)

Token encoding and document-symbol generation stream a **line cursor** in
source order instead of re-scanning to each line start from offset 0 (which
made them O(tokens × file size)). Identifier resolution uses per-analysis hash
indexes exposed by the frontend adapter — `symbol_index_build` /
`symbol_index_of_indexed` (name→symbol), `occurrence_index_build` /
`occurrence_kind_indexed` (composite source-line+exact-name→occurrence chain),
and enum-owner/name indexes for direct and bare variant classification — so
classification is O(1) average per identifier rather than a full scan. Enum
owner lookup follows aliases through a bounded chain after its direct indexed
probe; it verifies exact strings after hashing, rejects self/cyclic traversal,
and retains the linear adapter helper as the recovery/oracle path. The
occurrence chain likewise still verifies both fields after hashing, preserving
the linear adapter lookup as a collision/reference oracle. Measured on a synthetic
many-declaration file: 127 KB / 4.8k lines went from ~13.7s to ~3.1s at
`-O2`. Run `python3 test/bench.py --out bench/results.json` to capture the B04
baseline as JSON for 100, 1,000, and 5,000 function fixtures. `--sizes 100,1000`
selects fixtures and `--samples 3` repeats each scenario in a fresh server
process. The benchmark first verifies that the executable matches the current
build manifest and refuses stale artifacts; rebuild with `bash build.sh` after
source changes. `--allow-stale` exists only for diagnosing an intentionally
stale artifact and is recorded in provenance, so such a report must not be
used as a release comparison.

The JSON includes source hashes and byte counts, semantic-token counts,
per-scenario wall times, CPU/RSS when available, and build-manifest, binary,
host, freshness, and Git provenance. Wall time covers the documented scenario
round-trip; CPU and peak RSS cover that scenario's full server lifetime,
including setup. Every distribution summary includes the sample count, minimum,
median, nearest-rank p95, and maximum. Nearest-rank p95 selects the sample at
`ceil(0.95 * N)` after sorting, which keeps small runs deterministic; with one
sample p95 equals that sample. Raw timings are observations, not CI gates (see
the plan's separate-performance policy). Use p95 when comparing warm and cold
tail behavior, and retain the exact provenance and sample count with any
comparison.

For Q04's one-axis-at-a-time corpus experiments, add for example
`--dimensions source_size,symbols,unicode_density,edit_burst`. Source-size
fixtures hold declaration count constant and pad to exact UTF-8 byte targets;
symbol fixtures hold bytes constant and include a `documentSymbol` count;
Unicode fixtures hold bytes and declaration count constant while varying
non-ASCII comment density; edit-burst fixtures preserve the source size while
issuing sequential full-text changes and token requests. The
`dependency_fanout` axis is available as an explicit multi-document surrogate
(`--dimensions dependency_fanout`), because the current server does not yet
resolve project dependencies; its report must not be interpreted as a
dependency-graph benchmark. Use `--dimensions all` only when the larger
opt-in matrix is intentional.
The first checked-in run is `bench/baseline-2026-09-13.json`; rerun the command
on the release machine before using it as a release comparison.

Every run also includes a separate `storage_soak` section in benchmark schema
version 3.
By default, one fresh server process performs 20 cycles with 100-function
documents: open a distinct URI, replace its text with a bounded larger revision,
close it, then read `$/elisa/stats` after each operation. `--soak-cycles N`
controls the number of cycles and `--soak-functions N` controls that fixture's
size independently of `--sizes`; for example,
`python3 test/bench.py --sizes 100 --soak-cycles 500 --soak-functions 250`.
Each sample stores the full per-cycle trace (`storage_bytes`,
`storage_capacity`, `live_bytes`, `documents`, `documents_capacity`, `open`, and
line-index active/stored/capacity counts),
operation round-trip timings (each operation summary includes count, minimum,
median, nearest-rank p95, and maximum), final and peak counters, and
server-process CPU/RSS when available. The capacity fields are the current darray backing capacity in
bytes for storage and slots for documents. `soak_wall_s` spans the first open
through the last post-close stats response; `server_process_wall_s` also includes
initialization and shutdown. The stats values describe the LSP's flat document
buffer, document slots, URI index, and retained line-index sidecar:
`documents` counts registry slots, including free reusable slots, while `open`
counts currently open documents. Line-index capacity is measured in `usize`
entries. These counters do not measure total process heap or allocator-retained
memory, and retained RSS alone is not evidence of a leak.

## Storage reclamation (D04)

The session buffer appends a new reservation when a document source or cache
outgrows its current capacity; the old reservation becomes dead space until
`storage_reclaim` rebuilds the live bytes into a temporary buffer and swaps it
back once storage is at least twice the live size and above a 64 KiB floor.
Open documents retain their URI, source, and derived token/symbol/hover/
signature data. Closing a document unlinks its URI from the lookup index and
marks the slot reusable; compaction drops its URI and every byte in the freed
slot. Reclamation runs between messages, after open/change/close, when no
request holds a view into the buffer. `test/storage_reclaim_test.sh` drives
120 escalating-growth open/close cycles, asserts the buffer stays within ~2×
live, and that it reclaims to a few hundred bytes with features intact. The private
`$/elisa/stats` request (never advertised as a capability) reports logical
`storage_bytes`, `live_bytes`, and `dead_storage_bytes`, plus the current darray
backing capacities as `storage_capacity` and `documents_capacity`. It also
reports open canonical-URI bytes, source bytes excluding one stored NUL per
open document, aggregate logical derived-cache bytes, aggregate retained
reservation bytes, and the largest per-open-document cache. The cache budget
also reports its configured limit, `lru_snapshot` policy, and eviction count.
`snapshots` reports the current open, pending, ready, and failed snapshots;
`test/failed_analysis_request_test.sh` verifies that an injected failed snapshot
increments `failed` and that a later successful version returns the counts to
one ready and zero failed.
`dead_storage_bytes` is the
unreachable portion of the current flat buffer (`storage_bytes - live_bytes`),
not the memory retained by the allocator. `derived_cache_bytes` uses live
payload lengths, while `retained_bytes` includes each reservation's capacity.
Capacity shows the active container's
high-water reservation; it does not count older buffers retained inside the
arena, other containers, or total process memory.
Its `line_index` object reports active line entries, cached documents, stored
entries including holes, active darray capacity, and retained/fallback build
counts. At most 1,048,576 logical entries are retained in the sidecar (about
8 MiB with arm64 `usize`). The analysis worker shares the retained span across
semantic-token, diagnostic, document-symbol, and hover-summary construction;
an over-budget snapshot builds one temporary index for that worker job. The
loop-header/general hover, foldingRange, selectionRange, and signatureHelp
handlers use the retained span or build one request-local fallback when the
snapshot is over budget. One hover request shares its fallback between the
loop-header and general-hover paths. Close and
message-boundary compaction clear or rebase document spans safely.
The B04 benchmark records those counters after each operation in its bounded
long-session scenario; use `--soak-cycles` and `--soak-functions` to scale the
cycle count and fixed document size. It also samples the live server's current
resident set after initialization, after the first close, and periodically
through close batches, pairing each reading with the logical storage counters.
The sampler uses `libproc.proc_pid_rusage` on macOS and `/proc/<pid>/statm` on
Linux, normalizes readings to bytes, and records `null` when the platform does
not provide a supported source. These sparse process-level samples can reveal
growth that the darray counters miss, but they neither attribute memory to a
particular arena nor serve as a noisy CI threshold; the lifetime peak RSS is
recorded separately.
The captured Darwin/arm64 sample in `bench/storage-rss-2026-09-14.json` ran 200
one-function open/change/close cycles. RSS rose across all sampled close points
from 1,900,544 bytes after the first close to 5,111,808 bytes at cycle 200,
while the final snapshot had 3,101 stored bytes, 0 live bytes, and 131,072
bytes of active darray capacity. The active flat-store capacity had stopped
growing, but process RSS continued to rise. This reveals retained process
memory outside the reported counters for this workload; one run does not
identify which arena owns those pages or establish the long-session growth rate.
Closed documents are unlinked from their hash chain and their slot marked free;
`document_slot` reuses a freed slot (bumping its generation so no old lifetime
can publish) instead of appending. The slot table is therefore bounded by peak
concurrent opens, not by the number of distinct URIs touched. Storage is
the logical byte count is bounded after compaction, but the active darray's
backing capacity can retain its high-water reservation, and the arena may also
retain older buffers after growth. The 2×/64 KiB trigger compacts logical bytes;
it does not prove that the allocator released memory. `test/storage_reclaim_test.sh` also drives 300
distinct URIs and asserts the peak slot count stays tiny.
`test/uri_collision_test.sh` separately forces a true full-hash collision in a
temporary build and checks lookup, URI equality, chain-head/middle/tail removal,
and slot reuse.

## Folding ranges (E04)

`src/features/folding.elisa` derives folds from indentation (a line opens a
region when later lines are more indented; blank lines are transparent),
runs of `#` comment lines, and `"""` doc blocks. Output is line-only
(`{startLine, endLine}`, optional `kind`), so `lineFoldingOnly` clients are
satisfied with no character offsets; the client's `rangeLimit` is honored.
Folds are always non-empty and in-bounds. Floors: `test/folding_test.sh`.

## JSON validation (J01)

`Json::parse(src)` (in `src/json.elisa`) returns either a complete `Parsed`
value or a `Rejected` validation detail. Validation requires exactly one
well-formed JSON value followed only by whitespace: strict string escapes and
`\uXXXX` hex, JSON number grammar (no leading zeros), matched delimiters, and
a bounded nesting depth (256). It reports a zero-based byte offset and one of
`encoding`, `syntax`, or `resourceLimit`; ParseError (`-32700`, `id: null`)
includes that detail in its JSON-RPC `data` member and never dispatches the
body. Framing caps each incoming JSON body at 16 MiB, and validation caps JSON
values plus object member names at 200,000 before building the value tree.
These limits bound decoded strings by input size and parser node allocation by
the value budget. Parsed strings, numbers, and keys are zero-copy spans into
the caller-owned body; the caller must keep that body alive while using the
tree. Main processes each tree synchronously and copies any document text it
retains before reading the next body. `Json::is_valid` remains a yes/no wrapper.
Valid-but-wrong-shape messages still go through P01's
`InvalidRequest`/`MethodNotFound` paths. The value accessor uses the first
matching object member generally, while duplicate top-level `jsonrpc`,
`method`, `id`, and `params` members are rejected as `InvalidRequest` (decoded
key comparison includes escaped spellings). Other duplicate object names are
currently accepted and the accessor returns the first matching decoded key.
Floors: `test/json_strict_test.sh`, `test/json_differential_test.sh`, and
`test/json_smoke.sh`.

## Cancellation (Q02)

While a document snapshot is pending, analysis-backed request bodies and typed
IDs live in a bounded queue-owned byte buffer. `$/cancelRequest` removes only
the matching pending request and returns `RequestCancelled` (`-32800`); integer
`1` and string `"1"` remain distinct, and unknown IDs are harmless. Canceling a
waiter leaves the shared analysis job running so diagnostics and other queued
requests still receive their result. The parent handles cancellation while an
isolated child is active. Requests already replayed into a provider are not yet
interruptible, and cancellation races after dispatch, during result assembly,
or for future background workspace work remain open Q02 work. Floors:
`test/cancel_test.sh` and `test/analysis_worker_test.sh`.

## General hover (A03/F01)

At analysis time `build_hover_index` (in `src/features/hover.elisa`)
serializes compiler file symbols, param/local occurrences, and enum owner/name
records into the document's flat storage — a retained, compaction-safe summary,
so hover never re-runs the frontend. Hover resolves exact param/local
occurrences first, then performs one pass over cached declaration/variant
records. A unique declaration gets a summary; a uniquely owned enum variant
gets an owner-qualified label. Repeated variant names, cross-category
collisions, and overloaded declarations return no result because the frontend
does not yet expose occurrence-level variant targets or overload selection.
Identifier ranges use the shared `Positions` API.

Parameter and local hover uses the compiler's `BindingDeclaredType` side table
and exact `BindingId` to show declared type syntax at both declarations and
references, including shadowed names. When the compiler supplies only a
source-line declaration position, the provider recovers a binder only if that
line has exactly one `Ident:` token; the type record remains keyed by
`BindingId`. The annotation source span is bounded to 2,048 bytes per binding
and 65,536 bytes per document, encoded as hex in the worker record, checked
against the accepted source in the parent, and copied into owned storage.
Unannotated bindings still show their role and name; inferred types are not
guessed from the local type pass.

For uniquely retained top-level functions, the hover also carries the exact
source header from the parser-identified declaration through its top-level
colon. The header therefore preserves generic binders, typed/defaulted
parameters, return annotations, and declared effects without trying to infer
missing type information. It is stored as bounded hex data in the per-snapshot
signature index (2,048 bytes per header, 262,144 bytes per document) so control
bytes in source cannot corrupt the record stream; the analysis worker validates
it before publishing the snapshot. Markdown clients receive a dynamically sized
code fence that stays intact even when a default string contains backticks,
while plaintext clients receive the source header as written. If a declaration
is overloaded, lacks an exact retained identity, or falls outside the size
budget, hover falls back to the concise declaration summary. Floors:
`test/general_hover_test.sh`, `test/signature_help_test.sh`, and
`test/failed_analysis_request_test.sh`.

The source-only loop-capture fallback runs only while the cursor is inside its
pipe-delimited capture list. It returns that exact range in the negotiated
UTF-8/UTF-16 encoding and formats its heading for Markdown or plaintext
clients. Its current pipe/comma scan is still not a parser: nested/default
expressions and strings containing delimiters need compiler-provided loop
header/capture data. Floors: `test/general_hover_test.sh` and
`test/hover_test.sh`.

The private `$/elisa/stats` result also exposes cumulative analysis counters:
`tokenize_calls` counts full-source calls through the shared tokenizer,
`parse_calls` and `check_calls` count parser/checker calls from analysis;
semantic-token classification reuses the already-tokenized array. The separate
comment-span extraction API is not included in `tokenize_calls`.
`adapter_query_calls` counts
each invocation of a `frontend_adapter.elisa` read accessor; and
`symbol_index_build_calls` / `occurrence_index_build_calls` count the two
semantic-token index builds per analysis. These are call counts, not timings,
token totals, or counts of lower-level work performed inside the compiler.
They are process-wide and do not reset between documents. The cache regression
test asserts that all remain fixed while semantic tokens, hover, symbols,
folding, selection, definition, and references are served, and that only an
accepted edit advances them. Its `line_index.build_calls` counter likewise
stays fixed across worker-produced caches and repeated foldingRange, selectionRange,
signatureHelp, loop-header hover, and general hover requests; it advances for accepted snapshots
that fit the retained budget. `fallback_build_calls` includes one shared worker
fallback per over-budget accepted analysis and request-local fallbacks in the
position handlers. The cache test exercises the first over-budget line count
and verifies the next in-budget edit returns to the sidecar. Floor:
`test/analysis_cache_test.sh`.

The release-facing status table is maintained in `docs/known-issues.md` and linked from the feature manifest; update it when a capability or toolchain gate changes.

## Bounded observability (R05)

The server keeps stderr separate from the LSP stdout stream. New structured
observability is opt in with `ELISA_LSP_LOG_LEVEL=off|error|warn|info|debug`
(numeric values `0` through `4` are also accepted); the default is `warn`, so
normal successful sessions do not emit method traces. `info` records one line
per decoded request with the method, monotonic elapsed milliseconds, current
document generation when applicable, cache outcome, and analysis state.
`debug` additionally records accepted document generation/version transitions.
Compiler status is reported once at process startup at `info` level and states
that the embedded frontend is compiler backed, names the frontend contract
version, and identifies the isolated worker packet schema. No request ID, URI,
source text, or full document content is written. There is no wire trace mode
in the shipped server; clients that need wire inspection should capture the
framed protocol outside the process and treat that capture as sensitive.

Stage timing is a separate opt-in diagnostic controlled by
`ELISA_LSP_TIMINGS=1|true|yes|on`. When enabled, each completed message emits
one bounded `event=stages` line at `info` level with decode, edit application,
line-index, lex, parse, semantic-check, indexing, provider-query,
serialization, queue-wait, and transport observations. The private
`$/elisa/stats` result includes a top-level `timings` object for the last
completed message, with the same fields and an explicit `enabled` flag. The
analysis worker carries lex/parse/check/index durations across its validated
internal packet, so child work is not silently omitted from the parent report.
`serialization_ms` covers LSP frame-header construction and `transport_ms`
covers the bounded stdio read/write transactions. For a request deferred until
its analysis snapshot is ready, `queue_wait_ms` measures from queue insertion
through replay after the matching worker result is committed; synchronous
provider calls and document jobs without a waiting request report zero there.
All values are integer milliseconds and may be zero for sub-millisecond work.
Timing collection adds no clock reads when disabled. The timing probe is
headless and is covered by `test/timing_test.sh`; it starts only the LSP
subprocess and never launches VS Code, Electron, or an extension host.

All stderr writes, including existing bounded warning/error messages, share a
process-wide byte budget. `ELISA_LSP_LOG_MAX_BYTES` defaults to 65,536 bytes
and accepts 1,024 through 4,194,304. Once the budget is consumed, later bytes
are dropped; duplicate failure families remain capped by their existing eight
lines plus a suppression marker. Invalid level or budget values fail before
the server reads input. The private `$/elisa/status` request returns the
effective logging level/budget, bytes written, source/wire-trace policy,
JSON-RPC/LSP/worker/diagnostic compatibility versions, embedded compiler
status, frontend contract version, and all active transport/document/analysis
limits. Its `searchCoverage` object reports that references and document
highlights are partial and same-document only, lists the exact reference
identity subset, and states that an empty references result does not prove
project-wide absence; the workspace index is unavailable. This is provider
coverage metadata, not a live progress indicator. The request performs no
workspace lookup or project-code execution. Floors: `test/observability_test.sh`
and the private status entry in `docs/feature-manifest.json`.

## Same-document references (F04 subset)

`textDocument/references` reuses only the retained `d` edges generated from
the compiler's exact definition-reference side table. The declaration's exact
range is the identity key, and results are locations in the queried document
only; no name-based or workspace-wide fallback is used. The request requires
one `textDocument`, `position`, and `context.includeDeclaration` field with
valid types. Results are deduplicated and sorted by source position, and the
declaration self-edge is omitted when `includeDeclaration` is false. Unsupported
targets, closed or unknown documents, and cursor positions outside an edge
return `[]`. The supported symbol subset is the same unique top-level,
unqualified function subset as definition. Floor: `test/references_test.sh`.

## Safe local rename (F07 bounded slice)

`textDocument/prepareRename` and `textDocument/rename` accept only one
unambiguous parameter or local occurrence backed by a retained compiler
`BindingId`. Prepare returns that exact occurrence range and placeholder. Rename
collects every exact occurrence with the same owner and serial, includes the
binder declaration, sorts and checks the ranges for overlap, and returns a
versioned `TextDocumentEdit` in the negotiated UTF-8 or UTF-16 units. The
message loop compares the captured document generation and version again
immediately before emitting edits; the server never mutates document text as a
side effect of a rename response.

The proposed name is decoded from JSON and must lex as exactly one identifier
using the compiler lexer pinned by the release manifest. To guard against
capture while lexical-scope intervals and scratch semantic re-analysis are
unavailable, a different spelling is accepted only when its bytes do not occur
anywhere in the source snapshot. That intentionally rejects names mentioned
only in comments or strings. The lexer leaves parser-context words as ordinary
identifiers, so this slice also declines plain lowercase words; it accepts
names containing an underscore, uppercase letter, digit, or Unicode byte until
parser-context validation is implemented. Top-level symbols, unresolved
tokens, generated bindings, cross-file references, and post-edit binding-graph
comparison remain unsupported. Unsupported targets or conflicts return
`null`. The UTF-8/UTF-16 fixtures apply returned edits to a copy and
verify that only the selected binding changes. Floor: `test/rename_test.sh`.

## Document highlights (F04 subset)

`textDocument/documentHighlight` consumes the same retained resolver edges
and exact target identity. A function declaration is a `Text` highlight and
resolved calls are `Read` highlights. Parameters and locals are selected by
their exact `BindingId`; their first source-ordered range is the declaration,
an exact identifier followed by the direct `<-` operator is a `Write`, and
other non-declaration uses are `Read`. The compiler does not yet expose
read/write occurrence roles, so this provider recognizes only direct
assignment targets; indirect member/index writes and other assignment forms
remain unclassified by syntax. Fields, overloads, unresolved names, and other
unsupported symbol kinds return `[]` instead of being matched by spelling.
The provider returns same-document ranges in the session's negotiated position
encoding. Floor: `test/document_highlight_test.sh`.

## Definition (F03 subset)

`textDocument/definition` uses exact same-file resolver records. Unique,
unqualified top-level functions continue to resolve through compiler definition
edges; parameter and local occurrences resolve through their retained
`BindingId` group to the declaration span. Nested same-spelling locals remain
distinct. Overloaded or module-scoped top-level functions, unresolved names,
and unsupported declaration categories return `null` instead of using a name
fallback. Clients declaring `textDocument.definition.linkSupport` receive
`LocationLink[]` with exact origin and target token spans in the session's
negotiated encoding; the target range equals its selection range until the
resolver retains enclosing syntax-node spans. Other clients receive the legacy
`Location` shape. Floor: `test/definition_test.sh`.

## Selection ranges (E04)

`src/features/selection.elisa` answers `textDocument/selectionRange` for every
requested position with an innermost→outermost `parent` chain: the word under
the cursor (boundary policy: a cursor at a token's end selects it), the full
line, each enclosing indentation block, and the document. Blocks are derived
from indentation exactly like folding (blank lines transparent); containment is
asserted by the test. Ranges use negotiated units through `Positions`. A
character past a valid line clamps to that line's end. If any requested line is
past the document, the request returns `null` rather than a range that cannot
contain its corresponding position. An open empty document still returns a
zero-width chain for its valid `(0, 0)` position, and an empty positions array
returns `[]`. Floor: `test/selection_test.sh`.

## Incomplete-source containment (A04)

Malformed and half-written source never ends the session. The frontend is
already tolerant enough that every provider (tokens, symbols, folding,
selection, hover) answers during broken states and diagnostics are still
published; a later valid edit recovers with clean diagnostics and fresh
tokens. `test/incomplete_source_test.sh` drives 13 adversarial states
(unfinished declarations, dangling delimiters/selectors, half-written
generics, incomplete interpolation, unterminated literals/comments, deep
bodies) through every provider. Separately, accepted snapshots run in a fresh
child so a panic, abort, or hang inside the embedded frontend cannot take down
the server. The parent drains a packet whose bounded header carries snapshot
identity and individual payload lengths while the child writes, enforces one
monotonic deadline, validates every segment and identity, and commits only a
complete successful result. Cache segments are copied directly from packet
spans into document storage, avoiding temporary arrays for every result; the
diagnostic span is written directly to stdout.
`test/analysis_worker_test.sh` injects a child crash, infinite wait, and
malformed packet into a temporary server copy; each case must preserve
source-only requests and recover on the next edit. It also delays a worker
while the parent dispatches cancellation, status/stats requests, a replacement
edit, and shutdown. Pending analysis-backed requests keep their framed body and
typed JSON-RPC ID in a bounded queue-owned byte buffer; only requests matching
the validated current job are replayed. Cancellation removes one request while
keeping a shared analysis job alive for other waiters. The POSIX adapter's own
test covers pipe-capacity streaming, timeout and termination kill/reap,
descriptor/signal isolation, and repeated cycles.

The parent now advances a persistent bounded frame decoder over bytes already
available in its input buffer. An incomplete header or body returns to the
event loop; stdin is polled before another bounded read, and progress is kept
without rescanning the accumulated frame. `test/transport_test.sh` checks
byte-at-a-time fragmentation and pipelining; `test/transport_limits_test.sh`
checks malformed, truncated, and oversized frames. The POSIX readiness wait
also polls stdin and the active worker result pipe together, reports either or
both ready sources, and checks termination and the worker deadline. Its native
test covers input-only, worker-only, and simultaneous readiness, bounded caller
waits, deadline expiry, incremental reads that return immediately when no
bytes are ready, packet collection across chunks, EOF, nonblocking reap, and
nonzero-exit rejection; 25 ms deadline-check slices do not shorten a caller's
requested wait. The parent now waits on stdin and the active worker pipe
together. It continues decoding client frames while a child computes, handles
an edit by aborting the obsolete child and queuing only the latest snapshot,
then validates and commits the result in the parent. A single foreground child
and bounded per-document/request queues are in place. Queued cursor-provider
requests promote their snapshot ahead of diagnostics-only work; the regression
holds one worker active and verifies a later hover-requested snapshot completes
before an older background diagnostic snapshot. Diagnostic debounce, scheduler
fairness under sustained input, and workspace background scheduling remain open
Q01 work.

The process boundary has a directional same-workload measurement in
`bench/analysis-worker-overhead-2026-10-06.json`. A temporary in-process
baseline preserves analysis, provider projection, packet encoding, parent
validation, and cache publication, and replaces the fork/pipe/wait channel
with an in-memory byte channel. Five alternating fresh-process samples per
case produced identical semantic-token payloads. Median didOpen-to-diagnostics
times for 1, 32, 256, and 2,048 constants were 28.148/0.649 ms,
28.053/1.404 ms, 35.977/8.649 ms, and 251.690/213.967 ms for isolated versus
in-process execution. Retain the one-shot child for crash and hang containment
while Q01 defines responsive dispatch and restart behavior for any reusable
worker; the in-process benchmark baseline has no such containment and is not a
production mode. Results are directional evidence from one Darwin/arm64 host,
not a portable timing threshold. The comparison can be reproduced with
`python3 bench/analysis_worker_overhead.py`.

## Semantic token ranges (H05)

`textDocument/semanticTokens/range` filters the cached full result instead of
re-analyzing: `semtok_filter_range` decodes the delta-encoded array, keeps
entries intersecting the requested range, and re-encodes from document zero
(never the range start), so the output is a position-compatible subset of the
full result. Malformed shapes, negative coordinates, and reversed ranges
receive `InvalidParams`; a valid ordered range that extends past the document
is filtered against the tokens that exist in the cached result. Unknown URIs
and empty ranges return `{"data":[]}`. Floors: `test/semantic_range_test.sh`.

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

Validated targets: Darwin/arm64 and Linux/aarch64. Other platforms and
architectures build at your own risk; build.sh warns but proceeds. Windows
support is explicitly out of scope until transport, paths, watcher, and linker
gaps are closed (R04).
