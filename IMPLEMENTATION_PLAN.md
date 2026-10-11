# Elisa LSP implementation plan

> Planning baseline: 2026-09-12. This is a proposed implementation roadmap, not a claim that the work below is complete. It is based on the current working tree, including pre-existing uncommitted changes, rather than only commit `47a7f18`.

## 1. Objective and definition of success

Make Elisa's language server dependable enough to remain open throughout a full development day, precise enough that users can trust navigation and edits, responsive enough to feel immediate, and complete enough to support real multi-file Elisa projects in multiple editors.

“As close to perfection as possible” means continuously demonstrated correctness and usability. It does not mean advertising every optional LSP capability, duplicating the compiler's semantics in the server, or adding advanced refactorings before source positions and symbol identity are trustworthy.

The implementation should achieve these outcomes:

1. Every accepted request completes exactly once, with a valid result or appropriate error; notifications never produce response objects.
2. Malformed JSON, broken source code, interrupted transport, rapid editing, and compiler failures have bounded, tested behavior.
3. Every feature uses the correct document URI, source snapshot, project configuration, and position encoding.
4. Diagnostics, highlighting, completion, navigation, hover, references, and rename agree about what a symbol means.
5. Unsaved edits participate in project analysis, including changes in dependencies.
6. Editing operations preserve unrelated source and fail safely when their semantic preconditions cannot be established.
7. Interactive work takes priority over background work, and retained memory stays bounded across long sessions.
8. A clean checkout can be built and tested using documented, reproducible dependencies.
9. Capabilities and output adapt to the client; basic functionality does not depend on one custom editor integration.
10. Every released feature has regression tests, user documentation, performance evidence where relevant, and a supported fallback.

### 1.1 Priorities

| Priority | Meaning | Release policy |
|---|---|---|
| P0 | Protocol integrity, source identity, data corruption, crashes, reproducibility | Blocks a trustworthy foundation release |
| P1 | Essential everyday editing and analysis accuracy | Required for the daily-driver release |
| P2 | Productivity, scaling, client polish | Ship behind capability/configuration gates as validated |
| P3 | Advanced or ecosystem-dependent functionality | Implement only after foundations and a concrete use case |

### 1.2 Work item conventions

Each numbered work item below specifies its intended location, dependencies, implementation steps, and an acceptance gate. All unchecked items are planned. Proposed filenames are architectural destinations, not files that already exist. Compiler work belongs in the compiler repository and needs coordinated compatibility changes; a checkbox in this file does not authorize changing those repositories as part of this planning task.

Implementation order follows dependencies, not section length. Estimates use S (one focused change), M (several related changes), L (a substantial subsystem), and XL (cross-repository or exploratory work). These are relative sizes, not delivery promises.

## 2. Repository baseline and evidence

### 2.1 Initial architecture observed before implementation

The architecture and source-observation tables in 2.1 and 2.3 are the baseline that motivated this plan. They are historical; use the implementation checklists and the current verification record in 2.4 for later progress.

| Location | Responsibility at drafting baseline | Strength to retain | Limitation to address |
|---|---|---|---|
| `src/main.elisa` | Stdio framing, dispatch, lifecycle handlers, document storage, a specialized hover | URI-indexed documents; cached results; one semantic check per accepted update | Many responsibilities; synchronous analysis; no lifecycle state or document versions |
| `src/json.elisa` | Recursive-descent JSON values and deferred string decoding | Source-span representation avoids unnecessary copies | No explicit parse failures, strict grammar checks, or resource limits |
| `src/diagnostics.elisa` | Include compiler frontend, lex/parse/check, serialize diagnostics | Frontend remains the semantic source of truth | Direct sibling include; line-only LSP mapping; no version or diagnostic code |
| `src/semtokens.elisa` | 48-entry legend, lexical and semantic classification, interpolation/comment spans, encoding | Cached full responses; compiler lexer; local/parameter classification; enum variants | Byte columns, repeated lexing, line/name identity, heuristic classification, linear lookups |
| `test/*.sh` | Seven server smoke scripts plus a separately compiled JSON probe | Real subprocess coverage, useful escape and multi-document regressions | Mostly output matching rather than full protocol validation; inconsistent process checks |
| `docs/highlight-taxonomy.md` | Desired lexical and semantic taxonomy | Rich Elisa-specific categories | Mix of implemented behavior and future intent |
| `docs/highlight-palette.md` | Custom token palette and index mapping | Documented editor contract | Manual synchronization; some compiler API descriptions are stale |
| `build.sh`, `project.json` | Object compilation and native linking | Small, understandable build | Default compiler path, no pinned frontend compatibility, no clean-build CI in this tree |

The current working tree already contains multi-document caching, JSON-decoded URI lookup, semantic-result reuse, and enum-variant highlighting changes. Preserve those improvements and their tests. Do not treat the project as an empty LSP skeleton.

### 2.2 Initial validation performed when the plan was drafted

The following scripts returned success against the existing `build/elisa-lsp` executable:

- `test/handshake_test.sh`
- `test/diagnostics_test.sh`
- `test/escapes_test.sh`
- `test/semtokens_test.sh`
- `test/fstring_semtokens_test.sh`
- `test/hover_test.sh`
- `test/multi_document_test.sh`

Important limits of that evidence:

- The executable's filesystem timestamp is September 3, 2026. Its correspondence to the current source and adjacent compiler checkout was not established.
- `$HOME/.elisac/elisac`, the default used by the scripts, is absent; `ELISAC` was unset and `elisac` was not found on PATH during inspection.
- A fresh build and the independently compiled `test/json_smoke.sh` were not run. Establishing a reproducible fresh-build baseline is therefore the first implementation milestone.
- The existing tests exercise happy paths and selected regressions. Passing them does not establish Unicode correctness, transport conformance, workspace correctness, latency, or long-session stability.
- No runtime bug claims below should be read as new reproductions unless explicitly described as such. Most findings are direct source observations and resulting risks.

### 2.3 Initial confirmed source observations

1. `read_byte` allocates a one-byte array and performs a read syscall for each byte. `read_message` uses it for both headers and bodies.
2. `content_length_of` accumulates digits while ignoring other characters, has no overflow check, and only recognizes one exact header spelling.
3. `send_message` performs one `write` and ignores partial-write and error handling.
4. `Json::parse` has no success/error result and does not require complete input consumption. Literal and number parsing are permissive, and string decoding accepts unknown escapes.
5. JSON object keys and method lookup use raw escaped spans. URI lookup explicitly decodes values, so equivalent JSON encodings of URIs already work; the same consistency is not universal.
6. `extract_id` retains raw string escape spelling. Preserve valid ID echo behavior while adding validation; do not assume that this raw-span strategy itself breaks all escaped IDs.
7. `main` ignores unknown methods, always returns exit status zero for `exit`, and has no explicit initialize/shutdown state machine.
8. `LspDocument` has no version, open-state flag, generation, dependency information, or retained semantic snapshot.
9. `request_text_value` reads only the first `contentChanges` entry. The server advertises full synchronization, but it still needs an explicit policy for multiple replacements and malformed change payloads.
10. `check_and_publish` checks source before committing its text. A failed analysis therefore risks leaving the server's authoritative text behind the client's accepted edit.
11. Closing a document sets `text_len` to zero but does not publish empty diagnostics, reclaim its retained allocations, or remove the URI slot.
12. Document and token storage reuse existing reservations, but growth leaves old reservations in the flat storage buffer. Unbounded URI churn also retains slots.
13. A semantic table is shared between diagnostics and token computation for an update, but comment generation used to invoke a second lexer API; the compiler-backed combined token/comment entry point now removes that duplicate LSP scan. Other copies, sublexes, and provider scans remain to be measured.
14. `diagnostic_json` emits end character `999` on the diagnostic line. The adjacent compiler's `Semantic::Diagnostic` already contains an `Ast::Pos` with offsets and start/end coordinates, with defaults for checks not yet migrated.
15. `occurrence_ttype` scans `ref_line`, `ref_name`, and `ref_kind`. Top-level and enum lookups also scan arrays; repeated lookups can become expensive as files grow.
16. Semantic-token columns and lengths are byte-based. F-string handling explicitly assumes a single line, and subtoken classification is given lexer line values that the surrounding comment describes as stale.
17. Identifier text categories are chosen before resolved bindings. A contextual-keyword spelling used as an identifier can therefore override a valid semantic classification.
18. Bare enum variants and shorthand members can be selected by a global name match, and member calls are inferred from following punctuation. These are useful fallbacks, not sufficient evidence for navigation or rename.
19. Hover reads `position.line` but not `position.character`, scans pipe delimiters and commas in source text, and manually embeds generated content into JSON.
20. There is no repository-local workspace manager, completion provider, symbol navigation, references, rename, signature help, formatting provider, scheduler, benchmark suite, CI configuration, or README in the inspected file inventory.

### 2.4 Implementation-time verification and blockers (updated 2026-10-06)

- **Latest d4 artifact with incremental POSIX worker I/O (2026-10-06):** Rebuilt at `2026-10-06T04:23:09Z` with release flags `-O2 -fno-builtin -Wl,-v`, clean compiler/frontend commit `d4b40e36770d89973de1b8df93f8e0bcd091ae6a` (compiler source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`), and supported Go stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`. The manifest records LSP inputs `89235f38a9befed55a031feaa36099e76e4a4411a0700a1a7afa50613e3bd7bc`, a 624-file include closure `e34860e39733e2e690ab3e6f654b57a3c46074d479456e5ed3da74d402c3f876`, object SHA-256 `62027b11fee758a8017fa3090208eb395d582eaac133e091c2dc42955908ce90`, and executable SHA-256 `73117331b49edb3a1140a77239e9e58a17db920c61c6ccb5a42f3a6f6d812e6f`. Strict freshness and the canonical suite pass on this exact source tuple (`81/81`). Native worker coverage now also verifies nonblocking partial reads, EOF, successful reap, and abnormal-exit rejection. These C primitives are not yet connected to the Elisa scheduler; worker launch, packet validation/commit, cancellation, and message dispatch remain synchronous, so Q01 runtime acceptance is still open. Compiler padding/effect diagnostics remain advisory and untriaged.

- **Latest d4 artifact with resumable frame intake (2026-10-06):** Release rebuilt at `2026-10-06T03:50:16Z` against clean compiler/frontend commit `d4b40e36770d89973de1b8df93f8e0bcd091ae6a`, compiler source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`, and supported Go stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`; flags are `-O2 -fno-builtin -Wl,-v`. Manifest: LSP inputs `2118de6729356db91e7df1106c90f7328ad6f2ebbe051e662cdec7c7b2204643`, 624-file include closure `e34860e39733e2e690ab3e6f654b57a3c46074d479456e5ed3da74d402c3f876`, object `0253fb4dc8c56776de7bd0e0ab1e01921f918260fba471792e4ee50b3c2e78a2`, and executable `ef6cac67947d5e1f6dbbc0cabcf05367bd37094eabc6e33d675402a2c7f223b8`. The one-shot reader is replaced with a persistent header/body decoder; incomplete frames return to the outer loop, which waits for input readiness before reading another bounded chunk. Byte-at-a-time fragmentation, pipelining, strict transport limits, protocol lifecycle, and signal-driven shutdown tests pass. The exact-input canonical suite reports `pass=81 fail=0`, and strict freshness passes. This makes frame intake resumable but does not satisfy Q01 acceptance: analysis and worker-packet collection remain synchronous, so edits, cancellation, and shutdown cannot be dispatched during active analysis.

- **Latest d4 artifact after readiness-timeout correction (2026-10-06):** Rebuilt at `2026-10-06T03:40:06Z` using clean compiler/frontend commit `d4b40e36770d89973de1b8df93f8e0bcd091ae6a`, source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`, supported Go stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and `-O2 -fno-builtin -Wl,-v`. Manifest: LSP input SHA-256 `91f1450931268d710a3393797fafd844152a4ad172d93d2cad23292c709fc9c9`, 624-file compiler-emitted include closure SHA-256 `09b6568c62e7ed97a517469a4296eb87043ea512a846862f4da795cfcfc9aa1f`, object SHA-256 `922acdb3f813b5d290525ed218f2471144e9d8f7be16dd52195caee9129c462a`, and executable SHA-256 `91c17f827893dd8cc8934b889fb39d855f3b47e9f9cb062fec74f00d6b5d903e`. Strict freshness passes. A native deadline regression caught that 25 ms worker polling slices could return early instead of honoring the caller's longer wait; the helper now waits through those slices until readiness, the caller timeout, termination, or worker deadline. The focused native suite passes input-only, worker-only, simultaneous readiness, caller-timeout, and worker-deadline cases on this current source. The 81/81 canonical suite passed on the immediately preceding readiness-helper revision; this follow-up changes only the C helper, which remains unused by the Elisa dispatch loop. The scheduler's runtime acceptance is still open.

- **Latest d4 LSP artifact with Q01 readiness foundation (2026-10-06):** Rebuilt at `2026-10-06T03:20:03Z` against clean compiler/frontend commit `d4b40e36770d89973de1b8df93f8e0bcd091ae6a`, compiler source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`, supported stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and `-O2 -fno-builtin -Wl,-v`. The manifest records LSP inputs `f4ee88c6a44b55caf5cf0f341b8ce76072c0bd1585ee0fe75d218dfdcd0ed093`, a 624-file compiler-emitted include-closure hash `09b6568c62e7ed97a517469a4296eb87043ea512a846862f4da795cfcfc9aa1f`, object SHA-256 `efbd94dfb255fbc66dd783dd671c926b9ef6ad9041cf691c253e674cb3da39bc`, and executable SHA-256 `88dd4607b9038b4e61d5ad900638a58096fa5e4a0eab9768ad6a81193fe6a585`. Strict freshness passes. The exact-input canonical suite, whose isolated server builds are pinned from this manifest, reports `pass=81 fail=0`; after expanding native event coverage, `test/analysis_worker_posix_test.sh` also passes for input-only, worker-only, and simultaneous readiness. The added C readiness primitive remains unused by the Elisa server loop, so Q01's responsive-dispatch acceptance is still open. Compiler padding/effect warnings remain advisory and untriaged.

- **Compiler optimization-integration refresh (2026-10-06):** Rebuilt against clean compiler commit d4b40e36770d89973de1b8df93f8e0bcd091ae6a (source fingerprint 32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638), which includes recent owner-indexed lookup chains, memoized O(1) collection-stack lookup, and narrower enum/module visits. This replaces the previous compiler pin 6b475d894331f0a81c3112167ef7fcf5c642a424; the selected optimized integration is an active development commit and has not yet landed on origin/main. The compiler added diagnostic kinds, so the generated LSP mapping and diagnostic-span inventory were refreshed to 641 kinds and 1,093 constructor sites. The unsupported-construct audit was rerun on the pinned compiler and all 19 rejection probes still match. At refresh time, the Darwin/arm64 release was built at 2026-10-06T01:19:00Z with the supported Go stage0 binary SHA-256 5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e and -O2 -fno-builtin -Wl,-v. Manifest tuple: LSP inputs 290af215e13e0afaac86096fd00937bd7e9b68511d3b9165f80c14a1a58164e6, 624-file include closure SHA-256 7c2004430d029ca074e5fa0f759b0ec005249defbcb7607c61917c9ddbf6f269, object SHA-256 0dacf17b346e92d9188e814d8b4d83c9d950aa715a930e30289e88d8ce19423c, and executable SHA-256 526f86af0ef327308b81fc4245e057f41a4f58ebe24ff86d9e01c482d1155ac0. Strict freshness and the exact-input canonical suite pass (81/81). New compiler struct-padding/effect-analysis warnings are visible in build output and still need triage. A three-sample 5,000-function comparison against the previous clean 6b475d8 compiler snapshot used the same current LSP source except for the generated diagnostic adapter (640 versus 641 kinds): d4b40e3 reduced median clean-open/edit/hover round trips from 1.108/1.212/0.960 s to 0.925/0.787/0.829 s, while cached-token median rose from 0.029 s to 0.035 s and process peak RSS rose from 111.4 MiB to 113.5 MiB. Both storage soaks ended with zero tracked live bytes. Raw reports are bench/compiler-6b475d-control-2026-10-06.json and bench/current-compiler-d4b40e3-2026-10-06.json. This is directional evidence from one Darwin host and three samples, not a stable threshold; investigate the cached-token/RSS tradeoff and repeat on supported hosts. Stage1 parity and current-pin Linux validation remain open.

- **Latest d4 LSP artifact after references/highlight work (2026-10-06):** The release was rebuilt at `2026-10-06T01:57:18Z` with clean compiler/frontend commit `d4b40e36770d89973de1b8df93f8e0bcd091ae6a`, source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`, supported Go stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and release flags `-O2 -fno-builtin -Wl,-v`. The manifest records LSP inputs `2804d1ea45a7eab26795f36da51578e0aed73276d9be9d17163d4d25e6101b3f`, a 624-file include closure SHA-256 `78eeb60f329f6124a65c288e56411c4f21fc8d9aad9865ad1609229d7f7fa152`, object SHA-256 `ecc076437cf4c9127e4847ba752aed552f0c9ada896d3405fdb2ea2782211924`, and artifact SHA-256 `95257d0cd3ef71a606ee7155a98de331fcc3872ddfa6e2776cf51e0517279790`. Compiler sources are clean; the manifest marks the LSP working tree dirty because this implementation remains uncommitted. Strict freshness passes and the full canonical suite on this exact artifact reports `pass=81 fail=0`. Compiler padding/effect warnings remain visible and open for triage. This tuple supersedes the earlier 01:19 build tuple above; the optimizer comparison remains the separately recorded controlled d4-versus-6b report.

- **Latest d4 LSP artifact with explicit search-coverage status (2026-10-06):** Rebuilt at `2026-10-06T02:12:55Z` against clean compiler/frontend commit `d4b40e36770d89973de1b8df93f8e0bcd091ae6a`, source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`, supported Go stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and `-O2 -fno-builtin -Wl,-v`. The manifest records LSP inputs `7a155e8d642d7ccdf923e7e67b67f42e6227bbea5ecc1b7078b87d6d989e96b2`, a 624-file compiler-emitted include closure SHA-256 `9578cd683e3a14ef85ee02e9f7ea267709ddced506c5368bf3a2c003a2f98d4d`, object SHA-256 `aa20c8da27cc3c0109e2736dff7d3cb88c8766b66b562f848c02d51bb5ff81ed`, and executable SHA-256 `26d9ad374c6df1b640365cab3189665b85736294d9df62a800e6eb61ce115b71`. `$/elisa/status` now reports references/highlights as partial and same-document only, discloses the exact references identity subset, and states that an empty references result does not prove project-wide absence; workspace indexing is unavailable. Strict freshness and the exact-input canonical suite pass (`81/81`). The compiler source is clean and the LSP source remains uncommitted in the working tree. Compiler effect-analysis and struct-padding advisories remain open for triage.

- **Latest d4 LSP artifact after H04 readonly-constant indexing (2026-10-06):** Rebuilt at `2026-10-06T02:39:06Z` from clean optimizer-integration compiler commit `d4b40e36770d89973de1b8df93f8e0bcd091ae6a`, source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`, supported stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and `-O2 -fno-builtin -Wl,-v`. The manifest records LSP inputs `f9d1a3143d58a0cf7a8c9b0de5e735685aa08cbd0262f08630d0316a69ba2a92`, a 624-file compiler-emitted include closure SHA-256 `09b6568c62e7ed97a517469a4296eb87043ea512a846862f4da795cfcfc9aa1f`, object SHA-256 `c1ce202fdf85bdbbbcce1e3f5e86eb96b49e9651742e24c0fee07e04aba65a81`, and executable SHA-256 `be2ed3ade90e60d9e5b078097014312cfcb851fe8c5521b7690329c0b60cc182`. This artifact contains the collision-safe immutable-constant index used by semantic-token readonly classification. Strict freshness passes and the full canonical `test/run_all.sh` suite reports `pass=81 fail=0` on the exact input. The matched three-sample benchmark reports open-to-diagnostics medians of 430.763 ms versus 235.458 ms at 2,048 constants and 1,663.331 ms versus 898.263 ms at 4,096 constants; the samples include frontend analysis and cache construction and are directional evidence from one Darwin/arm64 host. The compiler source is clean; the LSP working tree remains uncommitted. Compiler struct-padding/effect-analysis advisories, stage1 parity, and current-pin Linux validation remain open.

- **A04 isolated-worker boundary comparison (2026-10-06):** `bench/analysis_worker_overhead.py` built a temporary in-process baseline from the same LSP/compiler inputs. The baseline preserved lex/parse/check, provider projection, packet encoding, parent validation, and cache publication, replacing only the POSIX child/pipe channel with an in-memory byte channel and direct fall-through. Five alternating fresh-process samples per workload on Darwin/arm64 returned identical semantic-token payload hashes. The `didOpen`-to-diagnostics medians (isolated versus in-process) were 28.148/0.649 ms for 1 constant, 28.053/1.404 ms for 32, 35.977/8.649 ms for 256, and 251.690/213.967 ms for 2,048; estimated boundary deltas were 27.500, 26.649, 27.328, and 37.723 ms. Candidate uses the exact release artifact above; both builds use compiler d4b40e3 source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638` and the same stage0 SHA-256. Keep the one-shot boundary for crash/hang containment while Q01 defines responsive dispatch and any restartable worker lifecycle; the in-process baseline has no fault containment, and the comparison is directional, single-host evidence rather than a latency gate. Raw samples and both artifact hashes are in `bench/analysis-worker-overhead-2026-10-06.json`.

- **H02 exact resolved function-use precedence (2026-10-06):** The LSP builds an offset-keyed index of compiler `DefinitionReference` edges once alongside its existing symbol index. Semantic-token classification uses an exact source span and target declaration before contextual-keyword or spelling fallbacks. Call-position fallback recognizes actual lambda syntax by checking its balanced parameter list and following body marker (`=>` or `:`), including an optional return type; an unresolved ordinary `fn(...)` remains a call. Regressions verify a function named `get` at its declaration and f-string interpolation use, a function named `fn` at declaration and call, and a lambda with an explicit result type. `test/precedence_test.sh`, `test/semtoken_families_test.sh`, `test/fstring_semtokens_test.sh`, `test/semtokens_test.sh`, `test/analysis_cache_test.sh`, `test/diagnostic_span_inventory_test.py`, `test/unsupported_constructs_test.sh`, `test/frontend_contract_test.sh`, and `test/manifest_test.sh` pass. The exact canonical `test/run_all.sh` run reports `pass=81 fail=0`. Release artifact: compiler HEAD `6b475d894331f0a81c3112167ef7fcf5c642a424`, source fingerprint `8188a8bcf5ee1f4dc57c6e49e63b247d36720e642141238e472d31392e6cfdf7`, supported Go stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and `-O2 -fno-builtin -Wl,-v`. Manifest tuple: built `2026-10-05T23:06:23Z`, LSP inputs `a24f5e5e1e600e6dfbb1f2ecb8ea8ed401acda2587631c585bdca0c913eeb5ee`, 623-file compiler-emitted include closure SHA-256 `8eb3d89a49a15b456171bfade944b777a73d9d8e126422bab8cbe4bb0841c817`, object SHA-256 `31513407f5856131a62b37c46fd7666b1a2e0a88a85597228ca80e4e58b9dfc5`, and executable SHA-256 `716b6d17b14983db6b0d3eecc22d99faa4bf466529774e5f4fc47f9931a86edc`. Strict build freshness passes. H02's remaining field/method/callable-value/module/alias/type/operator identity and ambiguity work remains open; no stage1 parity or performance claim is made.

- **H03 nested f-string span slice (2026-10-06):** The latest compiler accepts nested f-string syntax. `src/semtokens.elisa` recursively expands nested f-string tokens using the parent interpolation's absolute byte coordinates, emits inner literal and brace spans without overlap, and stops at depth 16 by coloring the remaining nested lexeme as one string span. The recursion-depth variable is distinct from the brace-matching counter. `test/fstring_semtokens_test.sh` checks exact one-level nested spans, an 18-level stress case, and definition/references for the nested parameter use; `test/rename_test.sh` checks exact declaration/use edits under UTF-8 and UTF-16. The existing Unicode, malformed-input, and global ordering/bounds assertions still apply. The canonical `test/run_all.sh` was rerun after the provider-fixture and documentation changes and reports `pass=81 fail=0`; strict build freshness, definition, references, rename, manifest, and JSON validation also pass. Release artifact: latest compiler HEAD `6b475d894331f0a81c3112167ef7fcf5c642a424`, source fingerprint `8188a8bcf5ee1f4dc57c6e49e63b247d36720e642141238e472d31392e6cfdf7`, supported Go stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and `-O2 -fno-builtin -Wl,-v`. Manifest tuple: built `2026-10-05T23:38:15Z`, LSP inputs `7c5145726fca1b3fe0d756e464c2e0d3d25a5144a818c22041cab183bd694c16`, 623-file compiler-emitted include closure SHA-256 `6478125dc606f134305de209dd92abcdef69874d2b9fe9cdf1b1b03017a77091`, object SHA-256 `32eb198da08861c43e2a5029c92943a7159501b0f499e81b92e6184820ac192b`, and executable SHA-256 `c8becaa19ab86cbc2427f3a955281d4227dde58d57c0ac5d7d09059f8e08dc41`. The build uses the latest compiler source snapshot and remains fresh because this follow-up changes fixtures and documentation only. Exact nested parameter identity is verified across definition, references, and rename. No stage1 parity or performance claim is made.

- **Latest-compiler declared-type hover slice (2026-10-06):** The release artifact was built at `2026-10-05T21:48:38Z` for Darwin/arm64 from compiler source fingerprint `8188a8bcf5ee1f4dc57c6e49e63b247d36720e642141238e472d31392e6cfdf7` and supported Go stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e` at `-O2 -fno-builtin -Wl,-v`. The immutable detached compiler snapshot was taken at HEAD `541788548651d43dd466d0b5210955eb966eb18e` with the then-uncommitted parser change. Current compiler HEAD `6b475d894331f0a81c3112167ef7fcf5c642a424` has the same exact source fingerprint, so the built source bytes match the latest compiler despite the manifest recording the prior base commit. Manifest tuple: LSP inputs `82027800920788b16566a52903c085681eaee183796d1187c5f293bc8199f905`, 623-file compiler-emitted include closure SHA-256 `431ab4243b0b00ed03b847e1bb775fbde735f0fc0841bf32e141215aab081174`, object SHA-256 `1b428d3f5574f95dd76d1538883b190dd8298d92831c20f53fca6a584f0a57dc`, and executable SHA-256 `3a31a48f0addafdcfb81c78c901bfe190aa04d5a31a2d2c732dc3b4f349c694a`. Strict build freshness passes. The new slice serves explicit parameter and local annotations keyed by exact `BindingId`, preserves nested type syntax from source, and validates and bounds the worker payload; `test/general_hover_test.sh` passes. The first canonical `test/run_all.sh` run reported `pass=78 fail=3`: its diagnostic-span and unsupported-construct gates were stale at invocation, and the frontend-contract expected vector was one value short after its line-only-position assertion was added. After refreshing the inventory and vector, `test/diagnostic_span_inventory_test.py`, all 19 probes in `test/unsupported_constructs_test.sh`, and `test/frontend_contract_test.sh` pass individually on the manifest-pinned source. The canonical aggregate was not rerun after these targeted fixes. No latency gain or stage1 optimization qualification is claimed.

- **Previous latest-source release checkpoint (2026-10-05 18:15 UTC; superseded by the hover/provider iteration below):** `build/manifest.json` records compiler HEAD `541788548651d43dd466d0b5210955eb966eb18e` and its dirty source tree at fingerprint `d348d596db164ab373f8c664df67cc39d181aabc389274367aa1fd4a43848049`. The build staged that exact source tree immutably, including the latest source-level compiler optimizations observed at launch, and used the supported Darwin/arm64 Go stage0 backend from source revision `f84b9c1034f708f69d048bd6cafb813e88c8210f` (binary SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`) with `-O2 -fno-builtin -Wl,-v`. The release artifact was built at `2026-10-05T18:15:06Z`: LSP input `6d75200f5e8783514c00775f00b30f4ca5938e3c5d6c34c0c328cff7a608f79c`, 623-file compiler-emitted include closure `164b6f86b9e669bc5bf88dfd32a3d914669b7f0a5e33fbd65fed0a4a4ed10f8d`, object SHA-256 `dad9eddcec287f90c4b76289f73bc754d5d60962cd3e5563911971892c135ef0`, and executable SHA-256 `bdcef44846ae66b21502978a968abe7830f4a9d39a56a31a1ce543bacb55a4f6`. Strict freshness passes; the canonical Darwin/arm64 suite passes `81/81`. The regenerated inventories describe 640 diagnostic kinds and 1,091 compiler diagnostic constructors; all 19 unsupported-construct probes pass against this exact compiler/stage0 tuple. A later stable-source stage1 probe first verified a fresh product at SHA-256 `27925891cf3185d91c678d902fc14db4d525d0fa47448f2104f91423c16ee1d1`, then built the stage0 control successfully in 82.582 s but stage1 declined 2,108 backend operations before object emission in 21.565 s. Tests and benchmarks were skipped, so `bench/compiler-upgrade-latest-541-stage1-2026-10-05-build-only.json` is a compatibility probe, not optimizer qualification; no stage1 parity or performance claim exists.
- **Previous hover/provider collision-guard checkpoint (2026-10-05 18:49 UTC; superseded by the single-pass iteration below):** The LSP was rebuilt after making enum-variant hover conservative around ambiguous names and ordinary-declaration collisions. The immutable compiler snapshot is still HEAD 541788548651d43dd466d0b5210955eb966eb18e, source fingerprint d348d596db164ab373f8c664df67cc39d181aabc389274367aa1fd4a43848049; the supported Go stage0 binary is SHA-256 5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e, with release -O2 -fno-builtin -Wl,-v. The artifact tuple is LSP inputs 6f184b21ad021c32037a1ec06484535973e4666ae18eed8f21560e511f79b1d6, a 623-file compiler-emitted include closure hashed 537c2e14085bc6f49b00533b83c93035351669838d7ed0f514688c8c2db9d03d, object SHA-256 a0248ab946c25908512580d52b56e6dda61437de2fb01fcaa6ddd088e668337d, and executable SHA-256 e88c05184d19e1b7362c900fabfced6a0f387eb65b596cc02e4a68335611dbd9. Build freshness and test/general_hover_test.sh pass; the focused test covers unique owner display, repeated-name rejection, and same-spelling ordinary-declaration rejection. The exact updated input passes the full canonical test/run_all.sh suite at 81/81, including test/general_hover_test.sh, test/frontend_contract_test.sh, and test/manifest_test.sh. Strict build freshness passes. No latency or optimizer benefit is claimed. The current compiler source-level optimizations are included in this -O2 stage0 build; stage1 remains unqualified because its most recent fresh product failed to emit the preceding LSP input.
- **Latest single-pass hover resolution (2026-10-05 19:03 UTC):** Declaration and enum-variant resolution now share one traversal of the retained hover record stream, avoiding a second full cache scan per identifier hover. Ambiguous variant owners, cross-category name collisions, and overloaded declarations return no result. The exact current build uses compiler HEAD 541788548651d43dd466d0b5210955eb966eb18e, source fingerprint d348d596db164ab373f8c664df67cc39d181aabc389274367aa1fd4a43848049, and supported Go stage0 SHA-256 5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e with release -O2 -fno-builtin -Wl,-v. Manifest tuple: LSP inputs d696c02d573ef36b1672fad5d0cfaafc085cba7026dcb8493f1489ff63c32320, 623-file include closure SHA-256 5900e26e24be5900250f669b7e8676f1efe35fe232caf45517819553cbe7dc01, object SHA-256 8f5b36c964ca3fb4f05e1f9c160169340d10499cd56f5d161d72c7eab31e2474, executable SHA-256 36b3d50fbc3b19db70a4be16bca04c7a666fa5598c5545b6a44d50ba561d3482. The focused hover and manifest tests and strict freshness pass. The exact final input passes the full canonical test/run_all.sh suite at 81/81, including unique/repeated/colliding enum variants, overloaded declaration names, frontend contract, and manifest checks. Strict build freshness passes. No latency improvement or stage1 performance claim is made.
- **Loop-capture hover range and presentation (2026-10-05 19:18 UTC):** The retained loop-capture summary now triggers only while the cursor is inside its pipe-delimited capture list and returns that list as its exact range. The range uses the negotiated UTF-8 or UTF-16 encoding; Markdown clients receive the existing bold heading, while plaintext clients receive an unstyled heading. Tests cover positions before and after the capture list plus a Greek accumulator under both encodings. The current release was built with latest observed compiler HEAD 541788548651d43dd466d0b5210955eb966eb18e, compiler source fingerprint d348d596db164ab373f8c664df67cc39d181aabc389274367aa1fd4a43848049, and supported stage0 SHA-256 5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e at -O2 -fno-builtin -Wl,-v. LSP input hash 1690462c765e634c2badc4c5f066ce752b5c14565b4b0ff44aedc52af6432933; 623-file include closure SHA-256 a957731d74c529c63d11c47be35a4b1f2d47028656be4766fcd5320cf6aef720; object SHA-256 4420a07fe87f99d30fa41fc22f697dcb1572d459b258a424d27e26a3f03dab1c; executable SHA-256 85ea440f73066fd636f5ffddd28ef2e76cbc8426239dd77a75bc6007b7e2158a. Focused hover tests and strict freshness pass. The exact input passes the full canonical test/run_all.sh suite at 81/81, including the failed-analysis loop-hover range case, the UTF-8/UTF-16 hover range matrix, frontend contract, and feature manifest. Strict build freshness and git diff --check pass. The naive delimiter/comma scan remains scheduled for replacement by frontend syntax data.

- **Upstream `origin/main` compiler snapshot (2026-10-01; superseded by the local checkout entry below):** The compiler worktree was pinned to `origin/main` `ce52ba2c5261ebced8f5dae9ca1e21f25db8f460`, whose view-provenance optimization computes same-name declaration counts once rather than walking the tree per query. Its compatibility-edited source fingerprint was `2a069ae9c7eaf694f838e74d5c8351ab2910a12d4f7b850c4a63c56f32e169e0`. Stage1 product `801546aedcd84ffb9759e9d5dbecd893210d6c74ea0364effc6f5ecdfa0ca66c` passed freshness, but the build-only LSP probe declined 1,905 backend operations before object emission; no parity or performance result exists. The compiler upgrade harness was updated to isolate frontend snapshots, mark skipped tests/benchmarks incomplete, extract p95 values, and fail closed on missing scenarios.

- **Previous stage0 release with negotiated completion metadata and definition links (2026-10-01 04:35 UTC; superseded below):** The supported Darwin/arm64 `-O2 -fno-builtin -Wl,-v` artifact used compiler `origin/main` HEAD `ce52ba2c5261ebced8f5dae9ca1e21f25db8f460`, compiler-source fingerprint `2a069ae9c7eaf694f838e74d5c8351ab2910a12d4f7b850c4a63c56f32e169e0`, and Go stage0 source revision `0b21b7b2c2936312381a1ec1625ed5b6e66b8016` (binary SHA-256 `2fc31c130863b41ac07d250c4bfa25ee5c73f45f8faefb8e696b5bbf7176c408`). Its LSP input was `9b256c3ba06524587e7fd2659bffb5ca36b72e2aead4226461d4e3ee327be0dc`, include-closure hash `10c15bd9221787094f7fc0278de0a6842db4d7efc5bc4d53e5492763e2133411`, object `12da02b5e150df2a3a7b5928c2d70778aed4fe604ef6ac23edeecc0ad1e4c0b7`, and executable `58f3148eeccc8144e3ae3e5df146e10bac32fdb26d51e19539044404fa1f2738`. That exact input passed strict freshness, the 19 compiler-rejected probes, and `81/81` tests. It covered negotiated completion edits/snippets/labels and definition `LocationLink`s, with `targetRange` conservatively equal to the exact target token range. Its no-optimizer-speedup statement applies only to that source/build's diagnostic output.

- **Full latest-main disposable compiler gate (2026-10-01):** `bench/compiler-upgrade-latest-main-ce52-stage1-2026-10-01.json` records a completed gate (`qualification_complete=true`, `gate_passed=false`). Its stage0 baseline is the exact latest-source input/compiler tuple above: LSP input `c75965f91af833327dd9de263387932463fac082af15e53f50cf6a07d1c60009`, compiler source `2a069ae9c7eaf694f838e74d5c8351ab2910a12d4f7b850c4a63c56f32e169e0`, backend SHA-256 `ad85e4ac14bff8d2c579f55c297f474fb35929d744a5d911e03bced853c1fe91`; fresh build took 83.927 s, the canonical suite passed `81/81` in 575.705 s, and the server artifact is SHA-256 `032c065bbe485b52954b63653d26a16dfbb5ae152e8a1de8d483f646581261c2` (object `ac57b137b1c3fd667d8e9f9126b866eac1c35c4d80633db2f5c83afed7152d01`). Three-sample baseline p95 latency observations are recorded in the report's raw benchmark for 100 functions / 5,680 bytes and 1,000 functions / 58,780 bytes; at 1,000 functions startup is 4.596 ms, clean open 4,227.537 ms, edit 3,756.602 ms, cached tokens 1,505.924 ms, and hover 2,295.964 ms. The three-sample p95 is the maximum sample and remains host-sensitive baseline evidence. The candidate used fresh stage1 SHA-256 `801546aedcd84ffb9759e9d5dbecd893210d6c74ea0364effc6f5ecdfa0ca66c`, but its backend declined 1,905 operations and wrote no object; candidate tests and performance are therefore unavailable. The report preserves raw samples; its original normalized p95 map is empty due to an extractor bug, now fixed and regression-tested. The gate also now fails closed when baseline/candidate p95 maps are empty or their scenario keys differ. No optimizer speedup or parity claim is made.

- **Current local-compiler stage0 build and completion resolve (2026-10-01 05:10 UTC):** `build/manifest.json` pins compiler HEAD `d8b5d305ec99a9d2238e035b871d9fd4e9835603`, three commits ahead of checked `origin/main` `ce52ba2c5261ebced8f5dae9ca1e21f25db8f460`, with local source edits and full source fingerprint `56868fba124d5f56905635d2529b3e70acbd22033a0a3ce5ff7225330cbb5393`. `build.sh` copied that exact local compiler source into its immutable snapshot and used the supported Darwin/arm64 Go stage0 backend at SHA-256 `2fc31c130863b41ac07d250c4bfa25ee5c73f45f8faefb8e696b5bbf7176c408`, with `-O2 -fno-builtin -Wl,-v`. The release artifact built at `2026-10-01T05:10:33Z`: LSP input `08a27651337b4651e242825b98416b96b63ca5c1086752a0529da17b5b60f672`, 581-file include closure `ac94cdd4193f883cdab83b0975df9583885aff81c9229ae6126b90c42459063f`, object `d040c8ffea7f56c234be0e53b04b34e078f650966d04dd93819d234b41b8d26e`, executable `ea6ea965c14abde8daf9342edfb0debe54f634efafc5a98d8fcfa8baa65fa850`. Strict build freshness passes. The unsupported-language inventory was rerun on this compiler/backend tuple and passed all 19 probes; the diagnostic-span inventory was regenerated from the manifest-pinned compiler snapshot. This input adds bounded `completionItem/resolve`: only a unique cached same-file function signature is resolved, and only while canonical URI, version, and open-document generation all match the current ready snapshot; stale or malformed resolve data leaves the item unchanged, and arbitrary client-owned fields round-trip. Resolve data is omitted for non-functions, absent signature metadata, and URIs longer than 2,048 bytes. It does not resolve docs, types, or return types. `test/completion_test.sh` covers matching resolution, custom-field preservation, stale versions, reopen generations, and malformed items. The full canonical suite is being rerun for this new input. The latest local stage1 SHA-256 `c9120725bde202e70ea9ff94c9b87ab2026770eb5b29e95bfc1bc285f76eb9cf` passes its freshness check, but a disposable build-only probe declines 1,918 backend operations before object emission; tests and benchmarks were skipped, so the candidate remains unqualified and there is no stage1 parity or performance result. The recorded report is `bench/compiler-upgrade-local-d8b5-stage1-2026-10-01-build-only.json`. Compiler optimization diagnostics from this build are not latency evidence.

- **Historical toolchain and optimizer-candidate audit (2026-09-15; superseded by the 2026-09-28 entries below):** The latest supported Elisa-LSP backend found at that time was the clean Go stage0 at revision `601f7bcd3de62877723ab7f5c5f9a502fb6ef9ae`, built with Go 1.27.1 for darwin/arm64; its executable SHA-256 is `51f5f5f1f33c65f71bb6a17acae8fcc45c74009ff27f6209a93a06ecd3d39b62`. The adjacent frontend/include checkout remains revision `8d7db0561d0f72c1f548fa6a73d071c86b2fe57f`, with latest observed dirty source fingerprint `429c49c0960305dd9e559437c64d331548a83b7d0e4f082f73307954a936c52b`. The newer optimizer snapshot at `05289f0430b359b4a28b761590a6a623f8497aec` and other local branches provide stage1 artifacts only. The known full-source `-O2` object-only probe for `05289f04` failed with an `Abort` effect-target error and region-lifetime escape diagnostics and emitted no object; the checked-in release build must therefore keep the supported stage0 until a candidate passes parity. The later 2026-09-28 API migration restores the current frontend/stage0 build, documented below. Builds with stage0 emit useful reserve-bound, fused-fill, and struct-padding diagnostics; the Q04 checklist now tracks triage separately for LSP code and included compiler code. The source checkout is based on Go `origin/main` `5284109ca5805560a488c3b0a5d8cd4a1a45e317`; that remote revision is not a compatible replacement because its libc `memset`/`memcmp` C-ABI lowering fails the focused probes. The earlier `TestAnalyzeRejectsDotModulePathInTypePosition` mismatch is fixed in the dirty Go checkout and covered by focused regressions; the pinned stage0 binary's remaining runtime trap is recorded in the compiler follow-up below.
- **Superseded artifact checkpoint (2026-09-15):** An earlier release artifact was rebuilt at `2026-09-15T03:36:07Z` with `-O2 -fno-builtin -Wl,-v` for Darwin/arm64. Its manifest recorded LSP input hash `12fbffded5e8b3cacbff4b8318ff3490a83fb86dbc112810956b26a39b590c49`, compiler-source hash `8e114cd067fd7da42b51b279a0d8ac09bba4c5b1b81cce1e5b66ec64b51ce9ba`, supported stage0 SHA-256 `51f5f5f1f33c65f71bb6a17acae8fcc45c74009ff27f6209a93a06ecd3d39b62`, object SHA-256 `51c88a86b462776fe673c01c8bc107d701ae44de05edf803d7b8b7487dc6fa69`, artifact SHA-256 `0a687751032626ba8c818b86377bdde59a1588614fabf7b3265e755213851d33`, and build-pipeline hash `de2963fff075ec4c4bbb62df1bf581027cb3eeba65f09c683040167b455605f4`. The manifest also recorded the compiler-emitted 543-file include closure with SHA-256 `822ba4160f22109cc5839df66f13403d5af51fd9fb8815740cdf5f152819fa7e`. It used clean stage0 revision `601f7bcd3de62877723ab7f5c5f9a502fb6ef9ae` (Go 1.27.1, darwin/arm64) with the dirty but content-addressed latest frontend revision `8d7db0561d0f72c1f548fa6a73d071c86b2fe57f`. This checkpoint is retained for audit history; the `2026-09-15` artifact immediately below is also historical, and the current authoritative artifact hashes are recorded in the `2026-09-28` verification entry later in this section. The artifact was intentionally attributed to stage0: newer stage1 optimizer candidates remain unsupported until they pass the full LSP compile, protocol/feature parity corpus, and calibrated benchmarks. Linux and hands-on editor-host workflows remain open.
- **Historical latest-toolchain headless verification (2026-09-15):** The historical release artifact was rebuilt at `2026-09-15T05:35:07Z` with the supported stage0 and release flags, after the indexed enum lookup was corrected to preserve bounded type-alias traversal. Its manifest records LSP input hash `e537bb1cd86f25eb18ec89417951e2aabb563ef7cca014af43d2c3241a1f5be4`, compiler-source hash `429c49c0960305dd9e559437c64d331548a83b7d0e4f082f73307954a936c52b`, object SHA-256 `46f3899cf171f2cdc4b60abfdf4b755683fcf6d41ed1f1ec09de3d3296045d33`, artifact SHA-256 `3b21df091a4141519cebdc2cc9e8db7d27b0ee37231d7b5abfa107fb2ad3087f`, and compiler include-closure SHA-256 `c2bc7a838b8b440b8afa68092675366e18d1039c9718d49a05851ef1513868f9`. `scripts/check_build_freshness.py` passed for that dated artifact and the complete canonical suite then reported `75/75`; all focused semantic-token, interpolation, precedence, combined-lexer, frontend-contract, cache, native worker, identity, and provider gates pass. The semantic-token regression covers direct enum owners, aliased enum owners, shadowed receivers, hash collisions, and fallback behavior. The direct lexer regression compares token kind, position, byte span, suffix metadata, and comment spans against both legacy streams and statically rejects a legacy comment-only call in the LSP. The sibling extension's `npm run test:headless` passes all `148/148` tests, TypeScript checking, and the VSIX content audit. Both gates spawn only subprocesses or test fixtures; the extension gate explicitly asserts that VS Code, Electron, and the Extension Development Host are not launched. Those results do not validate the current 2026-09-28 source/compiler tuple.
- **Latest Elisa compiler and optimizer audit (2026-09-28):** The adjacent compiler checkout is on `main` at `98261837ddc8ba0596c3bf9b0c5906475bf289b7` (`Reject local borrows escaping through containers and stored aggregates`, 2026-09-28 19:27:36 +02:00). At the original audit point the tracked sources were clean, with an untracked `elisa-compiler-worktrees/` directory present; compatibility work documented below now modifies tracked compiler sources. The original stage1 product hash `bcb0dab36d1944ca8d8dfcfae2c8aed276e6745d97591cfd7495b9ecb0bcf8a2` was rebuilt from the updated source and superseded by the fresh product recorded below. The frozen stage0 executable used for the current release build and full test run is Go 1.27.1/darwin/arm64, source revision `e42bbdfe8a1b8123c3c4bfd096d64eb4c97c8b11`, SHA-256 `850a8979e17bd28f1cb91e3c88665f6707b71d83e263f280dbd152458184ea6e`. The compiler documents conservative default optimizations for local `darray[i64]` buffers (repeated scalar-helper scratch reuse, counted-fill capacity inference, and bounded nonescaping stack placement); `-fnoalias` enables a separately gated safe scalar/darray subset. These are present in the latest compiler source, but their workload and type scope must be established for the LSP instead of assuming that they speed its predominantly byte/string and record-oriented data paths.
- **Initial compiler compatibility probe before API migration (2026-09-28):** `scripts/compiler_upgrade_gate.py` was run on disposable copies of the current LSP against the current stage0 and the current stage1 product, both with the adjacent `98261837` frontend and release `-O2`; tests and benchmarks were deliberately skipped because neither candidate completed compilation. Both candidates failed before object emission at that pre-migration source snapshot. The latest frontend rejects retained `document` views after `store_document_text` or a `darray.push` mutates their backing storage, and reports adapter conversions where `sview`/`Bytes.push_str` now receive `u8&` instead of `cstr`/`cstr?`. Stage1 also reports the newer storage-dependency invalidation diagnostics at the mutation sites. That probe did not produce a latest-tuple artifact; the subsequent compatibility repair and current stage0 verification below supersede its source-compatibility conclusion.
- **Compatibility repair (initial stage1 follow-up, 2026-09-28):** This records the intermediate source/API migration state before the exact-occurrence follow-up. The LSP now checks bounds before making source views, reacquires document records after mutation/compaction, uses the latest declaration-ID and diagnostic-enum APIs, and copies worker-owned arrays into caller-owned buffers where the current stage1 region analysis requires it. The first stage1 compile cleared LSP-owned view, byte-conversion, and auto-region escape errors but exposed indexed-view inference and a false `Abort.Panic` target diagnostic in compiler sources. Those specific issues were addressed in the adjacent compiler working tree; the later candidate qualification attempt and its remaining backend limitation are recorded below.
- **Earlier stage0 verification (2026-09-28 20:00Z, before exact-occurrence follow-up):** A Darwin/arm64 release artifact was built with `-O2 -fno-builtin -Wl,-v`, stage0 SHA-256 `850a8979e17bd28f1cb91e3c88665f6707b71d83e263f280dbd152458184ea6e`, compiler/frontend revision `98261837ddc8ba0596c3bf9b0c5906475bf289b7`, compiler-source SHA-256 `d10ccb1586417562841a72ff5c2a6efb2aecdd649decd8db5cb4d614d798bc26`, LSP-input SHA-256 `5da392bf9eddb5a3989f49adcb3042661664def553d3552bdd6fe6c91fccde50`, object SHA-256 `b2a2e7495813126e64755dfc90db65a08b2e3320f4f179e54c61a1144229895b`, and executable SHA-256 `794a2d3d3ed09ab62e73761fcae304e174c859d4bb8e5e9b3991a143205f3e62`. This checkpoint is superseded for current-source status by the verification immediately below.
- **Superseded stage0 verification (2026-09-28 22:54Z build; revalidated 2026-09-29):** The prior artifact used `-O2 -fno-builtin -Wl,-v`, compiler source fingerprint `c0090f6cb382a0f28d16c5f7c1d40aa0d3e227d16741de6cf13c0f646db3dd13`, LSP-input fingerprint `e00df3a039acd98223065c0843360a6915238a25a79e8e86e6c412cd76d12308`, 577-file include-closure hash `cc600bdff0def345eef7daca95d6117d6defb87f1b433cd2da81beba4b7291aa`, object SHA-256 `2315b3d082d644153bc82c106c0aa4cb569c00f512549e796c9285462c2085af`, and executable SHA-256 `dec45fafa3e3c8425a8c1bf36522fee0054e6723358c9e05a7b90fee69639786`. That tuple passed freshness and `75/75`; its compiler-source identity is historical because the local compiler advanced.
- **Prior stage1 optimizer qualification attempt (2026-09-29; superseded by the latest-source gate below):** The then-fresh stage1 product hash was `a10dafac0a9db4d751720ae2038718aacc39325d226aaca2125316f1405c7914`; its isolated build failed at both release `-O2` and debug `-O0` with `backend could not produce a linkable unit; declined 1875`, naming included frontend functions beginning with `parse`, `expr_pos`, and `Parser`. Since the failure reproduced without optimizations, it was a stage1 backend completeness blocker rather than evidence about optimizer performance. The gate’s disposable stage0 baseline reported `73/75`, while the direct canonical run reports `75/75`; the baseline discrepancy remains a gate defect to diagnose.
- **Latest-source compiler and stage1 optimizer recheck (2026-09-29):** The adjacent `main` checkout is at local HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2`, four commits ahead of the read-only checked `origin/main` ref `98261837ddc8ba0596c3bf9b0c5906475bf289b7`, with uncommitted compiler edits. Current source fingerprint is `ecd23c2e0a2f0ce74760bbf0e4200f06fa3405c5af9383ab70b8d13e2e4b4eb3`. A fresh guarded seed produced stage1 binary SHA-256 `109866537fb2889075edf485d829333d795b6468bcafa529343d0f9a1fb1c5cc`; `scripts/assert_stage1_fresh.sh` passes. Direct LSP object probes at `-O2`, `-O1`, and `-O0` each failed with 1,887 backend declines and wrote no object. This is a backend-emission blocker, not an optimizer comparison: the candidate never reached protocol tests, parity, or benchmarks, so its default memory optimizations and opt-in `-fnoalias` remain unqualified on LSP workloads. The older complete disposable gate at `bench/compiler-upgrade-stage1-2026-09-29.json` used source fingerprint `c009…` and its old 73/75 baseline result does not describe this tuple.
- **Superseded stage0 verification (2026-09-29 00:40Z build):** The intermediate artifact used compiler revision `30dcf6fae3d9266181aec86fb919c1fd436c9866`, source fingerprint `0b4d4a1fc9144ea77f7781cc6c0c54463866dfbc09ba8a0c00138f5c3d2a7208`, include-closure hash `6e61079dc35fb6fb7a96dd638a8614180daa661e32e5998d8766991520ff568c`, object SHA-256 `46e4300df62a8026ee5f8fbb4b1a203677e24287ac7ae6fa77552452d101999b`, and artifact SHA-256 `142871fb0208b8dfa67cf7e85a98e18f9415fe98d8fb3357f34d0a61151cbd80`. It passed freshness at build time; its first 76-test run was 75/76 because the construct inventory still named `c009…`. The compiler then advanced, which made that artifact stale and required a rebuild.
- **Previously fully verified stage0 artifact (2026-09-29 01:46Z build):** A Darwin/arm64 release artifact using `-O2 -fno-builtin -Wl,-v` was built with compiler revision `54360bf68398b4da8d63b82a3ad2979667798aa2`, source fingerprint `ecd23c2e0a2f0ce74760bbf0e4200f06fa3405c5af9383ab70b8d13e2e4b4eb3`, and supported stage0 SHA-256 `850a8979e17bd28f1cb91e3c88665f6707b71d83e263f280dbd152458184ea6e`. Manifest values: LSP-input hash `8bfc1e7b361e1ea2cf43dbedadd199d73199ad232fc55d4430766a226d8609fc`, 577-file include-closure hash `5a04387c3f3714e6d1b5d8f686b83941f8e0874f8cacb7440e0f4c45e3b25a27`, object SHA-256 `fdb478a3f4efc7c991b528e4afa83065429df8136e87843d7fef5c7b40bf390e`, and executable SHA-256 `a8bf51ecb72fc2d518f651720bdc80ca10d47e37a1587f8c27f2047f0115cba6`. This exact tuple passed freshness and the then-76-test canonical suite (`76/76`); the expanded storage-reclamation test also passed independently on release and debug builds. This is the last complete canonical result before the semantic-token fix and 48-category fixture below. It validates the latest local frontend through the supported stage0 backend on Darwin/arm64, not stage1 optimizations, `-fnoalias`, other platforms, or a real editor host.
- **Historical stage0 artifact (2026-09-29 03:05Z build):** The Darwin/arm64 release used the compiler source revision/fingerprint and supported stage0 executable noted at that earlier checkpoint, with `-O2 -fno-builtin -Wl,-v`. Manifest values: LSP-input hash `90070ea21f6f12dd4c195439eee55c4c25cdb0c1ed50e4bdab3462fd84c84df4`, 577-file include-closure hash `93f7a7b1cbfef1eb8db8c6c73928d53703608906c7d15ec030d089e3cfd29d86`, object SHA-256 `61e5578b8a90eca1e39709c2950aa50768fe28b8d95de2a073c73029a2e5b887`, and executable SHA-256 `a46cecb9ce36a38dcbaca0f7116416cc61ee966ada03bbcdc3c475969d7c9ad2`. Freshness passed then. The exact-span fixture passed 314 assertions and explicitly checked every one of the 48 legend categories; core, contextual, f-string, and manifest token gates passed as well. The full canonical suite was not run on this historical artifact; later exact-source `78/78` evidence belongs to the current v11 tuple recorded below.
- **Full-suite stability recheck (2026-09-29):** A later `bash test/run_all.sh` against the 01:46 fully verified artifact and then-current test list ended `pass=73 fail=3`: `test/lsp_client_selftest.py` timed out in its subprocess fragmentation/pipelining case, `test/output_stall_server_test.py` exceeded its subprocess deadline, and the expanded `test/storage_reclaim_test.sh` timed out waiting for a response during its final churn phase. The first two gates passed immediately when rerun alone; storage reclamation then passed alone in both release and debug builds, including alternating 104,417-byte/30-byte revisions and its close/churn/compaction cases. Unrelated compiler builds were consuming CPU during the full run, so load is a plausible explanation but not proven; the failures were timeout-only and none reproduced in isolation. The earlier `76/76` result remains valid for its exact artifact. Repeat the canonical suite on an otherwise idle host before treating the recheck as a stable all-green result.
- **Compiler namespace-path follow-up (2026-09-15):** The compiler source now preserves once-only dotted-module diagnostics across speculative semantic passes and adds `src/main_invalid_namespace_path_test.go`; focused Go tests pass for both the CLI object-emission boundary and semantic rejection. The supported pinned stage0 binary was not replaced: it still accepts an invalid `Module.Name` type path and later traps in object emission (`SIGTRAP`/LLVM ABI-size path). This remains a real compiler bug in the pinned binary and is a release blocker for adopting that compiler candidate, even though the source-level fix is present in the dirty Go checkout. A fresh Go-built candidate rejected the bad path in one direct probe but was not release-qualified because its LSP integration observability/handshake probes were incomplete.
- **Historical upstream-main compiler check (2026-09-14):** Go compiler `origin/main` at `5284109ca5805560a488c3b0a5d8cd4a1a45e317` passed its qualified-type check, fast `make test`, and sequential `make test-full`; the native-runtime package took 478.293 seconds. Those broad gates did not catch the libc C-ABI regression described next, because the current revision had deleted the focused backend regressions.
- **Historical stage0 C-ABI diagnosis (2026-09-14):** Go `origin/main` `5284109` lowered libc `memset`'s fill argument and `memcmp`'s result as platform Elisa `int` (`i64` on Darwin/arm64) instead of C `i32`, and had removed the focused regressions. Reconstructed zeroed-aggregate, darray-resize, and string-comparison probes failed with the `5284` binary (`d97d0d3…`). The fixed local `601f` branch retains the `i32` declarations/tests and passes the direct probes; it is the stage0 used by the current artifact above. An earlier compatible branch/binary `1d1ddf1` (`532285b…`) is superseded and is no longer the current build input.
- **Historical LSP flake investigation (2026-09-14):** Earlier runs under concurrent simulator/compiler load intermittently timed out in URI-collision or frontend-contract startup, and one relative compiler-root run resolved includes from `/tmp`. The test harness now canonicalizes a usable compiler root through `scripts/compiler_root_env.sh`; `bash test/compiler_root_env_test.sh` covers default, relative, and missing-root cases. The latest exact-source canonical result is recorded in the current artifact gate above.
- Historical verification at 06:40 UTC used Elisa-compiler revision `9791a8e1cd924bb03e43cb46da2d3530b4c9fbb0`, stage0, and release `-O2`; its manifest recorded compiler source SHA-256 `9177f9916409f210a619ad31e892ab3f21f7bacd78e2b9e6dc00745ee2a7c3d2`, LSP input SHA-256 `af48fb0c2696889f6304dbe97f298068ccac11eb966e0f8bdbbd92c83ace9041`, and artifact SHA-256 `20b2ae3066952dc9ea7fdafff325d132fe8292445ee6ec1aa912fb207a1905bf`. The compiler was clean and no compiler files were rewritten. At that historical snapshot, the canonical suite reported `pass=54 fail=0`; the 2,000-URI soak returned logical live storage to 0 bytes with 558,912 bytes of backing byte-store capacity. That result does not validate later source changes or the latest compiler revision.
- Historical checks on that same 06:40 snapshot reported `npm test` at 88 passed, `npm run check`, `bash test/signature_help_test.sh`, and `git diff --check` passing. Its observational VS Code performance capture measured warm semantic-token p50 0.238 ms and hover p50 0.111 ms; those single-machine timings are not regression gates. Cross-platform, real extension-host/theme, scheduler/cancellation-during-analysis, and broad project-workspace gates remain open.
- Follow-up B03/U01 checks: `bash test/run_all.sh` passed `54/54` after the per-occurrence semantic-token rewrite. The expanded token fixture and hover-position boundary matrix added afterward pass `semtokens_test.sh`, `contextual_tokens_test.sh`, `fstring_semtokens_test.sh`, and `general_hover_test.sh`; those focused reruns include exact ranges for additional token classes and InvalidParams behavior for malformed, negative, fractional, and duplicate hover positions.

**Fresh stage1 compiler qualification attempt (2026-09-29):** The Elisa compiler checkout is still at upstream `main` revision `98261837ddc8ba0596c3bf9b0c5906475bf289b7`; its current source fingerprint, including local tooling/API changes, is `c0090f6cb382a0f28d16c5f7c1d40aa0d3e227d16741de6cf13c0f646db3dd13`. `scripts/assert_stage1_fresh.sh` passes for the candidate product `bin/elisac-stage1` SHA-256 `792e163e372ca659a9fcea5a0eb63a7e96dc59e013316eca02936ea7a8eba7b2`. The disposable upgrade report is `bench/compiler-upgrade-stage1-2026-09-29.json`. The baseline stage0 build succeeded but its rerun of the suite reported 73/75; the exact current working-checkout artifact separately passes 75/75. The old gate report retained only the last 4,000 output characters and the temporary logs were removed, so the two failing test names cannot be recovered. The candidate stage1 build failed in 35.997 seconds: the backend declined 1,875 functions and refused to emit an object. Isolated stage1 builds at `-O1` and `-O0` produced the same decline count; neither a stage1 artifact, parity result, nor benchmark was produced. This supersedes the earlier specific indexed-view/effect-target blocker diagnosis. The upgrade-gate runner now retains `FAILED: test/...` names in its report for future runs; `test/compiler_upgrade_gate_test.py` covers extraction. Do not use this result to qualify or adopt stage1 optimizations. Re-run after the compiler backend can emit the LSP object, with failure names visible and the full suite green before measuring p95.

**Latest-source refresh and test evidence (2026-09-29):** The release was rebuilt from immutable compiler snapshot HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2` plus six local backend/test source files copied from the user's latest compiler checkout. The snapshot's complete frontend/compiler source fingerprint is `bff44114afd303d52c519a0bd77a470f028d91513476b110a3bf1884c6635b90`; the LSP input fingerprint is `6f2ff84e33a3b3a7de2b70c4de09a7cd17f358ad4f26f019a288d080c7a7f9ac`; and the compiler-emitted include closure contains 577 files with closure hash `22d546b767610fba589bf0c27e98a2e5d9467577b245bdd9094d30a09dc73152`. The release artifact was built at `2026-09-29T20:26:23Z` for Darwin/arm64 with `-O2 -fno-builtin -Wl,-v`, using Go stage0 SHA-256 `8982ace0e827d99ab1ac5539a3bce2a7896d1950fed8ef72d2d2bab6eeebbfd8`; its object SHA-256 is `660e522b4d4e6971fb6e6664962ebf4dbc45b9133e42435e9b185fe58ac58515`, executable SHA-256 is `850fa61378de3b99260dc978a2efcfc60ffef63ae47336aa7e2606e75f56dc42`, and build-pipeline hash is `76efdc915662d309add93afe5a9070bd121a1eba30e06c2c40ddd51df1f7246d`. `scripts/check_build_freshness.py` passes against that manifest, and the canonical suite passes `78/78` on the exact frozen tuple. The final fixes cover contextual-keyword/compact-reference disambiguation and alias declaration selection when the current compiler omits an alias `name_pos`; the v7 frontend contract, all 48 semantic-token categories, provider ranges, document symbols, analysis-worker recovery, bounded storage, and unsupported-construct probes pass in that suite. A stage1 seed was attempted only after an observed lock-free interval, but another compiler task acquired the machine-wide seed lock (PID 72005) before it could start; the script refused a concurrent high-memory seed and no stage1 candidate was built or measured in this attempt. The new 78/78 result supersedes earlier suite counts only for this exact source/artifact tuple. Stage1 optimizer qualification remains open: once the shared seed completes, re-identify its exact source fingerprint, prove product freshness, test LSP object emission, and run parity plus latency/RSS measurements only if object emission succeeds.

**Refreshed against the live latest compiler sources (2026-09-29):** The prior `bff44114…` snapshot was superseded by compiler source fingerprint `269b3924da9129d2565596b91ccabd33672e71f118ce013915c7e6cefbd29f02` at the same source revision `54360bf68398b4da8d63b82a3ad2979667798aa2`, including ten current dirty paths in the compiler checkout. The first live-checkout build correctly refused publication when source files changed during compilation; a source-stable copy was then captured, hash-checked before/after copying, and used for the release build. The resulting immutable manifest records LSP input hash `6f2ff84e33a3b3a7de2b70c4de09a7cd17f358ad4f26f019a288d080c7a7f9ac`, the 577-file compiler-emitted closure hash `ced36f0a7376593a9e94effa05a7c99f2db176dc1fbf65a5d0b7bc7ff0724af3`, Go stage0 SHA-256 `8982ace0e827d99ab1ac5539a3bce2a7896d1950fed8ef72d2d2bab6eeebbfd8`, `-O2 -fno-builtin -Wl,-v`, object SHA-256 `cdf857062d39f73418bb845cfab26c27e1b60d3a44871073b1888769290ae55e`, artifact SHA-256 `2b41c10eff333747f7d45fb10f37053df00a1300badd1e6fcf37001b0d55f84b`, and build-pipeline hash `76efdc915662d309add93afe5a9070bd121a1eba30e06c2c40ddd51df1f7246d`; the artifact build time is `2026-09-29T21:12:22Z`. Freshness passes. The refreshed compiler audit passes all 19 probes, and `test/run_all.sh` passes `78/78`, including the isolated compiler builds, 9,596-case position corpus, worker containment/recovery, and v7 frontend contract. The inventory provenance now names this source fingerprint; its support classifications did not change. The build emitted 381 non-fatal compiler warning diagnostics (predominantly effect-grant warnings in included and LSP source); the object and release executable were produced successfully. A fresh `-O3` stage1 product for this same compiler source fingerprint is present at SHA-256 `ca5d65c417d6f2f0a125ef6e286cd700bbea784c5aba18d04dd4acc2c7f58f4f`, and `scripts/assert_stage1_fresh.sh` passes. The direct LSP object probes using this product failed identically at `-O2`, `-O1`, and `-O0`, producing no object; each reported two argument-type errors in `parser_machine_laws.elisa:62`, one type error in `check_call_argument_exclusivity.elisa:397`, a non-null-reference zeroing error in `src/frontend_adapter.elisa:304`, and the `Abort` effect-target error in `src/main.elisa:1380`. The product is therefore fresh but not compatible with this complete LSP source unit. The upgrade gate's parity and benchmark phases did not run; keep the tested stage0 artifact as the release backend until a later stage1 passes object emission, the complete suite, and latency/RSS comparisons.

**Earlier latest-source stage0 checkpoint (2026-09-30; superseded by v11 below):** The prior Darwin/arm64 release used compiler HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2`, source fingerprint `4c48ea7e85d65af62bdfc83f3e351151f1f354d4ef9e735d9ea755751b8fdb98`, Go stage0 SHA-256 `8982ace0e827d99ab1ac5539a3bce2a7896d1950fed8ef72d2d2bab6eeebbfd8`, and `-O2 -fno-builtin -Wl,-v`. Its manifest recorded LSP input hash `6f2ff84e33a3b3a7de2b70c4de09a7cd17f358ad4f26f019a288d080c7a7f9ac`, 577-file include closure hash `13baf101c64fd6cc23586554c3a65cfd446d58a2faf1a49ea61dc8b1cfafc7c7`, object SHA-256 `5b390c506bad330416d8369b24e7cc9e8de980179370501fc90d0bf4743372a1`, and executable SHA-256 `d363102b69c5eb8bd0f52708ace99d7a87f916317f56798fc44a84c0288ff10c`. It passed strict freshness and `78/78`; its results remain valid for that exact tuple. The current v11 artifact and its `78/78` result are recorded below and supersede it for current-source status.

**Previous stage1 seed probe (2026-09-30; superseded below):** A guarded `-O3` stage1 product for compiler source fingerprint `4c48ea7e85d65af62bdfc83f3e351151f1f354d4ef9e735d9ea755751b8fdb98`, binary SHA-256 `017f7ccac250c6780c7cbd6ada877be81d899b163a37bc7217b1d5ec1240b6b4`, passed its freshness check. That probe reported two `u8`/`sview` argument errors in `parser_machine_laws.elisa:62`, a `sview` field initialized from an integer in `check_call_argument_exclusivity.elisa:397`, a non-null-reference zero-initialization error at `src/frontend_adapter.elisa:304`, and an `Abort` effect-target error at `src/main.elisa:1380`. It emitted no LSP object, so protocol parity and performance checks did not run. The later v11 stage1 attempt below uses the refreshed compiler source and current diagnostics.

**Previous latest frontend / release tuple before the completion refresh (2026-09-30; superseded by v12 below):** The compiler checkout at `../Elisa-compiler-latest` is HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2`, source fingerprint `766f5eadb9518b1c97282e3532e0f300a272e3f61d19356a34ed89e9a1946a5b`. The v11 Darwin/arm64 optimized release was built at `2026-09-30T19:58:21Z` using supported stage0 SHA-256 `ad85e4ac14bff8d2c579f55c297f474fb35929d744a5d911e03bced853c1fe91` and `-O2 -fno-builtin -Wl,-v`. Manifest fingerprints: LSP inputs `1f2743e9eb162bbf4bcba9b29a9dd2ebb600bf26de7f1c1754852f77258be674`, compiler include closure (577 files) `ec1fa1e1210a1c012b2c596e878745acbc60c38c8f85832e6d575386fca82346`; object SHA-256 `15718366699d0442e427f9476094f54d182d37010e8d8171e63fd038c80f3d4a`, executable SHA-256 `4e106871edc3000ee2852e1af46fd5230008cc53ba4aefa2272415f443803712`. The current artifact passes strict freshness and the canonical suite passes `79/79`; manifest-pinned stage0 and frontend snapshot paths are used for isolated builds. The unsupported-construct inventory, v11 exact-occurrence contract, and diagnostic-span constructor inventory all match compiler fingerprint `766f5ead…`. This was the supported release tuple before the completion-provider source change. It incorporates the latest frontend API and the compiler-recommended LSP fused-fill rewrites; it does not yet use a stage1-built LSP executable.

**Previous latest-compiler completion refresh (2026-09-30; superseded by the v12 artifact below):** The Darwin/arm64 `-O2 -fno-builtin -Wl,-v` release was rebuilt at `2026-09-30T21:37:03Z` from compiler HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2`, exact compiler source fingerprint `766f5eadb9518b1c97282e3532e0f300a272e3f61d19356a34ed89e9a1946a5b`, and supported stage0 SHA-256 `ad85e4ac14bff8d2c579f55c297f474fb35929d744a5d911e03bced853c1fe91`. The manifest records LSP-input hash `ea501370e3882085cb7cd57a2a88295223fa1344ebc3957579ec40d12a1c4f16`, a 578-file emitted include closure with SHA-256 `f8b3c51d65ee0d8619b0bd66d023ed0cde976f5bd3e20619c1e44f46034c60cf`, object SHA-256 `0edd872d02e83762971d849b97b93f1063174cf51ca1fdf41c46356c30516be7`, release artifact SHA-256 `111096f74e944804f3e3e4f7a7a6ffe5e68603645d7b3a2a56c9c877841823ac`, and the existing build-pipeline hash `76efdc915662d309add93afe5a9070bd121a1eba30e06c2c40ddd51df1f7246d`. Freshness passes. Completion now includes only exact-owner parameters from the retained analysis summary when a complete function header and body indentation identify the current function; type contexts, incomplete signatures, and potentially shadowed parameters remain excluded. Its focused regression passes for declaration candidates, parameter visibility, global/parameter shadowing, local/parameter shadow suppression, UTF-8/UTF-16 edits, and rejected contexts. The canonical suite log ends `pass=80 fail=0`, including worker packet validation for the extended retained symbol record and the storage/URI churn tests. The latest compiler emits no fused-fill, reserve-bound, or layout optimization advisory for `completion.elisa`; observed completion diagnostics are effect-grant/pointer-cast warnings, not optimizer recommendations. This v11 tuple passed freshness and 80/80 tests for its exact source state; the v12 rename artifact below supersedes it. Stage1 still did not emit the whole LSP object at the latest-source gate, so this release uses the supported stage0 backend; do not attribute unmeasured performance gains to newer stage1 optimizations.

**Previous latest-compiler parameter/local rename refresh (v12; superseded by v13 below):** The Darwin/arm64 release was built at `2026-09-30T22:14:49Z` with `-O2 -fno-builtin -Wl,-v` from compiler HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2` and exact source fingerprint `766f5eadb9518b1c97282e3532e0f300a272e3f61d19356a34ed89e9a1946a5b`. It uses supported Go stage0 SHA-256 `ad85e4ac14bff8d2c579f55c297f474fb35929d744a5d911e03bced853c1fe91`; the latest fresh stage1 candidate is still unqualified because it cannot emit the complete LSP object (probe below), so no stage1 optimizer or performance claim is made. Manifest: LSP inputs `6237629b7f4b41f986a9092f6ebc9f5995be55a103e2bc2bce3567e459c5ce6c`, compiler-emitted closure of 579 files with hash `066ce2c07a931e94129994f5b8f99740237b339fc5bee2f70d68d0cdcaaf9342`, object SHA-256 `5f9f6e87a2be32d96aace0f5f8cfb6246bb165f1f0b12f8edee304e1bc4d0024`, artifact SHA-256 `0d4f7dc50fce4d243bdf506d6f26b5da53aac8255c9500f9f1f942ee0379a475`, and build-pipeline hash `76efdc915662d309add93afe5a9070bd121a1eba30e06c2c40ddd51df1f7246d`. Strict freshness passed and the exact artifact passed the canonical suite `81/81`. The source-wide absent-name guard intentionally rejected new spellings found even in comments or strings. v13 below adds a fail-closed guard for parser-context words that the lexer alone leaves as `Ident`.

**Previous latest-compiler parameter/local rename refresh (v13; superseded by v14 below):** The Darwin/arm64 release was built at `2026-09-30T22:38:02Z` from compiler HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2`, source fingerprint `766f5eadb9518b1c97282e3532e0f300a272e3f61d19356a34ed89e9a1946a5b`, and supported stage0 SHA-256 `ad85e4ac14bff8d2c579f55c297f474fb35929d744a5d911e03bced853c1fe91`. It used `-O2 -fno-builtin -Wl,-v`, LSP inputs `e4b6f3f908e5cecc262a4534cbda00f2613b836704e7bd82b4da56c5b7dde575`, 579 emitted include-closure files with hash `123bf20ff4ce73dc200d357e60d4096824b06a990bd726ef0db163c43efdac6d`, object SHA-256 `d0bea31dd2e3fa99f436ec759f52536e59e1e59ad6bb16c635a31789a4d4eb56`, and artifact SHA-256 `e879eb349f97e3882274c1346dc9ed68a4641b83451f617f5b715ebee4e96709`. Strict freshness and the exact-source canonical `81/81` suite passed. It also added the fail-closed rejection of bare lowercase ASCII rename candidates because the lexer leaves some parser-context words as `Ident`; see v14 for the current artifact and the next provider slice.

**Previous latest-compiler local-highlight refresh (v14; superseded by v15 below):** The Darwin/arm64 release was built at `2026-09-30T22:53:47Z` from compiler HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2`, source fingerprint `766f5eadb9518b1c97282e3532e0f300a272e3f61d19356a34ed89e9a1946a5b`, and supported stage0 SHA-256 `ad85e4ac14bff8d2c579f55c297f474fb35929d744a5d911e03bced853c1fe91`. It used `-O2 -fno-builtin -Wl,-v`, LSP inputs `918f498ff489b15e9a7503a929343f9ca533d93f0e99d8722c551a33b5805b74`, a 579-file emitted closure with hash `c206f4208c7900f262e447f1a668292fbc454ca897c7a74802f4a482d53aa9fc`, object SHA-256 `cee36205f8f6543e908ac97032769c5282139bddc37b6c5f2b14c329f770f3b1`, and artifact SHA-256 `862f7ffc5e006f8327a7ac93cfc4b7f747277e1aa54f0d01e32cdaa63944573e`. Strict freshness and the exact-source canonical `81/81` suite passed. It extended document highlights to exact parameter/local bindings while leaving the kind unspecified. See v15 for the current artifact and definition-navigation extension.

**Historical local-navigation refresh (v15; 2026-10-01 local time, superseded by the 2026-10-06 optimizer snapshot):** The Darwin/arm64 release was built at `2026-09-30T23:06:02Z` with `-O2 -fno-builtin -Wl,-v` from compiler HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2` and exact source fingerprint `766f5eadb9518b1c97282e3532e0f300a272e3f61d19356a34ed89e9a1946a5b`. It uses supported Go stage0 SHA-256 `ad85e4ac14bff8d2c579f55c297f474fb35929d744a5d911e03bced853c1fe91`; the latest fresh stage1 candidate remains unqualified because it cannot emit the complete LSP object (probe below), so this is a latest-frontend-source build without a stage1 optimizer or performance claim. Manifest: LSP inputs `8fcf96be6188c96632152e3be43416d41f9a675b5bfe3699fcc38941aa51541b`, compiler-emitted closure of 579 files with hash `f39edd455a374c1a857505964f2c167879b9993c21aeaabd5310767c3c03eb86`, object SHA-256 `79a3b1fb383046d60ee585324d7aa22822ad484becb2f6f70082754be31e29c6`, artifact SHA-256 `e2f025b2b10a567fec759e1a30a194b18709935e9ee2f524450f02b9699dd90b`, and build-pipeline hash `76efdc915662d309add93afe5a9070bd121a1eba30e06c2c40ddd51df1f7246d`. Strict freshness passes and this exact artifact passes the canonical suite `81/81`. Definition lookup now resolves parameter/local occurrences to their declarations through exact retained `BindingId` groups; parameter shadowing and nested same-spelling locals remain distinct. Document highlights also use those exact binding groups and omit the optional kind until read/write occurrence metadata is available; unique top-level function declaration/call `Text`/`Read` behavior remains. `test/definition_test.sh` and `test/document_highlight_test.sh` cover UTF-8/UTF-16 ranges, with the canonical suite additionally validating references, rename, worker recovery, and the latest frontend contract. The v13 conservative rename guard remains current. Cross-file navigation, other declaration categories, compiler-source stage1 compatibility, complete compiler-provided read/write classification, and the remaining open plan acceptance gates remain unimplemented.

**Current stage1 optimizer compatibility probe (2026-09-30):** The fresh `-O3` stage1 product SHA-256 `52a3c776e89f4cb7d89ea2aa661edcb6cc3409df1acf913eb5dcb9216fb573b1` passes `scripts/assert_stage1_fresh.sh` for the same compiler source fingerprint `766f5ead…`. In the disposable upgrade gate the stage0 baseline compiled successfully in 171.767 seconds, but stage1 failed before object emission in 13.541 seconds. Current diagnostics are the `u8` versus `sview` arguments at `parser_machine_laws.elisa:62`, integer value for the `name` `sview` field at `check_call_argument_exclusivity.elisa:397`, and the LSP `src/main.elisa:1366` `Abort` target that is not a parameter. The candidate produced no object; protocol parity, full candidate tests, and latency/RSS measurements therefore did not run. Keep supported stage0 as the release backend until stage1 can emit the LSP and then passes parity and benchmark gates. Probe record: `/tmp/elisa-lsp-stage1-latest-compile-probe.json`.

**Linux/aarch64 platform validation (source fingerprint `4c48ea7e…`; 2026-09-30):** `scripts/platform_validation.py` completed a fresh release build with stage0 SHA-256 `b0692d4f01eb7eaeb32141f1a15572f6bae44624633258baf1eb40b46bddd7be` and compiler source fingerprint `4c48ea7e85d65af62bdfc83f3e351151f1f354d4ef9e735d9ea755751b8fdb98`. Its manifest records build time `2026-09-30T01:02:04Z`, LSP input hash `6f2ff84e33a3b3a7de2b70c4de09a7cd17f358ad4f26f019a288d080c7a7f9ac`, 577-file compiler include-closure hash `13baf101c64fd6cc23586554c3a65cfd446d58a2faf1a49ea61dc8b1cfafc7c7`, object SHA-256 `f39e96b56c64700362a52ef6ad784f754826c16332250ca9be7db1e79971479c`, and executable SHA-256 `0b08ee63a2e6f99303db102368a25c8cc972c2a11a7db29216fb9767222697f9`. Strict freshness passes; the full canonical suite passes `78/78` in 1319.063 seconds with no failure markers. The retained report is `bench/platform-validation-Linux-aarch64.json`. This is a platform result for its recorded earlier source/artifact tuple; it does not establish Linux validation for the later v11 `766f5ead…` tuple.

**D01 lifecycle/store boundary evidence (2026-09-30; earlier artifact tuple):** Lifecycle transitions for accepted snapshots, generation/job assignment, `Pending`/`Ready`/`Failed`, close, diagnostics publication state, cache eviction, and freed-slot reuse now live in document-store operations. All ten provider entry points take a plain `DocumentSnapshotView`; dispatch resolves it per request, and source/cache commits, line-index rebasing, cache recency, and flat-store compaction are document operations. A view is message-local and cannot be retained over accepted updates, worker completion, close, eviction, or compaction. The earlier Darwin artifact was built at `2026-09-30T03:21:51Z` from LSP input hash `6714bab000b4dc038620728b49c85b0df6439b9e5a150b0caa8d0c1a777baccb` and compiler fingerprint `4c48ea7e…`, using stage0 SHA-256 `8982ace0e827d99ab1ac5539a3bce2a7896d1950fed8ef72d2d2bab6eeebbfd8`. Its focused provider, lifecycle, cache, storage reclamation, and eviction tests passed, as did the fault-injection recovery test. The current v11 artifact and full `78/78` suite at fingerprint `766f5ead…` are recorded above; the implementation findings here remain applicable, while the older artifact hashes are historical.

### 2.5 Standards baseline

Use the current LSP 3.18 specification as the conformance baseline. The [official LSP overview](https://microsoft.github.io/language-server-protocol/) still identifies 3.18 as the latest version (rechecked 2026-09-30). Use the official [LSP 3.18 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/) and [machine-readable metamodel](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/metaModel/metaModel.json) to verify wire types and feature contracts. Pin the exact metamodel revision used in tests. Gate optional behavior on the relevant client capabilities and preserve the specified fallback behavior for clients that do not advertise newer options; do not infer support from the editor name or version.

The transport uses byte-counted framing, while editor positions need their negotiated character representation. Requests and responses have distinct shapes. JSON-RPC defines errors and notification behavior; LSP further constrains supported message forms. Implement the LSP profile deliberately rather than assuming every generic JSON-RPC extension applies. See the [JSON-RPC 2.0 specification](https://www.jsonrpc.org/specification).

The detailed architecture, performance targets, rollout policies, and feature designs below are proposed engineering decisions. Check each protocol-facing change against its applicable specification section during implementation.

## 3. Target architecture and invariants

### 3.1 Proposed module boundaries

| Proposed module | Responsibility | Must not own |
|---|---|---|
| `src/main.elisa` | Startup, dependency wiring, event loop, shutdown | Feature-specific parsing and ad hoc JSON assembly |
| `src/transport.elisa` | Buffered input, frame parsing, complete output writes | Documents or semantic analysis |
| `src/json.elisa` | Strict JSON parsing and writing | LSP method dispatch |
| `src/protocol.elisa` | Envelope validation, typed field access, IDs, errors, capabilities | Compiler internals |
| `src/session.elisa` | Lifecycle, negotiated capabilities, pending request IDs | Mutable source buffers |
| `src/positions.elisa` | Byte offsets, line index, encoding conversions, range validation | Semantic classification |
| `src/documents.elisa` | URI-keyed authoritative text, versions, immutable snapshots | Language-specific symbol lookup |
| `src/workspace.elisa` | Roots, project options, virtual files, dependency graph | Client-specific styling |
| `src/frontend_adapter.elisa` | Stable tooling interface to compiler parse/check/query results | JSON serialization |
| `src/analysis.elisa` | Analysis snapshots, queries, dependencies, invalidation | Stdio operations |
| `src/scheduler.elisa` | Priorities, cancellation, coalescing, generation checks | Source rewriting semantics |
| `src/diagnostics.elisa` | Diagnostic mapping, push/pull presentation | Reimplementing checker rules |
| `src/semtokens.elisa` | Semantic classification and token result caching | Request envelope parsing |
| `src/features/*.elisa` | Hover, completion, navigation, rename, formatting adapters | Independent symbol tables |
| `src/config.elisa`, `src/logging.elisa` | Validated configuration and bounded observability | Unconditional logging to stdout |

Extract modules incrementally with parity tests. Elisa include/module semantics and region ownership must be proven with a small compiling slice before committing to every boundary. Avoid a broad mechanical rewrite before the clean-build gate.

### 3.2 Core data contracts

**Document identity:** Keep the client's decoded URI for protocol output. Maintain any canonical filesystem identity separately. JSON unescaping, URI percent-decoding, path normalization, and symlink resolution are different operations and must not be conflated.

**Document state:** Track a stable document ID, original URI, explicit open/closed state, client version, internal generation, language ID, source bytes, line index, and analysis status. Empty source is a valid open document. Compiler NUL termination is an adapter concern and is excluded from logical source length.

**Text snapshot:** An immutable source revision identified by document ID and internal generation. Analysis and outgoing edits retain a snapshot handle rather than pointers into relocatable session storage.

**Analysis snapshot:** Retain the source snapshot, compiler/configuration revision, dependency fingerprints, diagnostics, recoverable syntax data, symbols, occurrence index, and token spans. A published snapshot is immutable. Document acceptance and analysis success are separate events.

**Source range:** A physical file identity plus half-open byte offsets into a particular snapshot. Derived LSP positions are calculated only at the protocol boundary. Generated or remapped code carries explicit provenance.

**Symbol identity:** A compiler-backed identity associated with a definition, owning scope/module, kind, visibility, and provenance. Stability is required inside a snapshot and its dependency graph. Across revisions, resolve/revalidate identities; do not promise permanent IDs derived only from names.

**Occurrence:** Exact source span, resolved symbol identity when available, role (declaration/reference/read/write/type/etc.), semantic kind, and modifiers. Unresolved/ambiguous occurrences are represented explicitly.

**Request context:** Original typed ID, method, selected snapshots, cancellation state, capability profile, and exactly-once completion state. Numeric ID `1` and string ID `"1"` are distinct.

**Cache key:** Include the source generation, frontend revision, project options, relevant dependency revisions, feature settings, and any client-specific token legend or encoding. Source text alone is not a sufficient key for semantic results.

### 3.3 Non-negotiable invariants

- The document store reflects accepted edits even when parsing or checking fails.
- No response combines ranges from one revision with semantic facts from another.
- No retained `sview` points into a reclaimed request buffer or moved source allocation.
- Source text from one URI never answers another URI's request.
- Close/reopen changes generation even when the URI and client version repeat.
- No provider may treat a lexical guess as a proven symbol for an editing operation.
- All outgoing JSON strings use a shared writer; source text is never inserted unescaped.
- All outgoing frames are complete and serialized through one writer.
- Cancellation, completion, close, and shutdown races cannot produce duplicate responses.
- Expensive work can be discarded without discarding authoritative text.
- The server never runs workspace code merely to answer editor requests.
- Unsupported capabilities remain unadvertised until their fallback and error behavior are tested.

## 4. Milestones and dependency order

| Milestone | Work items | Exit condition | Size |
|---|---|---|---|
| M0: Trustworthy baseline | B01–B04 | Fresh reproducible build; structured test harness; current behavior captured | M |
| M1: Correct server core | T01–T03, J01–J03, P01–P03 | Framing, JSON, lifecycle, errors, and capability tests pass | L |
| M2: Exact document state | D01–D04, U01–U03 | Versioned edits and Unicode round trips correct; storage bounded | L |
| M3: Shared compiler tooling | A01–A04, G01–G03, H01–H04 | Precise diagnostics/highlighting and owned semantic snapshots | XL |
| M4: Essential IDE features | F01–F07 | Hover, symbols, definition, references, completion, signature help, safe local rename | XL |
| M5: Real projects | W01–W04, F08–F09 | Unsaved multi-file analysis, reliable cross-file edits, configuration invalidation | XL |
| M6: Responsive at scale | Q01–Q04, H05, G04 | Cancellation works during analysis; benchmarks and soak gates pass | L–XL |
| M7: Editing polish | E01–E06 | Formatting, actions, hints, structural features proven and capability-gated | XL |
| M8: Release discipline | R01–R05 | Supported-client matrix, clean packaging, docs, regression/performance release gates | L |

Some work should begin before its milestone exits: measure performance at M0, design scheduling contracts at M2, prototype project resolution at M3, and run real-client checks as soon as M1 exists. Do not postpone discovery of compiler API constraints until M4.

Critical path: clean build → protocol/document correctness → exact spans and owned analysis → symbol identity → local features → dependency-aware workspace → safe cross-file edits. Responsiveness infrastructure must land before calling the result a daily driver.

## 5. M0 — Build and test foundation

### B01 — Reproducible toolchain and frontend compatibility [P0, M]

**Locations:** `build.sh`, `project.json`, `docs/development.md`, and `build/manifest.json`.

- [x] Discover and document the supported Elisa compiler installation/build procedure; accept an explicit `ELISAC` executable path and fail with an actionable error when unavailable (`build.sh`, `docs/development.md`, `test/build_script_test.sh`).
- [x] Record compiler revision, frontend revision, native linker version, target triple, flags, and exact compiler/artifact hashes in a machine-readable build manifest. Stage0 has no version flag; the manifest says so rather than inventing a version (`build/manifest.json`).
- [x] Record the stage0 compiler's source revision, dirty state, and reproducible build recipe separately from the Elisa frontend revision; the executable hash pins the compiler used but does not identify which source branch produced it.
- [x] Keep the stage0 C-ABI fixes and regression cases in the supported compiler source line, and pin the exact stage0 source revision and executable in the LSP manifest. Revision `e42bbdfe8a1b8123c3c4bfd096d64eb4c97c8b11` is also `origin/main`; the focused `memset`/`memcmp` ABI tests pass (`Go projects/Elisa-core/compiler/src/backend/llvm_resize_zero_init_test.go`).
- [x] Resolve `TestAnalyzeRejectsDotModulePathInTypePosition` against the language grammar: `.` accesses value members, `::` accesses namespaces. The supported stage0 semantic regression now passes on revision `e42bbdfe8a1b8123c3c4bfd096d64eb4c97c8b11` (`Go projects/Elisa-core/compiler/test/semantic/semantic_namespaces_test.go`).
- [x] Prefer the compiler-emitted dependency manifest (`-emit deps-json`); for older stage0 binaries, use the compiler-identical recursive include parser and finally a conservative source-tree fallback. `scripts/build_hashes.py` normalizes the report into portable `lsp/...` and `compiler/...` paths with per-file content hashes, and the resulting closure fingerprint is recorded in `build/manifest.json`, checked against the immutable staged tree, and recomputed by `scripts/check_build_freshness.py` for editor/canonical test gates. On the current latest compiler checkout the LSP entry resolves to 543 source files; edits to files outside that closure no longer invalidate a fresh artifact, while changed included files, include graph roots, and compiler reports fail closed. The conservative whole-`src`/`elisacore_std` hash remains as snapshot integrity evidence and as the safe fallback when a legacy compiler cannot provide a trustworthy closure.
- [x] Add a disposable compiler-upgrade gate that builds a baseline and candidate in isolated LSP trees, runs the same protocol/provider corpus, and records compiler/frontend revisions, flags, executable/object sizes, outputs, timings, and benchmark distributions (`scripts/compiler_upgrade_gate.py`). A candidate is eligible for adoption only when the gate passes semantic/protocol parity and the configured latency budget; the 2026-09-15 `05289f04` optimizer snapshot remains stage1-only and is not adopted.
- [x] Replace the implicit sibling-checkout dependency with a deliberate configured include root: `ELISA_COMPILER_ROOT` selects it and the adjacent checkout is the documented development default; the selected source revision/hash is recorded.
- [x] Keep a development override for an adjacent or separately located compiler checkout, with its actual revision recorded.
- [x] Consolidate build settings so `project.json` owns source/output paths and named profile levels, with validation in `build.sh`.
- [x] Build in a temporary output location and promote artifacts only after compilation, linking, and manifest generation succeed; failure-preservation behavior is tested.
- [x] Add debug and optimized profiles. Sanitizer support is explicitly reported unavailable because stage0 exposes no object instrumentation option; clang-only link flags are not misrepresented as instrumentation.
- [x] Establish macOS and Linux as initial validation candidates; declare a platform supported only after fresh build and protocol tests pass there.

**Platform evidence (2026-09-30):** Darwin/arm64 has a fresh stage0 O2 artifact SHA-256 d363102b69c5eb8bd0f52708ace99d7a87f916317f56798fc44a84c0288ff10c, a passing strict freshness check, and the canonical suite at 78/78 for LSP input hash 6f2ff84e33a3b3a7de2b70c4de09a7cd17f358ad4f26f019a288d080c7a7f9ac. Linux/aarch64 has its own fresh stage0 O2 artifact SHA-256 0b08ee63a2e6f99303db102368a25c8cc972c2a11a7db29216fb9767222697f9, a passing strict freshness check, and 78/78 canonical tests with no failure markers in bench/platform-validation-Linux-aarch64.json for that same LSP input. A direct fetch and ls-remote check confirmed compiler origin/main matches local HEAD 54360bf68398b4da8d63b82a3ad2979667798aa2. Both initial full-suite artifacts use compiler source fingerprint 4c48ea7e85d65af62bdfc83f3e351151f1f354d4ef9e735d9ea755751b8fdb98. After the D01 ownership refactor, a newer Darwin/arm64 artifact uses LSP input hash 75baf33a62670e7b6693d03e23ab2bc3ff26d6d5ab0afabf8ce49e1a91e26cff, include-closure hash 10bd2d6000a591638480596faaaff0e0ab897f772316cf5e1b47240345b98e78, object SHA-256 24e8f11bbc69775eea90e442b0cf41868cfb3a3a5b450e86660aaaab75d99b53, and executable SHA-256 b62ecea98d54fb6271b84fb875f353142d43febf62db1d100f29e30a189bbb7d. Strict freshness passes and `bash test/run_all.sh` now passes 78/78 on this newer input. Its first run was 77/78 only because `failed_analysis_request_test.sh` fault-injection text still named the former flat fields; those test-only mutation sites now target the nested records, pass in isolation, and pass in the canonical rerun. The current Darwin input is fully suite-validated; Linux still needs a native full-suite rerun for this newer LSP input. Other architectures remain unvalidated.



**Progress (2026-09-15):** The manifest now records Go build metadata embedded in stage0 under a distinct `stage0_provenance` object, including source module/revision, commit time, dirty-at-build state, Go version, target OS/architecture, and a reproducible `go build` recipe. Missing or non-Go metadata remains explicit and non-fatal. The current release artifact was rebuilt with the latest supported stage0 found in the environment, revision `601f7bcd3de62877723ab7f5c5f9a502fb6ef9ae` (`vcs.modified=false`, Go 1.27.1, darwin/arm64; binary SHA-256 `51f5f5f1f33c65f71bb6a17acae8fcc45c74009ff27f6209a93a06ecd3d39b62`), against latest frontend revision `8d7db0561d0f72c1f548fa6a73d071c86b2fe57f` with dirty source fingerprint `429c49c0960305dd9e559437c64d331548a83b7d0e4f082f73307954a936c52b`. The artifact manifest records LSP input fingerprint `335e38a432a890afa227b7f2d1f635402176a70f57d6351cffc01d6c6f83b4fa`, object SHA-256 `9ab9214787ba4d9cde8a6f539b25462e2abf159ebbb7d2a28696f6399e759d7f`, executable SHA-256 `f3f0317d77bb44e7c597dd91bb2b24fdd86e3b904d64bbbdac81f8d774bb5913`, and compiler include-closure SHA-256 `7cc38cfe52ab601f599e4669df769ce186d72d9fdbaa162a3586c01e0ac622ce`; `scripts/check_build_freshness.py` passes. A newer optimizer snapshot exists at `05289f0430b359b4a28b761590a6a623f8497aec`, but it provides only `elisac-stage1`; the repository build rejects stage1 because it has not passed LSP feature-parity validation. A disposable `-O2` object-only compile of the complete LSP source with that exact candidate failed with an `Abort` effect-target error and region-lifetime escape diagnostics and emitted no object. That candidate is not represented as the compiler used by the current artifact. The upgrade gate must verify stage1 feature parity before adopting its optimizations. Fake non-Go, missing metadata, clean, and dirty parser cases pass; the focused pinned analysis-worker, frontend-contract, and URI-collision gates pass. The combined-lexer regression is included in the current 75-test inventory. The exact rebuilt artifact passes the complete canonical suite at `75/75`; an earlier run under concurrent host load had `74/75` only because `build_script_test.sh` hit its bounded fake-compiler dependency-report timeout, and that test passed in isolation. Rerun the complete suite after toolchain or source changes.

**Dependency-closure progress (2026-09-15):** The current release manifest records the compiler-emitted normalized include closure rather than hashing every backend file: 543 files, logical `lsp/...` and `compiler/...` names, per-file SHA-256 records, and aggregate closure hash `7cc38cfe52ab601f599e4669df769ce186d72d9fdbaa162a3586c01e0ac622ce`. `build.sh` validates the closure before and after staging/compilation; freshness, platform, and upgrade gates recompute the same closure. Older compilers fall back to recursive include parsing or a conservative source-tree set and state the mode in the manifest.

**Upgrade-gate progress (2026-09-15):** `scripts/compiler_upgrade_gate.py` now performs a disposable baseline/candidate build, runs the canonical protocol/provider suite, records exact binary/source/manifest identities and benchmark summaries, and refuses a passing result when the candidate fails compilation/tests or exceeds the configured p95 latency budget. It gives the stage1 probe a temporary non-stage1 filename only inside the isolated copy; ordinary release builds still reject stage1. The known `05289f04` candidate therefore remains documented as a failed/unevaluable optimizer until a future run compiles the complete source and passes the parity corpus.

**Platform-validation progress (2026-09-15):** `scripts/platform_validation.py` and `test/platform_validation_test.py` provide a host-side Darwin/Linux gate. The runner captures OS/architecture, clang target/version, compiler/frontend fingerprints, manifest identity, bounded command tails, and timings; it reports `validated` only when the caller requests a fresh release build, the freshness check passes, and `test/run_all.sh` completes successfully. It never cross-compiles and marks omitted phases `incomplete`, so a macOS result cannot silently establish Linux support. The focused contract test passes on the current Darwin host. Linux remains unchecked until the same command produces a `validated` report on Linux.

**Current artifact refresh (2026-09-15 05:24 UTC):** The release manifest now points at frontend revision `8d7db0561d0f72c1f548fa6a73d071c86b2fe57f` and source fingerprint `429c49c0960305dd9e559437c64d331548a83b7d0e4f082f73307954a936c52b`; the generated diagnostic adapter contains 552 current frontend diagnostic kinds, the combined lexer entry point is covered by `test/combined_lexer_test.sh`, and the indexed frontend adapter now has explicit collision-safe hash-chain helpers and resolver-backed navigation accessors. The latest release build uses LSP input fingerprint `335e38a432a890afa227b7f2d1f635402176a70f57d6351cffc01d6c6f83b4fa`, include-closure fingerprint `7cc38cfe52ab601f599e4669df769ce186d72d9fdbaa162a3586c01e0ac622ce`, object SHA-256 `9ab9214787ba4d9cde8a6f539b25462e2abf159ebbb7d2a28696f6399e759d7f`, and artifact SHA-256 `f3f0317d77bb44e7c597dd91bb2b24fdd86e3b904d64bbbdac81f8d774bb5913`. The canonical suite inventory contains 75 tests and the exact rebuilt artifact passes `75/75`; an earlier run under concurrent host load had `74/75` only because `build_script_test.sh` hit its bounded fake-compiler dependency-report timeout, and that same test passed in isolation. The rebuilt artifact is freshness-checked and the changed adapter, combined-lexer, unsupported-construct, cache, identity, and provider gates pass.

**Acceptance:** A documented clean setup builds from source without the author's home-directory layout, emits provenance, and passes all current tests. Missing tools and incompatible frontend APIs fail clearly before linking.

**Current compiler gate (2026-09-29):** The current fresh Darwin/arm64 release build uses the supported Go stage0 binary at revision `e42bbdfe8a1b8123c3c4bfd096d64eb4c97c8b11` (SHA-256 `850a8979e17bd28f1cb91e3c88665f6707b71d83e263f280dbd152458184ea6e`) against self-hosted compiler/frontend source at local HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2` (source fingerprint `ecd23c2e0a2f0ce74760bbf0e4200f06fa3405c5af9383ab70b8d13e2e4b4eb3`). Current LSP-input hash is `90070ea21f6f12dd4c195439eee55c4c25cdb0c1ed50e4bdab3462fd84c84df4`, and the current executable hash is `a46cecb9ce36a38dcbaca0f7116416cc61ee966ada03bbcdc3c475969d7c9ad2`; manifest freshness passes. The 76-test suite passed for the preceding exact artifact recorded above; the current artifact has passed the new 48-category token fixture, core/contextual/f-string token suites, manifest check, and freshness, but not a full-suite rerun. The fresh stage1 product `109866537fb2889075edf485d829333d795b6468bcafa529343d0f9a1fb1c5cc` passes source freshness, but direct LSP object probes fail before emission at `-O2`, `-O1`, and `-O0`, each declining 1,887 functions. No stage1 parity suite or benchmark ran, so its newer default memory optimizations and optional `-fnoalias` remain unqualified for this workload. The earlier disposable gate report's stage0 baseline result (`73/75`) conflicts with the direct run for its old tuple (`75/75`); treat it as an unresolved gate-baseline issue. Exact hashes and reports are in §2.4.

**Supported-stage0 compatibility follow-up (2026-09-29):** The Go stage0 source checkout is clean at `e42bbdfe8a1b8123c3c4bfd096d64eb4c97c8b11`, and a read-only remote check reports the same commit at `origin/main`. The focused C ABI backend tests for `memset`'s C `int` argument, `memcmp`'s `int` result, and zero-initialization `memset` lowering pass with `go test ./src/backend -run 'TestGenerateLLVMIR(ResizeMemset|StringMemcmp|ZeroedMemset)MatchesCIntDeclaration' -count=1`. The grammar decision is covered by `go test ./test/semantic -run TestAnalyzeRejectsDotModulePathInTypePosition -count=1`: dotted module paths are rejected in type position with the namespace hint, and `::` remains the namespace separator. The fresh release manifest pins this stage0 executable and source revision separately from the latest self-hosted frontend fingerprint. Linux validation and qualification of the stage1 optimizer candidate remain open.

### B02 — Structured protocol test harness [P0, M]

**Locations:** `test/lsp_client.py`, `test/run_all.sh`; migrate remaining shell tests incrementally.

- [x] Start one real server subprocess per isolated test, with bounded startup, request, and teardown deadlines.
- [x] Frame UTF-8 byte payloads, parse output by exact Content-Length, and feed every body through an independent JSON implementation.
- [x] Support interactive send/wait sequences, interleaved notifications, raw malformed frames, fragmented writes, and pipelined requests.
- [x] Match responses by typed ID and preserve notification order without assuming diagnostics precede unrelated responses.
- [x] Fail on malformed headers, truncated output, duplicate responses, unexpected stdout bytes, and crash exit codes.
- [x] Add configurable assertions for unexpected stderr errors, with per-line regex allowances and a hard failure when the captured tail was truncated (`LspSession.assert_no_stderr_errors`; `test/lsp_client_selftest.py`).
- [x] Drain stdout and stderr concurrently; terminate and reap the process tree on timeout.
- [x] Make temporary integration-test cleanup restore write permission before deleting content-addressed read-only compiler snapshots; ensure cleanup errors do not obscure whether protocol assertions passed (`test/failed_analysis_request_test.sh`, `test/analysis_worker_test.sh`, `test/uri_collision_test.sh`). Cleanup restores owner write permission only under its private temporary root, reports an unsuccessful removal as a warning, and preserves the test's exit status.
- [x] Make missing binaries a test failure in the required suite. The hover smoke test also fails when the binary is missing.
- [x] Verify that the executable hash and current LSP/project input fingerprint match the provenance manifest before running the suite; check recorded compiler source/binary hashes when those paths remain available (`scripts/check_build_freshness.py`, `test/build_script_test.sh`).
- [x] Encode ordinary valid fixtures with JSON serialization; keep raw JSON bodies for deliberate malformed-input and escaped-spelling regressions.
- [x] Give normal initialize and didOpen fixtures the required capabilities object and document metadata; keep invalid metadata and abnormal exit in explicit negative tests.
- [x] Migrate normal sessions to initialize/initialized/shutdown/exit through the shared helper. Coverage includes handshake, capabilities, hover/definition/references/highlights, URI, document lifecycle/multi-document, outline/folding, selection, semantic tokens/ranges, position-provider integration, incomplete-source recovery, diagnostics/related information/version/ranges, numeric-field validation, precedence, multiline/f-string tokens, escape decoding, full/incremental sync, storage reclamation and forced hash collisions, signal exits, and manifest lifecycle/capability validation. Raw subprocess framing remains only in tests whose subject is transport/framing, protocol state, cancellation, strict/differential JSON, or deliberately malformed capability/wire bytes; the position test's direct compiler probe remains separate from its migrated live-server session. Numeric-field validation uses `frame_bytes` for malformed number spellings inside an otherwise shared lifecycle.

**Acceptance:** Deliberately truncated frames, wrong byte counts, duplicate IDs in responses, unexpected error-like stderr, and crashed processes cause clear harness failures. The 10 harness self-tests cover framing, UTF-8 bodies, typed IDs, deadlines, resource bounds, stderr checks, and process reaping.

### B03 — Golden fixtures and feature manifest [P1, M]

- [x] Add small Elisa fixtures for every current semantic-token family, diagnostic path, loop-header hover case, and document transition (`test/semtoken_families_test.sh` asserts exact spans across the 48 legend entries; focused semantic-token, diagnostic/range/version/recovery, loop-header hover, and document-lifecycle tests cover the other paths).
- [x] Store expected ranges and classifications per occurrence, not dictionaries keyed only by token text; repeated names remain distinguishable (`test/semtokens_test.sh` addresses `Event` and enum variants at declaration/type/use positions; `test/contextual_tokens_test.sh` distinguishes the `can` parameter declaration/use from the effect-grant keyword).
- [x] Define a feature manifest mapping advertised methods/options to implementation modules and required tests (`docs/feature-manifest.json`; checked against live capabilities by `test/manifest_test.sh`).
- [x] Compare protocol expectations as decoded JSON objects through `LspSession`, independent of field order and whitespace (`test/lsp_client.py`; provider tests assert parsed values).
- [x] Record unsupported language constructs separately from server regressions and compiler regressions (`docs/unsupported-constructs.json`, `test/unsupported_constructs_test.sh`). Compiler-rejected/removed spellings are direct probes against the manifest-pinned stage0 binary; compiler-accepted constructs that current providers decline are separate records with explicit `null`/`[]` behavior and provider tests.

**Fixture progress (2026-09-14; 48-category inventory closed below on 2026-09-29):** `test/semtokens_test.sh` now checks exact token ranges and classifications for repeated enum type/variant names, function declarations and calls, integer/float/string/character/value literals, punctuation, mutation, assignment, arithmetic, comparison, and core type families. `test/contextual_tokens_test.sh`, `test/fstring_semtokens_test.sh`, and `test/multiline_tokens_test.sh` add binding-vs-keyword, interpolation, and multiline span cases. Diagnostic, loop-header hover, and document-transition paths have separate focused tests. The compiler-confirmed unsupported-construct inventory is now split into 18 rejected/removed compiler spellings plus 5 compiler-accepted provider limits, with 19 direct `-emit obj -O0` probes and provenance checks against the latest manifest-pinned compiler (`docs/unsupported-constructs.json`, `test/unsupported_constructs_test.sh`).

**Complete token-family fixture (2026-09-29):** `test/semtoken_families_test.sh` adds a compact Elisa document and 314 occurrence-addressed token spans covering every one of the 48 advertised categories in that fixture itself. It exercises fields and constants, effect rows (including dotted `Abort.Panic` members), discard patterns, contracts, memory and flow constructs, operators, decorators, directives, modules, comments, types, literals, functions, and enum variants. This caught an effect-row suffix being styled as an ordinary value field; classification now treats a dotted suffix inside an effect row as `elisa.effect.name`. The fixture runs from the canonical suite. Existing focused tests still own diagnostic, loop-header-hover, document-transition, incomplete-source, and versioned-publication behavior.

**Acceptance:** A changed legend entry, wrong second occurrence of a repeated name, or newly advertised but untested capability is detected.

### B04 — Baseline measurements and issue inventory [P1, S]

- [x] Measure startup, clean-open analysis, one edit, cached token response, and specialized hover on small/medium/large fixtures.
- [x] Record wall time, CPU time where available, RSS, source bytes, token count, and toolchain provenance.
- [x] Convert every observed failure into a minimal reproducer and link it to the corresponding work item.
- [x] Capture baseline long-session storage behavior without interpreting allocator-retained memory as a proven leak.

**Baseline observation (2026-09-13):** `bench/baseline-2026-09-13.json` records deterministic fixtures from 100 to 5,000 functions, one sample per operation. On the 5,000-function / 302,780-byte fixture, clean open through the first semantic-token response took 14.016 s, an edit through retoken took 18.887 s, hover after opening took 17.083 s, and cached tokens took 0.030 s. These are reproducible latency failures for A03, Q01, and G04 investigation; the short cached-token path contrasts with the multi-second analysis path. The same artifact records one 20-cycle, 100-function storage soak: tracked storage peaked at 95,467 bytes (50,311 live bytes), returned to 0 bytes after close, retained one reusable slot, and peaked at 6.9 MB RSS. These counters describe LSP-owned flat storage and process RSS only; they do not prove allocator-wide leak freedom. Re-run with `python3 test/bench.py --sizes 5000 --samples 3` when measuring fixes.
**First optimization check (2026-09-13):** `bench/after-line-index-2026-09-13.json` uses the same 5,000-function source and toolchain provenance, with three independent process samples per operation. After semantic-token normalization switched to a shared line-start index, the median was 3.821 s for clean open, 3.948 s for an edit, 5.098 s for hover, and 0.014 s for cached tokens. Compared with the one-sample baseline, these medians are about 3.7×, 4.8×, 3.4×, and 2.2× faster respectively. The large-sample latency varies substantially on this host, so treat the comparison as preliminary, not a performance gate. The dominant analysis path remains several seconds and still needs stage profiling.

**Current stage0 control (2026-09-28):** `bench/stage0-current-2026-09-28.json` records three independent processes per operation against the fresh 2026-09-28 stage0 artifact (`794a2d3d…`), using a deterministic 1,000-function / 58,780-byte source. Round-trip medians were 2.576 s for clean open, 2.766 s for edit, 0.623 s for cached semantic tokens, and 0.790 s for hover; startup median was 6.4 ms. Across the three samples, nearest-rank p95 equals the maximum: clean open 4.349 s, edit 4.641 s, cached tokens 0.648 s, hover 2.528 s. The spread—especially on open and hover—shows substantial host noise, so these observations are a reproducible control artifact, not a regression threshold or an optimizer comparison. A three-sample 20-cycle/100-function storage soak ended with `live_bytes=0` in all samples, retained `storage_capacity=182,880` bytes per server, and median peak RSS 7,634,944 bytes. The benchmark manifest and source hashes are embedded in the JSON. Stage1 could not produce the matching artifact, so its optimizer delta remains unmeasured.

**Acceptance:** Benchmarks can be rerun with a single command and comparable environment metadata. Numbers in later performance gates are explicitly targets until measured.

## 6. M1 — Transport, JSON, and protocol correctness

### T01 — Buffered and bounded input framing [P0, M]

**Depends on:** B02. **Locations:** extract transport from `src/main.elisa`.

- [x] Replace per-byte allocation/syscalls with an 8 KiB reusable read buffer and explicit header/body parsing states.
- [x] Preserve unread bytes when a read contains several messages or only part of a message.
- [x] Parse case-insensitive ASCII header names and bounded whitespace according to LSP framing; require a valid decimal Content-Length and CRLF line endings (`src/main.elisa`, `test/transport_test.sh`).
- [x] Reject negative, nonnumeric, overflowing, or conflicting duplicate lengths. Identical duplicate lengths are deliberately tolerated and tested.
- [x] Set configurable maximum header bytes, header count, and body bytes, with conservative documented defaults and hard ceilings; body size supports an explicit large-file override (`ELISA_LSP_MAX_*`, `src/transport_posix.c`, `test/transport_limits_test.sh`).
- [x] Validate content type/encoding; accept compatible UTF-8 spellings and ignore only syntactically valid additional ASCII headers (`test/transport_test.sh`).
- [x] Distinguish clean EOF, truncated header/body, interrupted syscall (retry), and terminal read failure in transport outcomes (`src/main.elisa`, `src/transport_posix.c`, `test/output_write_test.sh`).
- [x] Treat framing corruption as a controlled session failure when resynchronization is unsafe. The parser stops at the first invalid boundary and never scans for a later apparent frame (`test/transport_test.sh`).
- [x] Route a zero-byte body through malformed-message handling rather than interpreting it as a successful exit; it gets a structured ParseError and later frames remain synchronized.

**Acceptance:** Every split point in representative messages is tested, including multibyte UTF-8 boundaries; concatenated frames decode correctly; oversized/overflowing input terminates or rejects predictably without excessive allocation.

### T02 — Complete output writes and stdout discipline [P0, S]

- [x] Loop until all header/body bytes are written, retrying interrupted writes where appropriate.
- [x] Handle zero-progress writes, broken pipes, and terminal errors without a busy loop.
- [x] Keep one serialized frame writer for the current synchronous dispatcher; queue/multiplexing is deferred until concurrent workers exist.
- [x] Avoid copying the complete serialized body into a second framed-output allocation; write the small Content-Length header followed by the already-built body (`src/main.elisa`).
- [x] Calculate byte length after serialization, including non-ASCII strings.
- [x] Keep logs and compiler chatter off stdout; the shared client rejects unexpected stdout bytes.
- [x] Apply bounded output backpressure for slow clients: nonblocking stdout during each frame, one monotonic deadline shared by header/body, then controlled nonzero exit on timeout.

**Acceptance:** An injected short-write transport reconstructs the exact response stream; a disconnected client exits nonzero; a stalled client is bounded by the configured whole-frame deadline; no later frame follows a possibly partial frame.

**Progress (2026-09-14):** `send_message` writes the small header and existing body under one monotonic frame deadline, removing the second body-sized copy and bounding time spent on a stalled client. Stdout switches to nonblocking mode only for the frame and restores its prior blocking bit afterward. `ELISA_LSP_WRITE_TIMEOUT_MS` defaults to 15 seconds and accepts 100–120,000 ms. `test/output_backpressure_test.sh` covers config bounds, pipe timeout, SIGTERM interruption, and flag restoration; `test/output_stall_server_test.py` confirms a real oversized response exits with a partial final frame and no continuation. The current synchronous dispatcher is the sole writer; a queue is a prerequisite only when concurrency is introduced.

### T03 — Process lifecycle and cleanup [P0, S]

- [x] Define exit status and restore transport/signal state for EOF, explicit exit, fatal framing/output failure, and POSIX termination.
- [x] Reclaim document/cache memory through process teardown and stop/reap any in-flight analysis child within the bounded worker deadline on timeout or termination (`src/analysis_worker_posix.c`, `test/analysis_worker_posix_test.sh`).
- [x] Add a POSIX adapter for read/write and signal handling; its host-independent C test covers signal capture, interrupted waits, and restoration (`src/transport_posix.c`, `test/termination_signal_test.sh`). Windows remains unsupported and requires a separate adapter.
- [ ] Consider client process-ID monitoring only after validating platform semantics and avoiding PID-reuse mistakes.

**Progress (2026-09-14):** The adapter records SIGINT/SIGTERM/SIGHUP using only `sig_atomic_t`, makes the single input fd nonblocking while installed to close the pselect/read race, and restores prior signal dispositions and the original blocking mode. `main` checks for termination at event-loop boundaries and restores adapter state for EOF, explicit exit, framing failure, output failure, and signal exits. `test/termination_signal_test.sh` exercises the C adapter and `test/termination_server_test.py` verifies all three real-server exit codes. Analysis now runs in a short-lived child; while the parent drains the result, it observes a pending termination within a 25 ms poll slice, then kills and reaps the child. The synchronous event loop still cannot service a new LSP message during that interval. Explicit document-cache teardown remains open; process exit currently reclaims that memory.

**Acceptance:** Tests verify normal and abnormal process outcomes, no orphaned workers, and no repeated teardown crash.

### J01 — Strict parser with explicit errors [P0, M]

**Depends on:** B02. **Location:** `src/json.elisa`.

- [x] Return either a parsed value or a structured error containing byte offset and error category.
- [x] Require one complete value followed only by permitted whitespace.
- [x] Validate literal spelling, number grammar, required colons/commas/closing delimiters, and string termination.
- [x] Reject unescaped control characters, unsupported escapes, malformed hex sequences, and invalid UTF-8.
- [x] Decode valid surrogate pairs. Define a deliberate invalid-surrogate policy that never forwards invalid Unicode to document storage.
- [x] Bound nesting, value count, decoded string size, and total parser allocation through a 16 MiB input bound plus strict-validator limits; ensure every parsing loop advances or returns an error.
- [x] Define duplicate-object-key handling consistently: decoded-key lookup is first-member-wins, and duplicate top-level `jsonrpc`, `method`, `id`, or `params` members are rejected to avoid ambiguous envelope interpretation.
- [x] Preserve zero-copy spans only where lifetime ownership is explicit; checked parse results borrow the input and the server consumes them before the body buffer is reused.

**Acceptance:** A table-driven positive/negative JSON corpus and fuzz seeds cover truncation at every byte, malformed nesting, surrogate cases, invalid numbers, and resource limits without hang or crash.

### J02 — Typed accessors and one JSON writer [P0, M]

- [x] Replace permissive `as_i64` use for protocol fields with tagged checked results, overflow detection, and typed LSP `integer`/`uinteger` bounds; document versions are required and their signed values cannot collide with parse errors.
- [x] Distinguish absent fields (`get` returns no value), explicit null (`StringParseOutcome.Null`), wrong types (`StringParseOutcome.WrongType`), and a valid empty string.
- [x] Decode keys and method names before semantic comparison or provide a validated equivalent comparison routine.
- [x] Introduce shared string and signed-integer writers for hover, URIs, diagnostics, workspace paths, and errors; validated IDs preserve their original JSON token, and the writer is ready for completion documentation.
- [x] Validate numeric IDs against LSP's signed 32-bit `integer` domain and string IDs by JSON string type. Preserve exact numeric/string meaning; use null only where an error response cannot identify a valid request.
- [x] Avoid unnecessary decode/re-encode work when a validated raw JSON token can be safely echoed.

**Acceptance:** Escaped quotes, backslashes, control characters, supplementary Unicode, and embedded newlines round-trip in every outgoing string field. Fractional or overflowing position/version fields are rejected rather than coerced.

### J03 — Parser differential and property tests [P1, M]

- [x] Compare supported valid JSON values against Python's JSON implementation using a deterministic seed and curated strict cases (`test/json_differential_test.sh`).
- [x] Explicitly test stricter project policies where reference parsers accept extensions or duplicate keys (`test/json_strict_test.sh`, `test/protocol_test.sh`).
- [x] Property-test encode/decode equivalence and the guarantee that invalid input never returns an apparently valid partial root (`test/json_differential_test.sh`: 406 seeded round trips and 205 malformed roots).
- [x] Seed regression tests with the minimized parser failures collected to date (`test/json_strict_test.sh`, `test/protocol_test.sh`, and the differential malformed-root corpus).

**Acceptance:** Deterministic seeded tests run in CI; longer randomized campaigns run separately with reproducible seeds and retained crash inputs.

### P01 — Envelope validation and dispatch [P0, M]

**Depends on:** J01–J02, T02. **Locations:** proposed `protocol.elisa`, `session.elisa`.

- [x] Validate `jsonrpc`, method, ID, params shape, and request-versus-notification classification before entering a handler.
- [x] Reject duplicate decoded fields consumed by handlers—including escaped-equivalent nested keys—before protocol or document state can mutate (`test/protocol_test.sh`).
- [x] Validate the shape and consumed decoded keys of each initialization workspace folder before mutating lifecycle/root state (`test/protocol_test.sh`).
- [x] Return ParseError, InvalidRequest, MethodNotFound, and InvalidParams in the appropriate cases (`test/protocol_test.sh`).
- [x] Return `InternalError` for analysis-backed requests against an explicitly `Failed` accepted snapshot; preserve ordinary no-document results and source-only methods (`src/main.elisa`, `test/failed_analysis_request_test.sh`).
- [x] Validate signature-help retained spans and return exactly one `InternalError` for a corrupt `Ready` cache; test source-only providers, absent-document behavior, and recovery after a valid edit (`src/features/signature_help.elisa`, `test/failed_analysis_request_test.sh`).
- [x] Standardize remaining recoverable provider/handler failures through a structured outcome instead of serializing replies inside `void` handlers. Distinguish valid no-match/absent-document results from invalid retained-cache data and operational failure. Panics, aborts, and hangs inside `Semantic::check` remain A04 worker-containment concerns.
- [x] Ignore unknown notifications without emitting response objects; log malformed known notifications with a fixed message cap and suppression notice (`test/protocol_test.sh`).
- [x] Distinguish responses to future server-initiated requests from incoming method calls.
- [x] Decide and test top-level array handling according to the supported LSP profile rather than silently accepting generic batches.
- [x] Defer a pending-request table while the server initiates no client requests; ignore unmatched client response messages and give each synchronous client request one response path (`test/protocol_test.sh`).
- [x] Document duplicate request-ID and malformed response behavior: dispatch is synchronous, IDs may be reused after each response, and response-shaped messages have no matching server request and are ignored (`docs/development.md`, `test/protocol_test.sh`).

**Progress (2026-09-14):** Signature help now checks the accepted source and retained signature-index spans with subtraction-safe bounds before reading. An out-of-bounds span in a `Ready` snapshot returns one `InternalError` instead of being hidden as `null`; a temporary-copy fault injection verifies same-process recovery after the next valid edit (`src/features/signature_help.elisa`, `test/failed_analysis_request_test.sh`). This closes one concrete cache-corruption path. Other recoverable provider failures still use handler-specific replies, so the general structured-outcome item remains open.

**Progress (2026-09-15):** All ten text-document providers now return a tag-only `ProviderOutcome`, and their dispatcher arms use the single response emitter: semantic tokens full/range, hover, signature help, definition, references, document highlights, document symbols, folding, and selection. Valid no-match and absent-document shapes remain `null`, `[]`, or `{"data":[]}` as required; retained document-symbol and full-token bodies can still be emitted directly from cached storage. Invalid retained source, index, or feature spans map to one JSON-RPC `InternalError` (`-32603`). The expanded `test/failed_analysis_request_test.sh` injects corruption into every provider path, assigns unique request IDs, asserts exactly one matching error per request, checks Failed-state loop-header hover and absent-document behavior, and verifies recovery after a valid edit. That test passes with an isolated optimized build using the manifest-pinned supported stage0 compiler. The provider-specific semantic-token, hover, signature, navigation, highlight, symbols, folding, and selection suites also pass. `OperationalFailure` remains defined and centrally mapped to `InternalError` for future returned operational failures; no current provider returns it. Panics, aborts, and hangs inside `Semantic::check` remain A04 worker-containment concerns.

**Acceptance:** A method/ID/envelope matrix proves every valid request receives exactly one response, including unknown methods and handler errors, while valid notifications receive none.

**Progress (2026-09-14):** Requests for semantic tokens, signature help, definition, references, document highlights, and document symbols now receive exactly one JSON-RPC `InternalError` when their open document is in `Failed` after a returned-table contract violation. Missing documents still return their established empty/null results; folding and selection remain available from accepted source text, and a later valid edit restores normal semantic results. A narrowly recognized parser-recovery placeholder for `def` followed by newline/EOF remains usable and does not trigger `InternalError`. `test/failed_analysis_request_test.sh` builds a temporary server with a source-triggered failure seam and covers failure, absent-document behavior, source-only providers, duplicate-response detection, and recovery; `test/incomplete_source_test.sh` verifies broken-source providers stay usable. This boundary handles a known returned-snapshot failure only; it does not recover a checker panic or hang.

### P02 — Initialization and shutdown state machine [P0, S]

- [x] Model uninitialized, initializing, running, shutdown-requested, and exited states explicitly; `Initialized` separately records the one allowed client `initialized` notification.
- [x] Handle pre-initialize requests/notifications, duplicate initialization, `initialized`, shutdown, and exit against the official LSP 3.18 lifecycle baseline.
- [x] After shutdown, prevent new normal work while allowing the required termination sequence.
- [x] Return the appropriate explicit-`exit` process status for orderly shutdown versus exit without shutdown; preserve clean EOF as the separately specified transport-level success case.
- [x] Preserve lifecycle consistency on invalid initialize/shutdown parameters. Cancellation notifications are validated and ignored under synchronous dispatch, so no IDs are retained and no asynchronous workers need shutdown handling.

**Acceptance:** State-transition tests cover each method before initialization, during normal use, after shutdown, and across abrupt disconnects. Existing happy-path tests are migrated to the compliant lifecycle.

### P03 — Capability negotiation and configuration surface [P1, M]

The current initialization profile requires exactly one object-valued `InitializeParams.capabilities` field; `{}` is the valid minimal profile. Escaped JSON capability strings are decoded before negotiation. Current support includes position encoding, hover content format, full/range semantic tokens, document-symbol shape/kind filtering, diagnostic related information, completion item-kind, snippets, insert/replace edits, commit characters, label details, bounded completion resolve, definition `linkSupport`, folding, selection ranges, and up to 32 validated workspace roots. Resolve enriches unique function candidates only while their URI/version/generation tag identifies the current ready snapshot; docs and return types remain unavailable. Local rename is advertised only when the client explicitly supports versioned `WorkspaceEdit.documentChanges`. The server currently initiates no client requests; configuration must not assume that `workspace/configuration` can be queried until request/response correlation and timeout behavior exist.

- [x] Parse and store position encodings, hover formats, full/range semantic-token support, diagnostic related-information capability, document-symbol shape/kind filters, folding limits, and validated workspace roots.
- [x] Add completion and workspace-edit capability handling when those providers are implemented; provider-specific negotiation, validation, and gating are covered by the checked sub-items below.
  - [x] Complete the provider-specific completion and workspace-edit negotiation slices listed below: validate client edit features and item kinds, gate rename/prepare by versioned `documentChanges`, and thread negotiated behavior into handlers and tests.
  - [x] Require and validate `workspace.workspaceEdit.documentChanges` before advertising prepare/rename, return null to manually sent unnegotiated rename requests, and retain versioned edits for capable clients (`src/main.elisa`, `test/capabilities_test.sh`, `test/rename_test.sh`). Malformed/duplicate capability shapes fail initialize with `InvalidParams`.
  - [x] Validate `textDocument.completion.completionItemKind.valueSet` and omit each unsupported `CompletionItem.kind`, preserving standard kinds when `valueSet` is absent (`src/main.elisa`, `src/features/completion.elisa`, `test/capabilities_test.sh`, `test/completion_test.sh`).
  - [x] Validate `textDocument.completion.completionItem.snippetSupport` and emit argument snippets only for uniquely retained function signatures when explicitly supported; otherwise retain plain-text edits (`src/main.elisa`, `src/features/completion.elisa`, `test/capabilities_test.sh`, `test/completion_test.sh`).
  - [x] Validate `textDocument.completion.completionItem.insertReplaceSupport` and emit an InsertReplaceEdit whose insert range ends at the cursor and replace range spans the complete token; preserve TextEdit for clients without support (`src/main.elisa`, `src/features/completion.elisa`, `test/capabilities_test.sh`, `test/completion_test.sh`).
  - [x] Validate `textDocument.completion.completionItem.commitCharactersSupport` and emit `(` only for plain function-name insertions without an existing call suffix (`src/main.elisa`, `src/features/completion.elisa`, `test/capabilities_test.sh`, `test/completion_test.sh`).
  - [x] Validate `textDocument.completion.completionItem.labelDetailsSupport` and emit parameter-name details only for one uniquely retained function signature; omit the field for unsupported clients, non-functions, ambiguous signatures, or unavailable metadata (`src/main.elisa`, `src/features/completion.elisa`, `test/capabilities_test.sh`, `test/completion_test.sh`).
  - [x] Implement function-signature completion resolve using bounded `{uri, version, generation}` ownership data; preserve submitted item properties and leave stale, malformed, or unrecognized items unchanged (`src/features/completion.elisa`, `src/json_writer.elisa`, `src/main.elisa`, `test/completion_test.sh`). Documentation, return types, overload selection, and broader semantic metadata remain outside this slice.
- [x] Validate `textDocument.definition.linkSupport` and return `LocationLink[]` with exact origin and target name spans only when requested; minimal clients keep `Location` responses (`src/main.elisa`, `src/features/definition.elisa`, `test/capabilities_test.sh`, `test/definition_test.sh`).
- [x] Advertise standard `serverInfo` name/version from `project.json` and only implemented capabilities; record artifact/compiler provenance in `build/manifest.json` (`test/capabilities_test.sh`).
- [x] Express document sync options explicitly, including open/close and incremental change mode.
- [x] Thread the negotiated capability decisions into handlers so initialization and providers use one session profile.
- [x] Use static registration; no tested need for dynamic registration exists yet.
- [x] Define validated configuration defaults and the settings transport. Use initialize-time data and documented defaults until outbound client requests are implemented; if `workspace/configuration` is needed, add typed request IDs, response validation, timeout, cancellation, and fallback behavior before sending it (`src/main.elisa`, `test/configuration_test.sh`, `docs/feature-manifest.json`).

**Acceptance:** A capability-profile matrix tests minimal clients and richer clients. Disabled features are absent from advertising and optional output fields are emitted only when supported.

**Progress (2026-09-15):** The server now accepts the standard
`workspace/didChangeConfiguration` notification and validates the
namespaced `elisa.analysisTimeoutMs` setting in both initialize-time
`initializationOptions` and later settings updates. Values use the same
100–300,000 ms bounds as the POSIX worker, updates apply atomically at message
boundaries, and the effective value is exposed only through the private stats
probe for diagnostics. Unknown extension settings are ignored; malformed
recognized values leave the prior setting unchanged. Notifications remain
response-free, escaped-equivalent duplicate keys are rejected, and no
`workspace/configuration` request is issued until outbound request
correlation, timeout, cancellation, and fallback behavior are implemented.
`test/configuration_test.sh` covers application, invalid-value atomicity,
duplicate keys, and corrected initialize recovery.

**WorkspaceEdit capability slice (2026-10-01):** The server now requires the
client's `workspace.workspaceEdit.documentChanges: true` before advertising
prepare/rename. It returns null for manually sent rename requests when that
capability is absent, and preserves versioned `TextDocumentEdit` output for
capable clients. Malformed objects, non-boolean values, and duplicate or
escaped-equivalent `documentChanges` keys reject initialization before session
state changes. Completion supports negotiated snippets and text-edit forms,
label details, and bounded signature resolution; optional fields remain
capability-gated. `test/capabilities_test.sh`, `test/rename_test.sh`, and
`test/manifest_test.sh` cover the profiles. The latest-source Darwin/arm64
stage0 build passes strict freshness and the complete canonical suite at
`81/81`; its exact artifact tuple is recorded in §2.4.

**Completion item-kind capability slice (2026-10-01):** Initialize validates
the client's `CompletionItemKind.valueSet` as a unique array of standard
integer kinds. The provider retains its normal kind when accepted and omits
the optional `kind` field when the client rejects it; an empty list omits all
kinds and an absent list preserves the standard default. Tests cover omitted,
empty, accepted, rejected, malformed, out-of-range, fractional, duplicate,
and escaped-equivalent duplicate values. Snippet and edit-form capabilities
remain open. The latest stage0 artifact passes strict build freshness and the
complete canonical suite (`81/81`) on the exact compiler source fingerprint
`2a069ae9c7eaf694f838e74d5c8351ab2910a12d4f7b850c4a63c56f32e169e0` and LSP
input `1508d5d51ee80484d5c3f598233718b728eb466e08e06348fa57d1a5dea0cd3e`;
the artifact tuple is recorded in §2.4.

## 7. M2 — Documents, Unicode, and source coordinates

### D01 — Explicit versioned document lifecycle [P0, M]

**Depends on:** P01, J02. **Locations:** extract `LspDocument` and document helpers into `src/documents.elisa`.

- [x] Separate URI indexing, open-state metadata, source spans, and feature caches into dedicated records nested under `LspDocument` (`DocumentUriIndex`, `DocumentLifecycle`, `DocumentSource`, and `DocumentDerivedCaches` in `src/documents.elisa`).
- [x] Store the client version and a monotonic internal generation; versions need not increase by exactly one.
- [x] Validate didOpen metadata (one URI, nonempty languageId, version, and text) before mutating document state.
- [x] Add a direct regression for duplicate didOpen on an already-open URI and document its new-generation policy; the handler starts a new generation (`test/documents_test.sh`).
- [x] Reject stale/equal-version changes and transactionally ignore malformed notifications without mutating text (`test/documents_test.sh`, `test/incremental_sync_test.sh`).
- [x] Accept source into the document store before deriving analysis. Mark `Pending`, transition malformed normal-return frontend snapshots to `Failed`, clear every derived cache, and never serve stale results for the accepted version.
  - Progress (2026-09-14): `check_and_publish` commits accepted text/version first, clears derived cache lengths, marks `Pending`, and sets `Ready` only after replacing every derived cache. The A01 validator now detects structurally invalid tables and takes the fail-closed `Failed` path with empty diagnostics and bounded logging. Providers decline non-Ready semantic snapshots. A panic or hang inside `Semantic::check` remains outside this in-process boundary. Regression coverage includes `test/analysis_cache_test.sh` and the malformed-table contract fixture.
- [x] Handle empty documents and empty final lines without indexing element zero of an empty allocation (`test/documents_test.sh`, `test/positions_test.sh`).
- [x] On close, clear open-file diagnostics under the initial open-files policy, invalidate provider caches, and reclaim source/analysis storage (`test/documents_test.sh`, `test/storage_reclaim_test.sh`).
- [x] Add explicit `didSave`/`willSave` lifecycle fixtures and document their policy. They are currently unhandled; open-buffer text remains authoritative, and disk-backed indexing must later establish save/watch invalidation before relying on persisted files.
- [x] On reopen, create a new generation so old work cannot publish into the new document lifetime.
- [x] Define unknown-URI behavior for current providers: empty tokens/symbols/folds, null hover/definition, and explicit no-op for unknown sync notifications. Edit targets are not yet implemented.
- [x] Centralize lifecycle transitions in document-store operations (`open`, accepted change, `Pending`/`Ready`/`Failed`, close, and slot reuse) so dispatch code cannot update version, generation, open state, or job identity independently (`src/documents.elisa`).
- [x] Give provider handlers a read-only snapshot view and keep source/cache-span writes behind document operations; document which close, eviction, compaction, and worker-completion transitions invalidate each view (`DocumentSnapshotView` in `src/documents.elisa`; providers receive no mutable document table).

**Acceptance:** Test A/B isolation, repeated JSON URI encodings, empty source, same-version retry, stale version, version gaps, unknown changes, duplicate opens, `didSave`/`willSave` policy, close with pending work, and close/reopen with reused versions. Lifecycle helpers must preserve the same matrix while making illegal generation/version/cache transitions unavailable to provider code.

**Progress (2026-09-15):** The save policy is now explicit: no save capability is advertised, unexpected `didSave` and `willSave` notifications are ignored, and the optional `didSave.text` field never replaces the open-buffer overlay or triggers analysis. `test/documents_test.sh` sends both notifications with save text that differs from the open document, checks symbols/tokens and diagnostics remain unchanged, and proves a subsequent valid `didChange` still updates the snapshot. `docs/development.md` and `docs/feature-manifest.json` record that disk-backed indexing must define save and watcher invalidation before it reads persisted files.

**Progress (2026-09-15):** The `LspDocument` type and URI registry, hash-chain, source-buffer, and line-index helpers have been mechanically moved into `src/documents.elisa`, included into the same translation unit from `main.elisa`. This establishes a buildable file boundary while preserving the current record layout and helper behavior. A post-move audit found close still unlinks before slot reuse, hash equality still compares URI bytes after a match, reuse resets the full cache/index state and bumps generation, and line-index compaction/reclamation paths remain intact. The new boundary does not yet separate URI indexing, open metadata, source admission/reclamation, or feature-cache ownership: cache spans remain on `LspDocument`, and admission, close orchestration, and flat-store reclamation still live in `main.elisa`. Keep the first checkbox open until those responsibilities have explicit interfaces and tests. `test/uri_collision_test.sh` now targets the moved hash helper and passes; the pinned analysis-worker, frontend-contract, and collision-chain isolated builds also pass against the fresh stage0 artifact. Provider-only semantic-token, contextual-token, range, hover, signature, navigation, highlight, symbol, folding, selection, document, and cache suites pass against the same artifact; manifest and freshness checks pass. A later all-tests run reached the same collision and synchronization checks but was terminated by the host during another isolated compiler rebuild, so do not label that interrupted run as a 60/60 result.

**Ownership-record progress (2026-09-30):** URI bytes/hash/collision links, open/version/generation/analysis/diagnostic state, source reservation spans, and semantic-token/symbol/hover/signature/line-index cache spans now live in four nested records on `LspDocument`. The records contain offsets and capacities into the existing flat stores rather than owning nested dynamic arrays, so compaction continues to update stable scalar spans. Provider handlers now take immutable `DocumentSnapshotView` values and cannot write through the view; dispatch does not pass them the mutable document table. Source, cache, line-index, eviction, and compaction writes are routed through document-store routines. View spans last only for the current message and are invalidated by accepted source snapshots, worker completion, close, cache eviction, and storage compaction. The latest Darwin/arm64 release build passes strict manifest freshness on LSP input hash `6714bab000b4dc038620728b49c85b0df6439b9e5a150b0caa8d0c1a777baccb`. All 11 provider endpoint tests plus lifecycle, cache reuse, reclamation, and aggregate eviction tests pass on the exact artifact; the isolated failed-analysis/cache-corruption test also passes after its fixture was updated for read-only views. The 78/78 canonical result recorded above belongs to its own earlier LSP input hash and has not been repeated for this artifact. This closes the remaining D01 ownership and lifecycle boundaries.

### D02 — Correct full synchronization, then incremental synchronization [P0/P1, M]

**Depends on:** D01; incremental mode also depends on U01–U02.

- [x] Validate every change entry and apply full replacements in notification order; do not silently use only entry zero.
- [x] Support ranged changes in the advertised incremental mode; reject malformed ranges rather than interpreting fragments as whole documents.
- [x] Convert each range against the text produced by the preceding change in the same notification.
- [x] Apply a change list transactionally: validate on a temporary new snapshot and commit only if the full list is consistent.
- [x] Support mixed full-replacement and ranged events in one notification.
- [x] Treat `rangeLength` as optional compatibility information; never use it instead of the actual range. Mismatch or rangeLength-without-range rejects the notification transactionally, using negotiated UTF-8/UTF-16 units (`test/sync_test.sh`).
- [x] Preserve exact source bytes, line endings, and trailing newline state (`test/incremental_sync_test.sh`).
- [x] Use a simple owned string/byte buffer first. Adopt a rope or piece table only if measured editing workloads justify its implementation and lifetime complexity.
- [x] Advertise incremental sync only after the reference-model tests pass (`test/incremental_sync_test.sh`).

**Acceptance:** Random edit sequences match a simple reference implementation, including multi-change notifications, insert/delete/replace, full reset, CRLF edits, supplementary characters, and edits at EOF.

### D03 — URI and filesystem identity [P1, M]

- [x] Parse `file:` URIs with a tested implementation; account for authorities, percent escapes, spaces, non-ASCII paths, and platform-specific path syntax (`src/uri.elisa:Uri::file_uri_to_path`, `test/uri_path_test.sh`).
- [x] Add a pure component parser (`scheme`, `authority`, `path`, `query`, `fragment`) and a separate lexical lookup-key conversion; malformed percent escapes are reported but retained literally for compatibility, and non-file schemes remain local overlays (`src/uri.elisa`, `test/uri_test.sh`).
- [x] Retain the incoming URI spelling for responses while normalizing only what is safe for internal identity.
- [x] Specify case sensitivity and symlink alias policy using filesystem behavior; the lexical overlay never aliases on case or symlink spelling, while a future resolver records per-volume `sensitive`/`insensitive`/`unknown` behavior and only attaches proven physical identity (`docs/workspace-and-configuration.md`, `docs/feature-manifest.json`, `test/filesystem_identity_test.sh`).
- [x] Support in-memory/untitled documents without pretending they have a disk path; define how their project context is chosen.
- [x] Refuse unsupported remote schemes or handle them through an explicit virtual-file provider; never silently fetch them as network resources.
- [x] Keep source identity separate from compiler display paths and `#line` remapping (`src/diagnostics.elisa:tokenize_frontend_source`, `test/source_identity_test.sh`).

**Acceptance:** URI/path round trips and alias tests cover supported platforms. Equivalent JSON escaping finds the same document; semantically different URIs cannot alias accidentally.

**Progress (2026-09-15):** `Uri::file_uri_to_path` now provides a pure OS-path conversion boundary in addition to the existing compatibility lookup key. It strictly validates and percent-decodes file-URI authority/path components, preserves UTF-8 and spaces, rejects malformed escapes/NUL/query/fragment metadata and relative paths, refuses remote authorities on POSIX, and handles Windows `/C:/`, `/C|/`, `C:/`, `file://C:/`, and UNC host forms with backslash separators. The target grammar is explicit so both platforms are tested on one host. Conversion deliberately leaves dot segments, case, symlink aliases, and filesystem existence untouched. `test/filesystem_identity_test.sh` now measures case sensitivity and symlink identity in a private temporary directory; the documented resolver policy uses that host/volume evidence only for a separate physical identity, fails closed when it is unknown, and never changes the lexical URI/edit key. The LSP frontend also uses the expanded-unit compiler entry point with stable display name `<elisa-lsp>`, and `test/source_identity_test.sh` verifies that compiler `#line` path/number metadata cannot move diagnostics, semantic tokens, symbols, or hover outside physical snapshot coordinates.

**Progress boundary:** The standalone server still does not read the filesystem or resolve physical aliases; W02 must implement the resolver and its file identity APIs before unopened dependencies can participate. The D03 policy boundary and source/display separation are now explicit and independently tested, while project discovery, physical-path normalization, and cross-file aliasing remain W02 work.

### D04 — Storage ownership and reclamation [P0, M]

- [x] Bound retained document storage with an offset-based flat store, explicit admission budgets, and measured dead-space compaction compatible with Elisa's region lifetimes. Keep active backing capacity as an observed high-water mark, separate from logical live bytes and process RSS (`src/documents.elisa:storage_reclaim`, `test/storage_reclaim_test.sh`, `test/bench.py`).
- [x] Release per-message parse, body, and response scratch on every helper return using the function-call allocation lifetime; keep negotiated semantic-token containers in the session region (`src/main.elisa`, RSS soak evidence below).
- [x] Keep retained document snapshots independent of pointers into the growable metadata array; exercise live array growth, cached-provider reads, and slot reuse (`test/storage_metadata_move_test.sh`).
- [x] Keep collision-safe URI equality; exercise equal-hash traversal, URI comparison, chain unlink, and slot reuse in a temporary constant-hash server build (`test/uri_collision_test.sh`), without a runtime test hook in the shipped server.
- [x] Enforce a configurable aggregate budget for accepted open-document source bytes, and reject any source over the per-document analysis input limit before mutating document state. Preflight `didOpen` before slot/generation allocation and `didChange` after applying edits to scratch but before commit; bound rejection logs without recording URI or source text (`ELISA_LSP_MAX_OPEN_SOURCE_BYTES`, `test/open_source_budget_test.sh`).
- [x] Bound concurrent open-document records and canonical URI bytes before `didOpen` changes slots or the URI index; closed-document slot high-water is therefore bounded by the configured concurrent-open cap (`ELISA_LSP_MAX_OPEN_DOCUMENTS`, `ELISA_LSP_MAX_OPEN_URI_BYTES`, `test/open_document_metadata_budget_test.sh`).
- [x] Bound aggregate derived semantic results by retained reservation cost; the current synchronous server retains one current snapshot per open document and does not retain historical snapshots across requests, while the worker packet cap remains a separate per-snapshot limit (`ELISA_LSP_MAX_DERIVED_CACHE_BYTES`, `test/cache_eviction_test.sh`).
- [x] Bound unresolved pending analyses through the current synchronous dispatch model: one child job is awaited with a hard deadline and no analysis queue or retained request-snapshot queue exists. Preserve this invariant until Q01 scheduling is implemented.
- [x] Define whole-snapshot least-recently-used eviction by retained reservation cost; the synchronous dispatch boundary has no in-flight retained views, and a future scheduler must add explicit snapshot pins before evicting shared request snapshots.
- [x] Instrument current snapshot-state counts, per-document and aggregate logical cache cost, and dead flat-store bytes (`$/elisa/stats`, `test/storage_reclaim_test.sh`, `test/bench.py`).
- [x] Expose active flat-storage byte capacity and document-slot capacity through private stats and the soak benchmark; label them as partial darray estimates, not total arena/RSS.
- [x] Measure process RSS beyond active darray capacity with the B04 benchmark; record the platform, source, unit, and counters alongside sparse live samples (`test/bench.py`, `bench/storage-rss-2026-09-14.json`).

**Acceptance:** Thousands of open/change/close cycles and alternating growth/shrink edits reach a stable retained-memory band after warmup. Stress tests exercise historical region/arena failure patterns in debug and optimized builds.

**Compaction strategy decision (2026-09-29):** Keep one offset-addressed byte store for URIs, accepted source, and retained provider results. Rebuild its live spans at message boundaries after `didOpen`, `didChange`, and `didClose` when dead storage crosses the 2x/64 KiB trigger; request-local compaction scratch follows the message-call lifetime. Aggregate source bytes, open-document count, canonical URI bytes, and retained derived-cache cost have separate hard admission limits. The byte-array's active capacity may retain the session high-water mark after logical compaction, so stats and benchmarks report it separately and do not present it as reclaimed RSS. This keeps snapshot spans stable across metadata-array growth and avoids introducing nested per-document arrays whose backing lifetimes would outlive their request.

**Alternating-edit verification (2026-09-29):** `test/storage_reclaim_test.sh` now alternates a 104,417-byte source and a 30-byte source 24 times on one open URI, checks live/dead accounting after every accepted change, and verifies the active reservation does not grow beyond the capacity warmed by the preceding escalation phase. The complete storage gate passed against the current manifest-frozen compiler snapshot in both optimized release and debug `-O0` builds; each run also covered 120 escalating grow/close cycles, 2,000 URI churn cycles, and provider reads across compaction/rebasing. The alternating phase observed 119,111 logical storage bytes for the large snapshot and 361 bytes for the small one, with a stable 558,912-byte active backing high-water mark. This verifies bounded logical dead space and an active-capacity plateau for this workload; process RSS remains a separate sampled metric in the B04 benchmark and is not inferred from `storage_capacity`.

**Progress (2026-09-14):** The implementation reuses freed document slots, unlinks closed URIs from collision chains, compacts URI/source/provider-cache bytes between messages after a 2×/64 KiB trigger, rebuilds dictionary tombstones, and reports live versus stored bytes, active darray capacities, and slot/index counters. `test/storage_reclaim_test.sh` samples capacity through growth, compaction, close, and URI churn; the benchmark reports final/peak capacity counters beside logical counts. The soak confirmed logical storage returns to 0 bytes while the active byte darray still reports 558,912 bytes of capacity after large-document growth. This is direct evidence that logical compaction does not shrink the backing array. The capacity fields measure only each current darray reservation, not abandoned arena buffers or total RSS. `test/storage_metadata_move_test.sh` keeps distinct documents open until stats confirm the document-slot darray grew from 8 to 16, then checks cached document symbols, hover, selection ranges, and a freed-slot reopen while older and newer documents remain live. This exercises existing snapshots across metadata relocation; handlers and the analysis worker use spans during a message and do not retain document-array pointers between messages. The release canonical suite passed `pass=55 fail=0` before the region-lifetime follow-up, including storage-capacity reclamation, metadata relocation, collision-chain behavior, worker-fault containment, and the updated frontend contract. The benchmark samples current process RSS in bytes with a direct OS interface, pairs readings with logical storage stats, and returns unavailable values explicitly. An earlier pre-fix 200-cycle Darwin/arm64 release capture ran one-function open/change/close cycles and sampled RSS monotonically from 1,900,544 bytes after warmup to 5,111,808 bytes at cycle 200 (+3,211,264 bytes), while `storage_capacity` stayed at 131,072 bytes and final state had 3,101 stored bytes, 0 live bytes, and no open documents. Those baseline measurements are retained here; the same artifact path was overwritten by the follow-up capture. This showed process-memory growth outside the active flat-store counters but did not assign pages to a specific allocator. `test/uri_collision_test.sh` builds an isolated temporary server whose URI hash is constant, then verifies unequal-URI lookup, head/middle/tail unlink, slot reuse, reinsertion, and unknown-URI misses over the protocol. Retained-cost/recency eviction and long-lived document ownership remain incomplete.

**Per-message lifetime follow-up (2026-09-14):** One complete frame now runs inside `process_next_message`; its function-local parse tree, body, response builders, and provider scratch are released on every normal or early return. A nested child `region` was not used because the stage0 runtime trapped while traversing capability JSON in that region. The release benchmark ran 1,000 open/change/close cycles in one server process: after-warmup sampled RSS was 1,884,160 bytes, peak sampled RSS was also 1,884,160 bytes, and final RSS was 1,818,624 bytes (-65,536 bytes from warmup). Final stats reported 0 live bytes, 0 open documents, 3,101 stored bytes, and 131,072 bytes of active storage capacity. The debug benchmark also ran 1,000 cycles: after-warmup and peak sampled RSS were 1,998,848 bytes, final RSS was 1,785,856 bytes (-212,992 bytes), and the same logical final counts held. The release and debug artifacts are `bench/storage-rss-2026-09-14.json` and `bench/storage-rss-2026-09-14-debug.json`; neither sampled RSS series grew with cycle count. These are single Darwin/arm64 samples and support bounded per-message scratch for this workload, while broader concurrent-project and large-document lifetime tests remain open. Fresh debug validation passed the expanded sync regression and `test/storage_reclaim_test.sh`.

**Open-source admission follow-up (2026-09-14):** `ELISA_LSP_MAX_OPEN_SOURCE_BYTES` defaults to 256 MiB and accepts 1 byte through 1 GiB. It counts UTF-8 source bytes across open documents, excluding each stored NUL terminator; the per-document worker-source limit remains 64 MiB. Both limits are checked before an open can allocate/reuse a slot or advance a duplicate-open generation, and before a change can replace source, version, or derived caches. Rejections are no-ops and produce at most nine generic stderr lines per process. The budget intentionally excludes URI/index metadata and derived caches, which remain separate D04 memory bounds. `test/open_source_budget_test.sh` covers exact-limit admission, over-limit open/change, capacity/index state preservation, version preservation, close/reopen reuse, and source-backed symbol access. A fresh pinned stage0 release build and manifest-freshness check passed; the transport-limit C test, open-source budget test, duplicate-open lifecycle test, mixed incremental-sync test, and analysis-worker fault-containment test all passed. The worker test independently verified same-process recovery after malformed packets for all five cache payload families and the three-digit signature-offset case. A complete canonical suite has not been rerun for this admission slice. The most recent pinned full-suite run before this change had `pass=55 fail=1`; its only failure was a temporary URI-collision server timing out before initialization, while URI-collision assertions passed in earlier full runs. The earlier `pass=56 fail=0` result is also preserved in the per-message validation record above.

**Open-document metadata admission follow-up (2026-09-14):** Empty documents previously bypassed the source-byte limit, while concurrent URI keys and the document slot vector had no admission cap. `ELISA_LSP_MAX_OPEN_DOCUMENTS` now defaults to 1,024 (hard maximum 16,384), and `ELISA_LSP_MAX_OPEN_URI_BYTES` defaults to 8 MiB (hard maximum 64 MiB). `didOpen` counts an existing duplicate lifetime as its replacement and checks both limits before slot reuse/allocation or URI-index insertion. Stats report open canonical-URI bytes and both configured limits. A 32-case unique-URI churn test confirms the slot vector and URI-index capacities plateau after peak concurrency; exact-limit admission, document-count rejection, URI-byte rejection, duplicate-open, slot reuse, and empty-source behavior pass. This LSP build used the latest clean compiler checkout at `fd2cb3cff470319500db362e5fce2833cbe300de` as its frontend source tree, with the stage0 backend required by this target. The repository-wide run started against the preceding source state was interrupted before its final checks and is not a passing full-suite result. Aggregate derived-cache memory and high-water backing-array shrinkage remain open.

**Snapshot accounting follow-up (2026-09-14):** `$/elisa/stats` now separates open URI bytes, source bytes (excluding one stored NUL per open source), logical derived-cache bytes, maximum per-document cache bytes, and dead bytes in the current flat store. It also exposes open/pending/ready/failed current-snapshot counts. The storage soak and benchmark parser verify `storage_bytes = live_bytes + dead_storage_bytes` and `live_bytes = open_uri_bytes + open_source_bytes + derived_cache_bytes + open_snapshots`, with per-document cache cost no larger than aggregate cache cost. These are logical payload counts; they do not account for reservation slack, allocator-retained pages, cumulative snapshot retirements, or snapshots held by future concurrent requests. Aggregate cache eviction and backing-array shrinkage remain open.

**Post-lifetime validation (2026-09-14):** The pinned-compiler release canonical suite passed `pass=56 fail=0`, including storage reclamation, metadata relocation, URI collisions, worker fault containment, strict sync boundaries, and the frontend contract. A subsequent fresh release build plus the focused document-symbol regression also passed.

**Aggregate derived-cache follow-up (2026-09-15):** `ELISA_LSP_MAX_DERIVED_CACHE_BYTES` defaults to 64 MiB (1 KiB–1 GiB accepted) and budgets retained cache reservation capacities for semantic tokens, document symbols, hover summaries, and signature help. After a validated worker result commits, the server assigns a monotonic access stamp and evicts the least recently used complete document snapshot until the aggregate retained cost is within the limit. Eviction clears every derived payload for that document, marks its accepted source `Pending`, increments the private stats counter, and leaves authoritative source/version state intact; the next edit or reopen rebuilds the derived snapshot. Provider requests touch ready snapshots regardless of logging level. `$/elisa/stats` reports live bytes, retained bytes, configured limit, policy, and eviction count. `test/cache_eviction_test.sh` exercises the low-budget path and close cleanup. The synchronous implementation has no request pins; scheduler work must add reference tracking before reusing this policy for concurrent requests.

### U01 — Shared line index and position conversion [P0, M]

**Location:** proposed `src/positions.elisa`.

The current slice builds one retained line-start sidecar span for every accepted snapshot within the session budget. Worker-side semantic-token, diagnostic, document-symbol, and hover-summary builders share that span, as do loop-header/general hover, `foldingRange`, `selectionRange`, and `signatureHelp` requests. Definition and reference responses consume exact positions serialized from the same worker snapshot. Incremental edit application retains its bounded source scan. The coordinate probe exposed and fixed lone-CR handling and malformed UTF-8 scalar counting. See the before/after evidence under B04.

- [x] Define half-open byte offsets as the internal source coordinate system.
- [x] Build one shared per-snapshot line-start index, preserving LF, CRLF, final-empty-line behavior, and lone CR as content unless immediately before LF.
- [x] Retain and reuse the line-start index on each document snapshot for repeated loop-header/general hover, `foldingRange`, `selectionRange`, and `signatureHelp` requests; keep scalar span offsets in each document and compact/rebase the flat sidecar at message boundaries.
- [x] Thread the retained index through semantic tokens, diagnostics, hover summaries, document symbols, definition, and request-time position providers; keep transient edit application scans only where profiling supports them.
- [x] Bound retained offsets to 1,048,576 `usize` entries per session, with provider-local fallback for snapshots that exceed the budget.
- [x] Implement byte offset ↔ line/character conversion for UTF-16 as the initial default and UTF-8 when negotiated; add UTF-32 only if supported and tested.
- [x] Count encoding units, not grapheme clusters or display columns. Tabs are not expanded to editor tab stops.
- [x] Avoid splitting UTF-8 code points or UTF-16 surrogate pairs. Define rejection or boundary handling separately for invalid incoming edits and permissive query positions.
- [x] Implement specification-compatible out-of-range handling per field/method, including line-end clamping where required; do not apply one blanket rule to every position. The tested method policies are recorded below.
- [x] Use binary search over line starts when mapping exact byte offsets for definition locations.
- [ ] Add optional per-line non-ASCII checkpoints for repeated column conversions if profiling justifies them.
- [x] Validate frontend offsets and distinguish absent/default position information from valid offset zero (`frontend_offsets_valid` and the default, reversed, out-of-source, exact-EOF, and `[0,1)` cases in `test/frontend_contract_test.sh`; `diagnostic_json` uses that shared predicate and still requires agreement with line/column data).

**Acceptance:** Exhaustive boundary checks for small Unicode strings and randomized round trips cover ASCII, `æøå`, Greek/lambda symbols, CJK, combining marks, emoji, tabs, CRLF, and empty files.

`test/positions_test.sh` exhausts 9,596 deduplicated short byte strings over that Unicode basis and malformed/truncated UTF-8 classes, then adds 64 deterministic longer samples (up to 20 Unicode or malformed-byte atoms). Both groups check scanning and indexed helpers against an independent decoder and every short span. Provider-level boundary behavior is separately tested per input method below; the shared helper tests alone are not treated as proof of protocol behavior.

The same 9,596 cases also exercise invalid lines `-1`, `line_count`, and `line_count + 1` across scan/indexed unit lengths and byte-column/unit-column conversions; all return the documented empty/end behavior without reading outside the source. The shared `lsp_position_valid` / `lsp_range_valid` gates reject malformed, negative, fractional, and out-of-domain coordinate values before method dispatch. Provider-specific out-of-document behavior is recorded in the matrix below: valid oversized characters follow Position's line-end clamp where relevant; line numbers past the document receive each method's defined empty/null behavior, while selectionRange declines the whole request to preserve containment. Ranged edits reject out-of-document lines transactionally while clamping overlong characters on valid lines. Semantic-token ranges clip ordered nonnegative input to document tokens; tests cover both a range ending beyond EOF and a zero-width range starting beyond EOF. `test/general_hover_test.sh` also checks omitted, malformed, negative, fractional, and duplicate position fields return InvalidParams, while a well-formed out-of-document line returns `null`. `test/frontend_contract_test.sh` directly proves byte offset zero is valid for `[0,1)`, the all-zero default and reversed/out-of-source spans are rejected, and an end exactly at source length remains valid; the diagnostic renderer uses the tested predicate and retains line/column fallback on mismatch.

**Provider method matrix (2026-09-14):** `didChange.contentChanges[].range` rejects malformed/reversed edits without mutating the accepted snapshot, rejects either endpoint on a line past EOF, clamps an oversized character on a valid line, and rejects endpoints inside an encoded scalar (`test/sync_test.sh`). `semanticTokens/range.range` returns InvalidParams for malformed, negative, or reversed coordinates, includes the full in-document token set when an ordered range extends past EOF, and returns empty data when its start is past EOF (`test/semantic_range_test.sh`). Point requests use these explicit policies: hover clamps an oversized character on a valid line and returns null past EOF; definition returns null for a past-EOF line or a position that cannot hit a half-open symbol span; references and document highlights return empty arrays in those cases; signature help clamps to line end (including an incomplete call whose active parameter is asserted) and returns null past EOF; selectionRange clamps a valid-line character and returns null for the whole request if any line is past EOF, keeping every returned chain valid and containing its input. Evidence is in `test/general_hover_test.sh`, `test/definition_test.sh`, `test/references_test.sh`, `test/document_highlight_test.sh`, `test/signature_help_test.sh`, and `test/selection_test.sh`. `semanticTokens/full`, `documentSymbol`, and `foldingRange` accept no input Position/Range; their output spans are validated by their feature tests. Future position-bearing methods must add an explicit row and regression before being advertised.

**Out-of-range edit progress:** Ranged `didChange` rejects a start or end line beyond the current snapshot instead of aliasing it to EOF; `Position.character` beyond a valid line still clamps to that line's end under the LSP 3.18 `Position` contract. Edit endpoints inside a UTF-8 scalar or UTF-16 surrogate pair are rejected rather than rounded; permissive query conversion remains unchanged. `test/sync_test.sh` checks both encodings, invalid starts and ends, a later valid edit, Unicode overlong-column clamping, and storage/live-byte stability after rejected out-of-document edits. The audited method-specific policies and test evidence are listed above; new position-bearing methods still need their own matrix row.

**Selection-range audit (2026-09-14):** The LSP 3.18 `Position` contract specifies that a character beyond a valid line clamps to the line end but gives no fallback for a line beyond the document. `SelectionRange` also requires each result at index `i` to contain the input position at index `i`. `textDocument/selectionRange` returns `null` if any requested line is outside the open document, avoiding a fabricated EOF range; it preserves the required character clamp, returns a three-level zero-width chain for `(0, 0)` in an empty open document, and returns `[]` for an empty positions array. `test/selection_test.sh` covers these cases and mixed valid/out-of-range positions. The other implemented position providers and semantic-token ranges have method-specific line/column boundary assertions listed in the matrix above.

**Retained-index progress (2026-09-14):** `LspDocument` holds scalar start/count/capacity fields into a flat session sidecar. Accepted snapshots rebuild the index before worker fork, including source snapshots whose semantic analysis later fails; close clears the span, and message-boundary compaction rebases live spans. The worker shares the inherited span across semantic-token normalization, diagnostics, document symbols, and exact hover-definition coordinates. Request-time loop-header/general hover, folding, selection ranges, and signature help also use span-based helpers. If a snapshot cannot reserve a retained span, the worker constructs one local index and shares it across all four artifact builders; one hover request similarly shares its local fallback between loop-header and general-hover lookup. The stored span count is capped at 1,048,576 `usize` entries; worker fallback count is returned in the version-2 worker packet, while request-time handlers report their own local fallback. Private stats distinguish active entries, stored entries, darray capacity, retained builds, and fallback builds. `test/analysis_cache_test.sh` verifies cached-provider stability, shifted positions after edits, one worker fallback just above the cap, one shared over-budget hover fallback, and return to the retained path after replacement; `test/storage_reclaim_test.sh` forces sidecar rebase during URI churn and checks close reclamation. `test/positions_test.sh` compares all span helpers with indexed helpers across the exhaustive coordinate set. `test/frontend_contract_test.sh` now covers the optional physical-offset bounds and valid-zero distinction. Incremental edit scans and non-ASCII checkpoints pending performance evidence remain open; the provider boundary matrix is audited above.

### U02 — Route every provider through one coordinate API [P0, M]

- [x] Convert lexer byte columns and spans through the shared `Positions` API before semantic-token serialization.
- [x] Replace hover's independent line scanning with indexed `Positions` lookup for each provider operation.
- [x] Map diagnostic spans and ranged edits through the shared `Positions` coordinate API; the providers use purpose-specific helpers within that API.
- [ ] Require future completion, navigation, references, rename, folding, and formatting providers to use the same range helpers.
- [x] Add opt-in debug assertions that outgoing ranges are ordered, in the requested snapshot, and valid for the negotiated encoding, including nested symbol/selection ranges, folding endpoints, URI identity, and semantic-token bounds (`ELISA_LSP_VALIDATE_RANGES`, `src/main.elisa`, `test/provider_range_validation_test.sh`).

**Acceptance:** The same marked source span is reported identically by hover, diagnostics, highlights, navigation, and text edits under each supported encoding.

**Outgoing-validation progress (2026-09-15):** An opt-in response-boundary walk now validates all current provider payloads against the still-open document snapshot. It rejects malformed or out-of-bounds UTF-8/UTF-16 positions, invalid folding endpoints, wrong same-document URIs, malformed semantic-token arrays, and source-order regressions in direct location/symbol arrays; nested document-symbol, selection, and related-information ranges are checked recursively. Failures return one `InternalError` with bounded stderr logging. `test/provider_range_validation_test.sh` enables `ELISA_LSP_VALIDATE_RANGES=1` across every provider suite; production defaults keep the assertion disabled because it performs a full-source boundary scan.

**Provider-range progress (2026-09-14):** A focused audit found that hierarchical document-symbol selection ranges mixed a byte-based start with a UTF-16 width when UTF-8 positions were negotiated. The fix uses the pinned frontend's exact `Symbol.name_pos` span, verifies that the span is on the declaration line and matches the source bytes, and converts both endpoints using the negotiated encoding. `Symbol.offset` is only the declaration-line start and must not be treated as the identifier start. ASCII and UTF-8 `π` regressions assert exact name ranges, and the rebuilt release server passes `test/document_symbols_test.sh`. Symbols without an exact frontend name span still use the line-extent fallback, so F02's full exact-name coverage and U02's complete provider/debug-validation work remain open.

### U03 — Source maps and generated syntax [P1, L]

**Depends on:** A01. **Compiler coordination required.**

- [ ] Inventory physical token positions, AST positions, display-line remapping, interpolation subspans, and desugared nodes in the compiler.
- [ ] Expose physical source spans independently from user-facing compiler diagnostic locations.
- [ ] Preserve origin ranges for includes, compile-time splices, generated declarations, and lowered loop/match forms when those constructs exist in the supported frontend.
- [ ] Mark synthesized positions as synthetic; map to a useful origin or omit unsafe edits instead of inventing a writable location.
- [ ] Define source-map ambiguity behavior for navigation and refactoring.

**Acceptance:** `#line` or equivalent remapping cannot produce out-of-document LSP ranges; generated symbols navigate to an explainable origin and cannot trigger edits at fabricated offsets.

## 8. M3 — Compiler tooling and reusable analysis

### A01 — Stable frontend tooling adapter [P0, L]

**Locations:** `src/frontend_adapter.elisa`; corresponding compiler tooling API.

- [x] Inventory APIs already available in the adjacent frontend before proposing replacements: `Diagnostic.pos`, `Symbol.offset`, structural type IDs, parameter metadata, effect metadata, and occurrence side tables are present to varying degrees.
- [x] Define a versioned adapter contract for lex/parse/analyze/query operations and ownership of every returned buffer/span (`docs/frontend-adapter-contract.md`, current contract v10, exercised by `test/frontend_contract_test.sh`).
- [x] Encapsulate direct access to `ref_kind` numeric values and parallel compiler arrays behind named tooling concepts.
- [x] Return recoverable syntax results, diagnostics, symbols, occurrences, token/comment spans, and analysis completeness in a coherent snapshot result (`LspFrontendAnalysisSnapshot`; job-local owners remain alive through provider projection).
- [x] Keep compiler wording/severity authoritative. Language rules must not be independently re-created in feature handlers (`src/diagnostics.elisa` calls `Semantic::diagnostic_message` / `diagnostic_severity`; `test/diagnostics_test.sh` verifies compiler-authored syntax and semantic wording/severity).
- [x] Introduce a compatibility check or compile-time fixture that fails when the required frontend surface changes (`test/frontend_contract_test.sh`, current contract version 10).
- [x] Validate normal-return snapshots before provider indexing: occurrence/enum parallel-array lengths, supported occurrence roles, source-backed name spans, and definition-edge targets/spans; malformed tables enter `Failed`, clear derived caches, publish empty current-version diagnostics, and produce bounded stderr reporting. A parser-created empty function-name row is admitted only for a bounded zero-width span matched to an expected-identifier error at newline/EOF; provider name indexes skip the placeholder and navigation edges cannot target it.
- [x] Keep compiler wording and severity authoritative in exported source findings (`Semantic::diagnostic_message` and `Semantic::diagnostic_severity`; `test/diagnostics_test.sh`).
- [x] Establish behavior for incomplete language coverage: compiler diagnostics/recovery remain analysis results; provider-specific unsupported constructs return their documented no-match shape; failed snapshots produce `InternalError` for semantic requests and can recover on a later accepted version (`docs/unsupported-constructs.json`, `test/incomplete_source_test.sh`, `test/failed_analysis_request_test.sh`).

**Acceptance:** Only the adapter depends on unstable compiler storage details. A compiler upgrade either passes contract fixtures or fails with a localized compatibility error.

**Progress (2026-09-14):** Feature providers now read symbol names, categories, lines, declaration-order offsets, arity, and return types through stable adapter accessors; definition edges and module/import/enum ambiguity guards are adapter-owned as well. The adapter rejects mismatched tooling arrays, out-of-range definition targets, and spans outside the accepted snapshot before signature, token, symbol, hover, or diagnostic providers consume them. A source audit found one legitimate parser-recovery row for `def\n`: an empty function name with a zero-width span exactly matching an `ExpectedToken(Ident)` error at newline/EOF. Contract v4 admits only this shape; indexes skip empty names and edges cannot target them. The fixture also proves a malformed edge remains rejected when a syntax error exists. This catches malformed results returned by the embedded frontend, but not a panic, abort, or hang inside `Semantic::check` (see A04).

**Contract v9 and coherent snapshot (2026-09-30; historical):** `docs/frontend-adapter-contract.md` specified ownership and lifetime of source bytes, lexer tokens/comments, parser recovery AST, semantic table/diagnostics, accessor results, table-local declaration IDs, and serialized worker projections across lex/parse/analyze/query boundaries. The v9 build record below remains valid only for its recorded inputs and predates the v10 occurrence-pairing rule.

**Previous v8 build (superseded by v9 below):** Darwin/arm64 release on input `1e5d28a99e82ba02f710843706742eb8bdf9590eb8be983d3b79a6ab1e3b3a7a` passed freshness and all `78/78` tests; that artifact used contract v8 immediately before the declaration-ID assumption was versioned. The current qualified v9 tuple is recorded below after its rebuild.

**Previous qualified v9 build (2026-09-30; superseded):** Darwin/arm64 release `-O2 -fno-builtin -Wl,-v`, built `2026-09-30T05:17:02Z` with compiler revision `54360bf68398b4da8d63b82a3ad2979667798aa2`, compiler source fingerprint `4c48ea7e85d65af62bdfc83f3e351151f1f354d4ef9e735d9ea755751b8fdb98`, and stage0 SHA-256 `8982ace0e827d99ab1ac5539a3bce2a7896d1950fed8ef72d2d2bab6eeebbfd8`. LSP input SHA-256 `7c7d61140b35867ac438d5fb22a38e020455cf7e1292f1bcc10bf63f253232d0`; 577-file include-closure SHA-256 `123e33709ab7ce41569e829e7f9bf18385c14981c26cba85cecc3179175246a1`; object SHA-256 `81b21418be0a2b718f5a59648ec7c87d6d46623adc027cdf89e6c08aee29d0f5`; artifact SHA-256 `8b6f2020cd42a19f9bd72d9df205acaa845f5055aad963a4200b29a583d0ee53`. This historical v9 tuple passed strict freshness and the then-current full canonical suite at `78/78`.

**Historical qualified v11 build after the first completion slice (2026-09-30):** Darwin/arm64 release `-O2 -fno-builtin -Wl,-v`, built `2026-09-30T21:04:47Z` with latest compiler revision `54360bf68398b4da8d63b82a3ad2979667798aa2`, frontend source fingerprint `766f5eadb9518b1c97282e3532e0f300a272e3f61d19356a34ed89e9a1946a5b`, and supported stage0 SHA-256 `ad85e4ac14bff8d2c579f55c297f474fb35929d744a5d911e03bced853c1fe91`. LSP input SHA-256 `cfcf620ac2abadc88d9d6fd6214449419e980e7c9b578a709519ce95c3588dc6`; 578-file include-closure SHA-256 `810bdc109804c4b2944aa42041ef337dd56d254b93bdceac23b5b7eaffdef6ab`; object SHA-256 `c763e03f7deeaa36996096489fa374fe808f8e03e192a03fc4d9df923c04bc54`; executable SHA-256 `eeb4a90ecad0f1cabb6e0deca61d92f3cfb54d7484c746a4711a86444126979f`. The manifest and strict freshness guard bind the release to this exact compiler/include/LSP tuple. `bash test/run_all.sh` passes `80/80`, including cached completion candidates, UTF-8/UTF-16 full-token edits, conservative shadow/context handling, worker containment/recovery, the v11 frontend contract, diagnostic-span inventory, and feature-manifest agreement. This uses the latest frontend source and supported stage0 backend; the newer stage1 optimizer still cannot emit an LSP object, so it remains unqualified.

**Current performance evidence:** `bench/after-adapter-boundary-2026-09-14.json` records three independent 1,000-function/58,780-byte samples on the current toolchain: median round trips were 1.022 s for clean open, 1.768 s for an edit, 4.5 ms for cached tokens, and 649 ms for hover; median process RSS was about 19.3 MB. These are current observations, not a controlled before/after comparison, so they do not isolate the validator/accessor overhead. Profile before replacing the allocation-free linear validator or adapter scans with more complex machinery.

**Worker observation (2026-09-14):** `bench/after-analysis-worker-2026-09-14.json` records three release samples at the same 1,000-function/58,780-byte size: median startup 2.2 ms, clean open 525 ms, edit 299 ms, cached tokens 2.9 ms, and hover 588 ms. The prior artifact records the same stage0 binary hash but a different compiler source hash (`0fd0…` versus `0698…`) and compiler revision metadata, because this build needed a stage0-compatible compiler snapshot. The apparent timing changes therefore cannot be attributed to the process boundary. Rebuild an in-process comparison from an identical compiler snapshot before using these observations to choose persistent-worker or cooperative-recovery architecture.

**Incomplete-coverage contract (2026-09-29):** Compiler parse/check findings and recoverable syntax remain normal analysis snapshots with the compiler's diagnostics; independently safe providers can still answer, and a later valid version replaces the recovered snapshot. Constructs that parse successfully but exceed a provider's identity/workspace coverage return that provider's documented `null` or `[]` result and are listed separately from compiler-rejected syntax in `docs/unsupported-constructs.json`; the LSP does not invent a compiler diagnostic. A worker, snapshot-contract, or frontend failure instead clears derived caches, marks the snapshot `Failed`, and produces JSON-RPC `InternalError` for analysis-backed requests. `test/incomplete_source_test.sh` checks continued service and recovery on malformed edits, `test/unsupported_constructs_test.sh` checks the compiler/provider boundary, and `test/failed_analysis_request_test.sh` verifies the error response and later recovery. This contract separates behavior and failure handling; it does not claim feature support for entries still marked unsupported or partial.

**Latest-frontend tooling inventory (2026-09-30; source fingerprint `766f5ead…`):** `Diagnostic.pos` may carry a full `Ast::Pos`, while compiler wording/severity remain authoritative and some diagnostic producers still leave default positions. `Symbol` exposes a table-local `DeclId`, kind, declaration-order offset, optional exact `name_pos`, return-type name/structural ID, and arity bounds; parameter and effect metadata live in parallel arrays, and structural types/regions use table-local IDs. This compiler snapshot exposes parallel `ref_line`, `ref_name`, `ref_kind`, `ref_binding_ids`, and `ref_pos` rows. Parsed parameter names, local declaration names, identifier reads, assignment targets, and plain `for` binders carry their exact physical `Ast::Pos`; transformed parameter records preserve that position. Generated rows without a source token use the all-zero absent-position sentinel. Contract v11 validates each concrete span against the accepted source and consumes it directly; only sentinel rows use the older conservative line/name candidate correlation. Pattern/refinement binders, complete read/write/access roles, fields and variants as declaration rows, and cross-file provenance still need compiler data or dedicated AST correlation. This inventory describes the exact frontend tree and include closure recorded by the current release manifest, not an older sibling checkout.

### A02 — Exact symbol and occurrence index [P1, XL]

**Depends on:** A01, U01. **Compiler coordination required for missing data.**

- [ ] Assign symbol IDs to declarations across local scopes, modules, fields, parameters, generic/region parameters, enum variants, effects, and aliases.
  - [x] Validate and expose the latest frontend's table-local `DeclId` for every current `Semantic::Symbol` row; assert `id == row_index`, use the named adapter accessor for definition-edge targets, and reject a corrupted row identity (`src/frontend_adapter.elisa`, `test/frontend_contract_test.sh`). This covers only declaration kinds currently represented by `Semantic::Symbol`; fields, enum variants, binders, and other missing rows remain open.
  - [x] Preserve resolver `BindingId` owner/serial identity on parameter/local occurrence rows and expose the components through named adapter queries; the repeated-name shadow fixture proves that a local declaration/read and its parameter initializer remain distinct (`test/frontend_contract_test.sh`, `test/references_test.sh`). This does not assign identities to declaration kinds absent from the compiler's occurrence log.
- [ ] Record exact name-token ranges separately from enclosing declaration/body ranges.
  - [x] Preserve and validate exact `Symbol.name_pos` spans for current named declaration rows (functions/parameters, structs, enums/error sets, consts, aliases, laws, imports/includes, externs/exports, modules, and `using` aliases); document symbols select these spans against source bytes (`test/document_symbols_test.sh`). Fields, enum variants, generic/effect binders, and declarations without semantic rows remain open.
- [x] Replace `(line, name)` lookup with byte-span occurrence lookup. Same-name references on one line must remain distinct.
- [x] For matched parameter/local rows, pair declaration-shaped tokens to the newest unmatched same-role `BindingId` serial before source-order uses; this corrects post-initializer resolver ordering when a local shadows a same-named binding on the same line (`src/frontend_adapter.elisa`, `test/references_test.sh`).
- [ ] Prefer compiler-provided exact source positions for every occurrence row; line/name pairing still cannot prove every pattern, synthesized, interpolation, or unusual traversal occurrence.
- [ ] Include declaration/reference, read/write, mutability, access visibility, and semantic category metadata.
- [ ] Resolve qualified names, UFCS/method targets, overloaded names, aliases, and shadowing using compiler results.
- [ ] Represent unknown or ambiguous targets explicitly; retain candidate sets only where useful to completion/signature help.
- [ ] Build reverse occurrence lists and position lookup indexes once per snapshot, avoiding per-token scans over all symbols.
  - [x] Build the collision-safe exact-byte-position/name lookup used by semantic-token classification once per analysis projection; hash buckets are verified by exact span/name comparisons and the analysis counter asserts one build per accepted snapshot (`src/frontend_adapter.elisa`, `src/semtokens.elisa`, `test/frontend_contract_test.sh`, `test/analysis_cache_test.sh`). A reverse index grouped by resolved declaration target for references/workspace queries remains open.
- [ ] Expose type and callable-signature queries using structured compiler types, including generic substitutions when available.
- [ ] Specify how imported and generated symbols retain ownership and provenance across files.

**Acceptance:** Fixtures with nested shadowing, contextual-keyword identifiers, repeated same-line names, identical field names in different types, aliases, overloads, and enum variants produce distinct correct identities.

**Progress (2026-09-30):** The latest compiler table exposes parameter/local `(line, name, role, BindingId)` facts but not exact source positions for every row. The LSP validates array shape, bounds, spelling, and paired source spans. It now recognizes declaration-shaped candidates in each equal-sized `(line,name)` group, pairs them from right to left with newest same-role BindingIds, and pairs remaining expression reads in resolver order. UTF-8/UTF-16 reference fixtures prove parameter declarations/reads, multiple same-line reads, nested same-named locals, and a shadow initializer that repeats the outer name on the declaration line; `includeDeclaration` is checked both ways. This closes that concrete reordering case, not all row/token correlation: pattern binders, synthesized rows, interpolation, and other traversal permutations still require exact frontend positions or dedicated AST correlation. Complete declaration identity, access/read-write roles, qualified and overloaded resolution, structured types, and cross-file provenance remain open.

**Declaration-range progress (2026-09-29):** The latest compiler source now records exact identifier spans for named struct, enum/error-set, const, alias, law, import/include, extern/export, and module declarations, keyed to each declaration's source offset; semantic symbol rows retain them as `Symbol.name_pos`. Existing function and parameter spans remain intact, and `using` module aliases also retain their source token. Document-symbol output validates the span against source bytes and handles a nested module whose canonical name is qualified but whose source declaration spells only the leaf. `test/document_symbols_test.sh` now uses `alias Num = Num.Num` to prove that an ambiguous same-line spelling still selects the declaration token. This closes exact source-name spans for supported declaration symbol rows; it does not provide IDs/ranges for fields, enum variants, generic/effect binders, or all generated declarations, so broad A02 remains open.

**Declaration-ID validation slice (2026-09-30):** The current compiler assigns each existing `Semantic::Symbol.id` the owning table row as a table-local `DeclId`. The adapter now validates that invariant for every row, exposes it through `symbol_declaration_id`, and uses the named accessor when converting definition edges to row indexes. The contract fixture checks all rows, the out-of-range sentinel, agreement with a resolver-produced edge, and rejection of a corrupted row ID. The exact declaration-ID checkpoint passed strict build freshness and the canonical `78/78` suite recorded for that earlier artifact; the current v11 completion refresh now passes `80/80` (hashes above). This covers only declarations already represented by `Semantic::Symbol`; assigning identities to fields, enum variants, generic/effect binders, and other missing declaration rows remains open.

**Exact occurrence-position progress (2026-09-30):** The latest frontend now records source spans on resolver rows used by LSP providers. `ParamDecl.name_pos` is set by ordinary and law parameter parsing and preserved when parser passes rebuild parameter records. `SymbolTable.ref_pos` is parallel to each resolver occurrence; `record_reference` keeps source-backed spans for identifiers, locals, assignment targets, and `for` binders, and canonicalizes generated zero-width rows to an all-zero sentinel. Contract v11 validates parallel-array shape, exact row line/spelling/source bounds, and the sentinel; the adapter trusts validated compiler spans and keeps conservative candidate pairing only for sentinel rows. `test/frontend_contract_test.sh` verifies exact shadow-fixture positions, bad-span rejection, and array-shape rejection; references, definition, document-highlight, signature-help, semantic-token, and other focused tests pass on the fresh Darwin/arm64 stage0 `-O2` artifact. After auditing `docs/unsupported-constructs.json` against fingerprint `766f5ead…`, the canonical `test/run_all.sh` completed with `pass=78 fail=0`, including the compiler probes and v11 frontend contract. Exact positions substantially reduce A02's resolver/token correlation gap; pattern payload binders, more declaration rows, access/read/write roles, qualified/overloaded resolution, structured types, and cross-file provenance remain open.

### A03 — Owned analysis snapshots and reuse [P0/P1, L]

- [x] Retain source, syntax, symbol information, diagnostics, and token spans under one tested ownership scheme (`LspFrontendAnalysisSnapshot` is a job-local projection while source/token/AST owners stay live through every provider projection; `docs/frontend-adapter-contract.md`, `test/frontend_contract_test.sh`).
  - [x] Keep the `FrontendTokenBatch`, parsed `Ast::File`, and returned `Semantic::SymbolTable` in the same per-snapshot worker scope until signatures, semantic tokens, symbols, hover data, and diagnostics have been projected (`src/main.elisa`). Removed helper returns that let the table outlive function-local parser/token owners (`src/diagnostics.elisa`). `test/analysis_cache_test.sh`, `test/failed_analysis_request_test.sh`, `test/signature_help_test.sh`, `test/document_symbols_test.sh`, and `test/diagnostics_test.sh` pass on the qualified stage0 product. A probe with the newer user-local stage0 analyzer reports no LSP escaping-reference diagnostics after this change; its build still returns 1 with diagnostics in included compiler sources, so it publishes no artifact.
- [x] Reuse the initial full-source token stream for parsing, signature-index construction, and semantic-token classification.
- [x] Reuse lexer comment spans from that same pass now that the compiler exposes both streams through `Lexer::frontend_tokenize_expanded_unit_with_comments` (`src/diagnostics.elisa`, `src/semtokens.elisa`, `test/combined_lexer_test.sh`).
- [ ] Benchmark any adapter fallback that still re-lexes, including comment extraction and f-string expression spans, before changing the compiler interface.
- [ ] Separate syntax-only, semantic, and serialization caches so presentation changes do not rerun semantic checking.
- [ ] Invalidate analysis on relevant source, compiler, project, dependency, or semantic-option changes.
- [ ] Allow immutable snapshots to serve multiple providers without sharing mutable frontend state.
- [x] Introduce cumulative counters for full-source tokenize/parse/check calls, adapter accessors, and semantic-token index builds; the tokenizer counter now covers the shared stream and `test/analysis_cache_test.sh` proves one full-source tokenization per accepted snapshot and no work for cached providers. These are call counts, not timings or compiler-internal operation totals.
- [ ] Keep historical snapshots only while requests or validated token-result histories need them.

**Acceptance:** Repeated hover/tokens/symbol requests on unchanged input do not rerun checking. Cache eviction and document close never leave dangling diagnostic or symbol spans.

**Progress (2026-09-14):** Analysis now tokenizes the complete source once and passes that same token array to parsing, signature-help indexing, and semantic-token classification. The counter is incremented at the shared full-source tokenizer entry point, so `test/analysis_cache_test.sh` detects an extra full-source call instead of merely observing the parser path. At that snapshot the comment-span API and any future interpolation sublexing remained separate work. Same-host 1,000-function before/after samples are in `bench/before-token-stream-reuse-2026-09-14.json` and `bench/after-token-stream-reuse-2026-09-14.json`; they use the same compiler source and stage0 hashes. Median clean-open time was 327 ms before and 497 ms after, edit time 543 ms before and 473 ms after, cached-token time 2.88 ms before and 3.00 ms after, and hover time 615 ms before and 268 ms after. The three samples in each case vary widely, so these wall times do not establish a latency improvement; the verified gain is one fewer full-source tokenization per accepted snapshot. Focused token/cache regressions and the full canonical `pass=54 fail=0` suite pass.

**Combined token/comment pass (2026-09-15):** The compiler lexer now exposes `FrontendTokenBatch`, containing the established expanded-unit token stream plus the comment side channel produced by that same machine pass. `src/diagnostics.elisa` retains both arrays in the accepted analysis job; parsing/checking and all semantic-token classification use the shared token array, while comment merging uses the shared comment array. The LSP contains no call to the legacy comment-only API. `test/combined_lexer_test.sh` compiles and runs a direct stage0 probe that compares token kind, physical position, byte span, suffix metadata, and comment spans against both legacy entry points, including CRLF, quoted `#`, f-string interpolation, and trailing comments. The remaining Q04 work is broader than this win: JSON serialization/copies, f-string sublexing, per-token scans, allocation policy, scheduler overhead, thresholds, and process-boundary cost still require independent evidence.

**Borrowed-analysis lifetime follow-up (2026-09-29; historical artifact):** The analysis worker now owns the source buffer, shared tokens/comments, parsed AST, and semantic table in one lexical scope until every provider projection and the worker packet are complete. This removes the helper boundary where a returned semantic table could carry references into a local AST or token batch. The qualified stage0 build at LSP input hash `36bbea2f91b596f141d0d57d347bad11610e0eb094517a11e4ee8041f188a0de` passed the focused lifecycle/provider tests and build-freshness at that time. Compiler sources and artifact inputs advanced afterward and superseded that checkpoint. The current v12 source/build tuple is recorded in §2.4 and A02 progress above.

### A04 — Incomplete syntax and frontend failure containment [P0/P1, L]

- [x] Test realistic intermediate edits: missing delimiters, unfinished declarations, dangling selectors, half-written generics, incomplete interpolation, unterminated strings/comments, and deep broken bodies (`test/incomplete_source_test.sh`); signature help separately covers an unfinished call (`test/signature_help_test.sh`).
- [ ] Improve compiler recovery so unaffected declarations and scopes survive syntax errors where possible.
- [ ] Mark recovery nodes and unreliable semantic regions; providers must not pretend incomplete facts are proven.
- [x] On a failed analysis result, retain accepted text, keep source-only providers usable, gate semantic providers on an explicit internal `Failed` state, and clear diagnostics for that version. Semantic requests surface `InternalError`; a later successful edit restores the snapshot.
- [x] Audit the frontend boundary for panic/hang and process-global-state risks. A source audit found no thread-pool or parallel-loop entry points in the current LSP analysis call path; process isolation protects against a panic or abort, and the parent deadline contains a hang. Re-audit before introducing concurrent frontend work.
- [x] Prototype an isolated per-snapshot POSIX child with bounded pipe IPC, monotonic timeout, snapshot/job identity tags, result validation, kill/reap, and same-process recovery. This is a one-shot fork per accepted snapshot, not a persistent worker.
- [x] Validate semantic-token JSON, symbol JSON, hover records, signature records, and diagnostic-notification JSON before caching or publishing a worker result; inject content corruption with intact headers/lengths and verify failure containment plus same-process recovery (`test/analysis_worker_test.sh`).
- [x] Deduplicate and rate-limit failure messages; clear current diagnostics on failed analysis so stale findings are not presented as current.
- [x] Measure process-boundary overhead against a compatible in-process baseline and record the decision: preserve one-shot process containment while Q01 defines a responsive, restartable worker lifecycle. Five alternating samples show an approximately 27 ms fixed boundary cost on small inputs and 38 ms at 2,048 constants; payloads match exactly. See `bench/analysis_worker_overhead.py` and `bench/analysis-worker-overhead-2026-10-06.json`. The test-only baseline lacks fault containment and does not justify replacing the production worker.
- [x] Decide whether the internal `Pending`/`Ready`/`Failed` state needs a stable client-facing status extension: the private, unadvertised `$/elisa/stats` request reports aggregate open/pending/ready/failed snapshot counts without URI or source data; `test/failed_analysis_request_test.sh` verifies Failed-to-Ready transition counts, while semantic providers use `InternalError` and source-only providers remain usable.

**Progress (2026-09-14):** Every accepted source snapshot is committed before analysis and marked `Pending`; a one-shot POSIX child tokenizes once through `tokenize_frontend_source`, passes that array into `check_source_tokens`, and builds all semantic caches and diagnostics from the accepted snapshot. Its version-2 bounded packet carries job ID, document generation, client version, source length, URI hash, source hash, payload lengths, per-job analysis counters, and the shared line-index fallback delta. The parent drains concurrently with child writes, checks the shared monotonic deadline, validates packet shape, counter consistency, and identity against the still-current snapshot, then copies cache spans directly into document storage and publishes the diagnostic span without intermediate payload arrays. A child crash, timeout, malformed packet or counter, process setup failure, oversized result, or invalid frontend result produces a `Failed` snapshot with empty derived caches and cleared diagnostics; source-only folding and selection remain available, and a later edit recovers in the same process. Failure logs are bounded. `test/analysis_worker_posix_test.sh` covers large streamed output, exit validation, timeout, pending-termination kill/reap, descriptor/signal isolation, abort, and reuse. `test/analysis_worker_test.sh` injects crash, hang, malformed-packet, and negative-counter faults into a temporary server copy and verifies same-process recovery; `test/failed_analysis_request_test.sh` covers invalid returned-analysis state; `test/incomplete_source_test.sh` covers 13 malformed edits. The release canonical suite passes `pass=54 fail=0`, including freshness, storage-capacity reclamation, shared-token reuse, worker-fault, and frontend-contract checks. The analysis deadline bounds the synchronous block but does not let the event loop process cancellation, a newer edit, or shutdown messages while the job is running. The current 2,000-URI storage soak completes in about one minute; its final drain allowance is 120 seconds to cover the added per-snapshot process work. The worker benchmark is not comparable to the earlier in-process artifact because its compiler source hash differs. Compiler recovery metadata and scheduler-level cancellation remain open.

**Payload-validation follow-up (2026-09-14):** The parent now checks all five returned payload families before setting `Ready`, caching spans, or publishing diagnostics. The fault harness corrupts each payload while preserving its worker header and declared lengths, then verifies `Failed`, source-only provider availability, and version-2 recovery in the same server process. A 16-declaration regression reaches a three-digit signature row and caught a REC-relative offset mismatch in signature-field validation; the validator now passes the record-marker offset expected by the shared parser. The CRLF semantic-token regression also exposed a token beginning on the carriage-return byte; normalization now omits that out-of-line span. The focused diagnostics, semantic-token, signature-help, multiline-token, worker-fault, and VS Code `Rect` golden checks pass. The `pass=55 fail=1` run recorded here was an earlier snapshot whose temporary URI-collision server timed out before `initialize`; later canonical runs first reached `pass=56 fail=0` and then `pass=59 fail=0`. Those historical counts are superseded by the exact-source result in §2.4. Scheduler-level cancellation and compiler recovery metadata remain open.

**Acceptance:** Malformed source does not kill the session, later valid edits recover, and an injected worker crash/hang does not corrupt document state or strand requests indefinitely.

## 9. Diagnostics that users can trust

### G01 — Exact diagnostic ranges from existing frontend spans [P1, M]

**Depends on:** U01–U02, A01. **Location:** `src/diagnostics.elisa`.

- [x] Consume the adjacent compiler's existing `Diagnostic.pos` fields before undertaking an upstream span redesign (`src/diagnostics.elisa`, `test/diagnostic_ranges_test.sh`).
- [x] Prefer absolute physical offsets only when both endpoints are in the current snapshot and agree with the frontend's 1-based byte columns; document end-exclusive semantics and convert them to LSP ranges (`src/diagnostics.elisa`, `src/positions.elisa`, exhaustive offset-boundary probe in `test/positions_test.sh`, exact UTF-16/UTF-8 spans in `test/diagnostic_ranges_test.sh`).
- [x] For findings without spans, use a valid bounded fallback such as the actual source line extent or a known relevant token. Never use character `999` (`src/diagnostics.elisa`, `test/diagnostic_ranges_test.sh`).
- [x] Handle empty files, EOF diagnostics, multiline findings, and missing/default span data (`test/diagnostic_ranges_test.sh`).
- [x] Keep message/severity mapping in the compiler (`src/diagnostics.elisa`).
- [x] Emit the stable `source` field under a documented policy: frontend findings use `elisa`; LSP-generated truncation hints use `elisa-lsp` (`test/diagnostics_test.sh`).
- [x] Add stable diagnostic `code` values with an explicit compatibility/export policy: every pinned `DiagnosticKind` maps to `ELISA-<DiagnosticKind>` in the generated adapter (`src/diagnostic_codes.elisa`, `scripts/generate_diagnostic_codes.py`, `test/diagnostic_codes_test.sh`). Ordinals and wording-derived strings are never exposed.
- [x] Track position-field coverage by diagnostic family across the exact source-fingerprinted frontend and prioritize producers that omit a position (`scripts/diagnostic_span_inventory.py`, `docs/diagnostic-span-coverage.json`, `test/diagnostic_span_inventory_test.py`). The report distinguishes an explicit `pos` field from an omitted field; it does not infer that an explicit value is precise, which remains covered by runtime exact-range fixtures.

**Historical progress (2026-09-14):** Constant `source` labels were emitted (`elisa` for frontend findings, `elisa-lsp` for the synthetic truncation hint), and `test/diagnostics_test.sh` passed against the then-fresh executable. At that snapshot stable `code` values were still open because the frontend enum had no versioned identifier table; the generated adapter and synchronization gate below close that gap for the current pinned frontend.
**Stable-code progress (2026-09-15):** `scripts/generate_diagnostic_codes.py` extracts all 551 members of the pinned `DiagnosticKind` enum and deterministically generates `src/diagnostic_codes.elisa`. The adapter is included by `src/diagnostics.elisa`, emits `ELISA-<DiagnosticKind>` beside every frontend diagnostic, and has a bounded unknown fallback. `test/diagnostic_codes_test.sh` verifies exact synchronization against the manifest-pinned frontend and is part of `test/run_all.sh`; `test/diagnostics_test.sh` checks code shape and the namespace diagnostic’s exact code. Wording, severity, and source remain compiler/LSP policy fields rather than code inputs.

**Source-span coverage inventory (2026-09-30, compiler fingerprint `766f5ead…`):** The static scanner finds 1,031 `Diagnostic{...}` constructor sites across 621 `DiagnosticKind` values in 812 compiler source files. It classifies 1,022 sites to a fixed enum value and leaves nine sites whose kind is dynamic or unresolved. Of all sites, 429 explicitly provide `pos`; 602 omit it and therefore depend on the compiler's line/default position plus the LSP's bounded fallback. The largest families to migrate first by omitted-site count are `EnsureNotProven` (13), `PreconditionUnproven` (13), `UngrantedEffectCall` (9), `LocalRefinementUnproven` (8), and `RegionStoreEscape` (8), followed by `CallArgumentError` and `NullableWithoutProof` (7 each). `docs/diagnostic-span-coverage.json` records every omitted source site; the test regenerates against the release manifest's staged compiler snapshot and fails if its fingerprint or findings drift. This is source-constructor coverage rather than proof of runtime span validity; the LSP's exact Unicode, UTF-8, EOF, multiline, and bounded-fallback assertions remain the runtime evidence.


**Acceptance:** Exact-range fixtures include ASCII and Unicode, parser errors, type errors, undefined symbols, EOF, and multiline source. Every diagnostic range lies inside its identified source snapshot.

### G02 — Versioned publication and diagnostic lifecycle [P0/P1, M]

- [x] Publish only results whose document generation is still eligible; synchronous dispatch currently prevents an older analysis from overtaking a newer one (`src/main.elisa`). Dependency/configuration eligibility remains W03 work.
- [x] Include the accepted document version in diagnostics (`src/main.elisa`, `test/diagnostics_version_test.sh`).
- [x] Clear resolved errors after a clean edit and clear open-file diagnostics on close under the initial policy (`test/diagnostics_version_test.sh`, `test/documents_test.sh`).
- [ ] When project-wide diagnostics are later enabled, explicitly transfer closed files to disk-backed project ownership instead of keeping stale open-buffer findings.
- [x] Deduplicate stable duplicate findings and impose a documented maximum with visible truncation status when needed (`src/diagnostics.elisa`, `docs/development.md`).
- [x] Suppress identical repeat publications when doing so preserves version correctness (`test/diagnostics_version_test.sh`).
- [x] Separate analysis failures from source diagnostics; failed worker results clear the current diagnostic publication and analysis-backed requests surface `InternalError` rather than fabricating an Elisa diagnostic (`test/failed_analysis_request_test.sh`, `test/analysis_worker_test.sh`).

**Acceptance:** Slow old analyses never overwrite newer findings; closing/reopening cannot restore old errors; dependency edits refresh affected files and leave unrelated files quiet.

### G03 — Rich diagnostic context and fix linkage [P1/P2, M]

- [x] Expose compiler-provided secondary source locations as capability-gated `relatedInformation` (duplicate declarations point to the original; `test/related_info_test.sh`). Notes, expected/actual type details, and compiler help links remain open where the current adapter has no structured LSP mapping.
- [x] Support capability-gated related information from frontend secondary spans; deprecated/unnecessary diagnostic tags remain open until the frontend exposes authoritative tag metadata.
- [ ] Give fixable findings stable codes and opaque snapshot-tagged data for code-action resolution.
- [ ] Add source snippets only when useful and escaped; avoid duplicating entire source lines into every message.
- [ ] Prioritize root-cause diagnostics over cascades through compiler recovery improvements, not arbitrary LSP message filtering.

**Acceptance:** A duplicate definition points to the original declaration; a fix resolves from structured data and becomes unavailable after its source preconditions change.

### G04 — Pull diagnostics and workspace reporting [P2, L]

**Depends on:** W01–W03, Q01–Q03, G02.

- [ ] Implement document diagnostic result IDs, unchanged reports, and related-document results only when the underlying dependency graph is reliable.
- [ ] Add workspace diagnostics with progress, cancellation, and bounded result delivery.
- [ ] Select push or pull behavior based on client support; avoid duplicate reporting from independent paths.
- [ ] Invalidate result IDs on source, dependencies, configuration, and compiler changes.

**Acceptance:** Push-only and pull-capable clients see equivalent findings; unchanged reports are actually unchanged and canceled workspace requests stop consuming unbounded work.

## 10. Semantic highlighting without semantic guesses

### H01 — Canonical taxonomy and client fallback [P1, M]

**Locations:** `src/semtokens.elisa`, `docs/highlight-palette.md`, `docs/highlight-taxonomy.md`, and `docs/semantic-token-schema.json`.

- [x] Define all 48 custom token names and standard fallback types in the schema and server profile (`docs/semantic-token-schema.json`, `src/semtokens.elisa`). Standard and Elisa-specific modifier policy remains open.
- [x] Validate custom legend indices and every fallback mapping against the schema in `test/manifest_test.sh`; generating server constants, documentation tables, and editor mappings remains open.
- [x] Preserve the existing 48 custom names and their indices for compatible clients; coordinate any future legend migration with editor consumers (`docs/semantic-token-schema.json`, `test/manifest_test.sh`).
- [x] Negotiate a usable standard-only legend for clients that advertise supported standard token types; omit categories the client does not offer (`src/semtokens.elisa`, `test/capabilities_test.sh`, `test/semantic_range_test.sh`).
- [x] Add standard modifiers where supported: declaration/definition, readonly, and modification are negotiated and emitted only from compiler-backed or exact direct-write evidence; static, deprecated, abstract, async, documentation, and defaultLibrary remain omitted until authoritative metadata exists.
- [ ] Add Elisa-specific mutable/unsafe/ghost modifiers only with a defined client rendering contract; do not misuse unrelated standard modifiers.
- [x] Freeze the negotiated legend at initialize; keep cache entries in the canonical 48-index form and remap at response time, so presentation profiles cannot mix within a session (`src/main.elisa`, `src/semtokens.elisa`).
- [x] Update stale docs referring to `Semantic::occurrence_kind` or older comment-token API spellings to the actual adapter contract (`docs/highlight-palette.md`).

**Acceptance:** A manifest validation test proves indices/names/mappings agree; custom and generic clients both display meaningful highlighting without out-of-range token types.

**Modifier slice (2026-09-15):** `SemTok` keeps canonical declaration/definition/readonly/modification bits in the analysis cache. `semtok_profile_with_modifiers` negotiates the client's supported names at initialize, and full/range responses remap or drop bits at the protocol edge. Concrete declaration names receive `definition`, `extern` names receive `declaration`, immutable compiler-recorded `const` names receive `readonly`, and direct identifier/field mutation or `rebind` targets receive `modification`. `test/semantic_modifiers_test.sh` covers reversed/unknown client lists, exact modifier bits, full/range preservation, and a client that omits modifiers; worker validation rejects bits outside the four-bit mask. Unsupported standard and Elisa-specific modifiers stay explicitly unadvertised until compiler metadata and a client rendering contract exist.

### H02 — Exact semantic precedence [P1, L]

**Depends on:** A02.

- [ ] Make exact compiler occurrence classification authoritative for identifiers.
- [ ] Classify contextual keywords by syntactic role, not spelling alone; a legal binding named like a contextual keyword retains its binding kind.
- [x] Keep `can` as the effect-grant token after a function parameter list even when a same-line parameter is also named `can`; the focused regression also verifies the parameter use and reserved `return` token retain their own classes (`src/semtokens.elisa`, `test/contextual_tokens_test.sh`).
- [ ] Resolve fields, methods/UFCS, callable values, aliases, modules, enum cases, and type names from their actual targets.
- [ ] Replace global enum-name matching and PascalCase inference where semantic evidence exists.
  - [x] For leading-dot shorthand cases, require one compiler-registry `(owner, module)` identity with no ordinary-symbol collision before emitting the enum-variant token; exact binding and definition-reference facts take precedence. An ambiguous shorthand stays unclassified, while explicit `Owner.Variant` keeps its owner-qualified path (`src/frontend_adapter.elisa`, `src/semtokens.elisa`, `test/semtokens_test.sh`). This is a conservative guard only: bare identifier/call fallbacks and exact enum-variant occurrence targets remain open.
- [ ] Use conservative lexical fallback only in unresolved or recovery regions; keep fallback confidence internal for testing and debugging.
- [ ] Preserve useful lexical coloring during incomplete edits without using it as proof for other features.
- [ ] Classify operator roles using syntax context where one spelling has multiple meanings, such as reference syntax versus bitwise operators.
  - [x] Classify clear prefix address-of and reference-type suffix `&` as memory qualifiers, and clear infix `a & b` as bitwise; examine consecutive ampersands as one parser-compatible run and leave the array-suffix form unclassified when token context cannot expose the parser's `in_type_annotation` flag (`src/semtokens.elisa`, `test/semtoken_families_test.sh`).

**Acceptance:** Same-spelling symbols with different roles receive the correct classification at each occurrence, including within interpolation and shadowed scopes.

**Ambiguous leading-dot enum case slice (2026-10-06):** The semantic-token adapter now colors a leading-dot enum case only when the validated compiler registry identifies one `(owner, module)` pair and no same-spelled ordinary symbol exists. Exact local/parameter occurrences and resolver edges take precedence; ambiguous shorthand receives no semantic token. A repeated `Shared` spelling across `LeftState` and `RightState` verifies the conservative decline, while `LeftState.Shared` retains enum-variant coloring. `frontend_table_valid` now validates the compiler's `enum_variant_module` array alongside owner/name, and the frontend adapter contract is v15. `test/semtokens_test.sh`, `test/semtoken_families_test.sh`, `test/precedence_test.sh`, `test/frontend_contract_test.sh`, and `test/manifest_test.sh` pass; the full canonical `test/run_all.sh` reports `pass=81 fail=0`, and strict build freshness passes. Release artifact built `2026-10-06T00:41:48Z` with the latest clean compiler snapshot at HEAD `6b475d894331f0a81c3112167ef7fcf5c642a424`, source fingerprint `8188a8bcf5ee1f4dc57c6e49e63b247d36720e642141238e472d31392e6cfdf7`, supported stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and release flags `-O2 -fno-builtin -Wl,-v`. Manifest tuple: LSP inputs `e26b3d4e45af4abf571ae8ab2b2982cc36b1180b31aa83509c8a7e10ccfba8b3`, 623-file compiler include-closure SHA-256 `0dcf3c0082cb5f9e54127443007121938879b0a35790f2e2f2e002eba79e4aff`, object SHA-256 `f51dedb64d49b45ff389ffe961af561c2746513ad0e372a7986738d6e6dbaf3c`, and executable SHA-256 `9462a93e87704508cf4a5a2f790e7a5d85b73ec02dd64aaa0c2a8272e8a2fa75`. This does not close global bare-variant classification, owner/module resolution for qualified paths, or compiler-provided enum-variant identities and source spans; no latency or optimizer benefit is claimed.

**Context-sensitive ampersand slice (2026-10-06):** `semtok_ampersand_ttype` now uses the token stream's expression-start/end shapes and the compiler's consecutive-ampersand rule to distinguish prefix address-of/reference suffixes from clear infix bitwise-and. It declines the following-`[` form because deciding between a type array suffix and a value operand depends on parser type-context state that the LSP does not currently retain. The 48-family fixture verifies all three colored roles at exact source spans; `test/semtokens_test.sh`, `test/semtoken_families_test.sh` (365 exact spans across all 48 advertised categories), `test/precedence_test.sh`, and `test/fstring_semtokens_test.sh` pass on the current artifact, as do strict build freshness, `test/manifest_test.sh`, and `git diff --check`. The current release was built at `2026-10-06T01:00:20Z` with the latest clean compiler HEAD `6b475d894331f0a81c3112167ef7fcf5c642a424`, source fingerprint `8188a8bcf5ee1f4dc57c6e49e63b247d36720e642141238e472d31392e6cfdf7`, supported stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and release flags `-O2 -fno-builtin -Wl,-v`. Manifest tuple: LSP inputs `8f521bda8ff271659abf45780bd4a2030b7121a6464b1184e5ffa30fbef3c2d7`, 623-file compiler include-closure SHA-256 `86aa82d2892b76b2637c3121333cfe9209c215468275b7cd72bc3f51fad91562`, object SHA-256 `ac6990467844501109d9353a60146399cdbf41c3136385c37e6ace5114b8bef4`, and executable SHA-256 `41eb562310504878d3378149729b101c1bcbe2f7a44070b974b7c68d1b8afcd6`. These focused gates are the verification recorded for this artifact; the `81/81` canonical result above is for the preceding leading-dot enum artifact. No full-suite or performance claim is made for this build.

### H03 — Literal, interpolation, comment, and multiline correctness [P1, L]

- [ ] Consume frontend interpolation spans instead of maintaining brace/string scanners in the server when the compiler exposes them. The current compiler emits a single `FString` token and lowers interpolation expressions into the AST without retaining a reusable span side table; the LSP still has mirrored scans for semantic coloring and occurrence correlation.
- [x] Derive sub-lexed expression identity from absolute source offsets; do not use stale sublexer line metadata for semantic occurrence lookup. Exact BindingId references through interpolation pass in `test/fstring_semtokens_test.sh`; compiler occurrence positions are validated by `test/frontend_contract_test.sh`.
- [x] Cover escaped braces and backslashes, character and nested string literals containing braces, a missing closing interpolation delimiter, Unicode around embedded tokens, and the following binding's exact identity (`test/fstring_semtokens_test.sh`).
- [x] Determine whether nested f-strings are legal and add ordinary and deep-nesting fixtures; the latest compiler accepts `f"outer {f"inner {name}"}"`, and semantic tokens recursively expand it with a bounded depth-16 string fallback (`test/fstring_semtokens_test.sh`).
- [x] Verify exact nested interpolation identity across definition, references, and rename. Same-scope parameter tests assert definition and references from the nested `name` use (`test/fstring_semtokens_test.sh`) and exact declaration/use rename edits in UTF-8 and UTF-16 (`test/rename_test.sh`); unrelated same-spelling bindings remain isolated.
- [x] Calculate full physical spans for quoted literals from the compiler token contract: `semtok_display_start` and `semtok_display_length` account for delimiters around content-only token spans; exact token text is asserted for embedded string and character literals (`src/semtokens.elisa`, `test/fstring_semtokens_test.sh`).
- [x] Split multiline strings/comments into valid per-line spans for clients without multiline token support (`semtok_normalize`, `test/multiline_tokens_test.sh`).
- [x] Keep emitted spans ordered, non-overlapping, source-bounded, and nonempty; the interpolation regression checks this for all response tokens, and multiline/comment fixtures check per-line precedence (`test/fstring_semtokens_test.sh`, `test/multiline_tokens_test.sh`).
- [x] Convert token starts and lengths through the negotiated position-encoding layer before relative encoding; the f-string regression requests both UTF-16 and UTF-8 and verifies the same exact Unicode token text under each encoding (`test/fstring_semtokens_test.sh`).

**Acceptance:** Decode every response and verify token text, source order, bounds, length, type, and modifiers. Include non-ASCII text before and inside interpolation, multiline comments, nested quoting, and missing closing delimiters.

### H04 — Linear or indexed classification pipeline [P1, M]

- [x] Replace repeated full scans in `symbol_ttype`, `occurrence_ttype`, enum helpers, and readonly-constant classification with collision-safe adapter indexes built once per analysis snapshot.
  - [x] Replace the semantic-token occurrence lookup's line-wide bucket with a collision-safe composite `(source line, exact name)` hash-chain; retain the linear adapter lookup as the correctness oracle (`src/frontend_adapter.elisa`, `src/semtokens.elisa`, `test/semtokens_test.sh`).
  - [x] Index direct enum variant `(owner, name)` and bare-name lookups while retaining exact collision checks and bounded alias-owner traversal; keep the linear enum helper available as the signature-recovery correctness oracle (`src/frontend_adapter.elisa`, `src/semtokens.elisa`, `test/semtokens_test.sh`, `test/frontend_contract_test.sh`).
  - [x] Build a power-of-two-bucket, exact-byte-checked index for the compiler's immutable-constant name set and use it for semantic-token readonly modifiers instead of scanning every const for each identifier. `test/semantic_modifiers_test.sh` proves a positive constant match and an `ext` non-match that intentionally shares its bucket. The reusable 3-sample fresh-process comparison in `bench/semantic_token_const_index.py` records median open-to-diagnostics reductions of 45.3% at 2,048 constants and 46.0% at 4,096 constants on one Darwin/arm64 host; see `bench/semantic-token-const-index-2026-10-06.json`. The measurement includes frontend analysis and semantic-cache construction and is directional, not an isolated lookup benchmark or threshold.
- [x] Reuse lexer/comment spans from analysis and merge already ordered spans without an unnecessary global sort. The analysis worker returns the shared `FrontendTokenBatch` streams, the LSP classifies those tokens and takes comments from that same lexer pass, and `semtok_data_body_with_table` uses a linear merge after line-span normalization. `test/combined_lexer_test.sh` checks equivalence against both legacy lexer entry points; `test/semtokens_test.sh`, `test/fstring_semtokens_test.sh`, and `test/multiline_tokens_test.sh` cover the provider output.
- [ ] Keep JSON serialization separate from internal token representation so other encodings/legends do not require reanalysis.
- [x] Benchmark many-identifiers/many-symbols files to detect quadratic scaling. `bench/semantic-index-scaling-2026-09-29.json` holds UTF-8 input at 65,536 bytes and varies declarations/identifier count across 8, 64, and 256, with five fresh-process samples per case on the current stage0 release. Median `clean_open` times were 42.3, 189.0, and 494.6 ms; increasing declarations 32× increased end-to-end time 11.7× for these cases, with no quadratic knee observed. This includes lexing, parsing, and semantic checking, so it is evidence about the end-to-end selected corpus, not an isolated classification cost or a portable performance threshold. The JSON retains every sample and exact build/host provenance; p95s are too host-sensitive to calibrate a gate.

**Acceptance:** Instrumentation confirms no per-token scan across the full occurrence table; token generation scaling remains near linear for the selected corpus outside known compiler costs.

**Readonly-constant index slice (2026-10-06):** Semantic-token classification used to scan `immutable_const_names` for each identifier. It now builds a collision-safe hash-chain once per analysis and compares exact names within a bucket. `test/semantic_modifiers_test.sh`, `test/semtokens_test.sh`, `test/frontend_contract_test.sh`, and `test/manifest_test.sh` pass against the pinned d4 compiler, and the exact-input canonical `test/run_all.sh` suite reports `pass=81 fail=0`. The reusable benchmark holds exact source bytes constant between artifacts and records three fresh-process samples per case: open-to-diagnostics medians changed from 430.763 ms to 235.458 ms at 2,048 constants and from 1,663.331 ms to 898.263 ms at 4,096 constants. Both artifacts use compiler source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638` and the same supported stage0 SHA-256; compiler analysis remains part of the timed path, and the one-host results are directional.

### H05 — Range and delta token requests [P2, M]

**Depends on:** H01–H04, D04. Delta support additionally depends on Q01's responsive request lifecycle.

- [x] Implement range requests by filtering and remapping cached full results while retaining document coordinates: encode the first token relative to document line/character zero, not the requested range start, and subsequent tokens relative to the preceding token (`src/semtokens.elisa`, `test/semantic_range_test.sh`).
- [ ] Add delta support only after result IDs and bounded snapshot ownership are defined:
  - [ ] Bind full-result IDs to document generation, legend, and encoding.
  - [ ] Retain bounded history and compute full/delta responses from encoded-data differences.
  - [ ] Fall back to a full response for unknown/expired result IDs, incompatible legends, or a delta larger than the full payload.
  - [ ] Test edits by applying each delta to the previous integer array and comparing with a newly computed full result.
  - [ ] Trigger semantic-token refresh only for supported clients and meaningful external invalidation.

**Acceptance:** Range responses reconstruct the expected document-coordinate subset under all negotiated legends. Once delta support is enabled, arbitrary edit sequences reconstruct exactly the full token data, repeated requests reuse analysis, and result history remains within the configured memory budget.

## 11. M4 — Essential editor features

Every provider below must support current open-buffer snapshots, malformed-source recovery, Unicode positions, capability-aware response shapes, cancellation where work is nontrivial, and unknown-document behavior. Add each provider to the capability manifest only when its own gate passes.

### F01 — General semantic hover [P1, L]

**Depends on:** A02–A03, U02, J02. **Location:** `src/features/hover.elisa`.

- [x] Provide limited retained-summary hover for declarations and parameter/local bindings, with the existing loop-header capture fallback (`src/features/hover.elisa`, `test/general_hover_test.sh`). This is a tested initial slice, not full semantic hover.
- [x] Render compiler-registered enum variants as owner-qualified hover only when the variant spelling has one owner and no colliding ordinary declaration; repeated variants and overloaded declaration names stay unresolved until exact occurrence/overload identities are available (src/features/hover.elisa, test/general_hover_test.sh).
- [x] Resolve the occurrence under the exact cursor position, with a tested boundary policy for the end of a token (`test/general_hover_test.sh` covers exact ranges, same-line shadowing, UTF-8 position encoding, and the inclusive token-end hover policy).
- [x] Render the exact source signature, including generic parameters, parameter annotations/defaults, return annotation, and declared effects, for uniquely retained top-level functions (`src/features/signature_help.elisa`, `src/features/hover.elisa`, `test/general_hover_test.sh`).
- [x] Render exact declared parameter/local type syntax from compiler `BindingDeclaredType` metadata keyed by `BindingId`, including shadowed bindings (`src/frontend_adapter.elisa`, `src/features/hover.elisa`, `test/general_hover_test.sh`).
- [ ] Render inferred parameter/local types; expose declared types/return types for other declaration categories and constants when exact identity and stable type representation are available.
- [ ] Render documentation and defining module from authoritative compiler metadata when present.
- [ ] Show Elisa-specific effects, permissions, region relationships, mutability, and contracts from compiler metadata; label missing information rather than inventing it.
- [ ] Preserve the loop-capture/accumulator hover as a structured syntax/semantic feature. Replace pipe/comma scanning with parser-provided header and capture data.
- [ ] Restrict loop information to the appropriate hovered span and handle nested/default expressions without splitting strings or nested commas.
  - [x] Restrict the current capture summary to its pipe-delimited span, return the exact UTF-8/UTF-16 range, and test off-span positions and plaintext output (src/main.elisa, test/hover_test.sh).
  - [ ] Replace the delimiter/comma scanner with compiler-provided loop-header and capture data, including nested/default expressions.
- [ ] Support markdown and plaintext. Use safe fenced code rendering when source contains backticks, and escape all JSON through the writer.
  - [x] Honor Markdown/plaintext negotiation for the current loop summary and declaration/binding labels; JSON string content is escaped before response assembly (`src/main.elisa`, `src/features/hover.elisa`, `test/hover_test.sh`).
  - [x] Render source signatures inside a dynamically sized Markdown code fence so embedded backticks cannot terminate the block; plaintext clients receive the original signature text (`src/features/hover.elisa`, `test/general_hover_test.sh`).
  - [x] Show explicit parameter/local annotations in Markdown and plaintext from source-validated, bounded type slices; bindings without annotations remain untyped until inference metadata has a stable representation (`src/features/hover.elisa`, `test/general_hover_test.sh`, `test/analysis_worker_test.sh`).
  - [ ] Add safe fenced rendering for documentation and other source-derived hover content when those providers exist.
- [x] Return the exact hover range. Comments, whitespace, and unrelated characters outside the loop capture-list span do not trigger loop hover; ranges use the negotiated position encoding (`src/features/hover.elisa`, `src/main.elisa`, `test/hover_test.sh`, `test/general_hover_test.sh`).

**Acceptance:** Test parameters, locals, functions, structs, enum variants, aliases, effects, unavailable docs, token boundaries, and quoted/backtick content. Existing loop hover behavior remains available at appropriate positions.

**Progress (2026-10-05):** A unique supported top-level function hover now uses its exact parser-backed source header, preserving generic binders, parameter annotations/defaults, return annotations, and declared effect grants. `build_signature_help_index` identifies the declaration through its exact compiler name span and row identity, then locates the header's top-level colon with the compiler token stream; the header is hex-encoded into the existing owned signature cache to keep record separators unambiguous. Retention is bounded to 2,048 source bytes per header and 262,144 source bytes per document, with the existing concise summary as the fallback when a header is unavailable or over budget. The worker validates the added field before publishing a `Ready` snapshot. Markdown uses a fence longer than any backtick run in the source; plaintext preserves the original header. Focused coverage checks generic/effect/default clauses, backticks inside a default string, plaintext output, stale-cache failure handling, and normal signature help. Inferred local types, docs, non-function type information, overload selection, and compiler-provided loop syntax data remain open.

**Progress (2026-10-06):** Parameter and local hover now includes explicitly declared type syntax from the compiler's `Semantic::BindingDeclaredType` side table. The adapter carries exact `BindingId` owner/serial pairs plus declaration and annotation positions; the provider uses the binding identity to associate the type with a parameter or local, then reads the original source tokens after the annotation colon so nested types remain intact even when `Ast::expr_pos` points only at a delimiter. If the binder position is line-only, recovery requires exactly one same-line `Ident:` token; ambiguous rows omit the annotation. The worker validates hex-encoded source slices and enforces 2,048 bytes per binding and 65,536 bytes per document before publishing. Focused hover, worker-payload corruption, diagnostic inventory, unsupported-construct, frontend contract, manifest, and build-freshness checks pass. The exact compiler source fingerprint `8188a8bc…` matches latest observed compiler HEAD `6b475d8`; release compilation uses supported stage0 at `-O2`. The full runner reported `78/81` before the two stale inventories and one contract expected-vector correction were applied; those three tests now pass individually, but the aggregate suite was not rerun. No optimizer speedup is claimed, and inferred types remain open because the current adapter does not expose a stable inferred-type representation.

### F02 — Document symbols and workspace-ready symbol records [P1, M]

- [x] Return flat `SymbolInformation` by default and hierarchical `DocumentSymbol` when supported; respect client `symbolKind.valueSet` (`src/features/document_symbols.elisa`, `test/document_symbols_test.sh`). Supported compiler rows now receive block-aware ranges and exact selections where source evidence exists; struct fields and enum variants remain open because the current frontend does not expose stable positions and identities for them.
- [ ] Build hierarchical document symbols for modules, types, functions, members, constants, and other supported named declarations.
  - [x] Attach source-ordered compiler rows under the nearest earlier containing module/declaration block using validated source indentation and a precomputed block range; keep same-name rows distinct.
  - [ ] Emit struct fields, enum variants, impl/protocol members, and other compiler-exposed members only after exact editable source spans and stable owner identities are available.
- [x] Distinguish full declaration range from exact selection/name range for compiler symbol rows: block ranges use accepted source indentation, while selection ranges use validated `name_pos` or one unambiguous declaration-line lexer token.
- [ ] Preserve source order and containment for nested declarations, with recovery behavior for unfinished code.
  - [x] Preserve compiler row order, use strict indentation plus range containment for child attachment, and retain valid outlines for recovered source (`test/document_symbols_test.sh`).
  - [ ] Replace indentation-derived extents with compiler syntax-node extents when the frontend provides complete physical declaration ranges.
- [x] Provide a flat fallback for clients without hierarchical symbol support (`test/document_symbols_test.sh`).
- [ ] Reuse the same symbol records later for workspace search rather than creating a second index.

**F02 bounded hierarchy progress (2026-09-15):** The document-symbol
projection now retains one source-ordered entry record per supported compiler
symbol row. For hierarchical clients, a row is attached to the nearest
earlier module whose source indentation block contains it; module ranges cover
the final non-blank line of that block, and nested `DocumentSymbol` ranges are
validated against their parent before the worker publishes the snapshot. Flat
clients continue to receive every supported row in the table's order. Exact
selection spans prefer the compiler's `Symbol.name_pos`; when that optional
field is absent, the projection accepts a matching identifier token only when
the declaration line contains exactly one such token, and otherwise retains a
safe line extent. This covers nested module declarations and recovery rows
without inventing compiler identity. The latest frontend's struct-field and
enum-variant registries still have names/arity but no stable source positions
or symbol IDs, so those members remain intentionally omitted. `test/document_symbols_test.sh`
covers module containment, duplicate names in separate modules, block ranges,
exact selections, UTF-8 selections, value-set filtering, and malformed-source
recovery; the worker contract validator recursively checks child ranges.

**Exact selection follow-up (2026-09-29):** The compiler now supplies source-token spans for the supported named declaration categories rather than relying on an unambiguous-token fallback. The projection still validates every span against the accepted snapshot and preserves the conservative fallback for recovery or synthetic rows. The repeated-name alias fixture exercises that source of truth directly; the canonical suite passes `75/75` against the manifest-pinned latest source snapshot and stage0 artifact.

**Declaration-block hierarchy follow-up (2026-10-05):** `DocSymbolEntry` now records whether the compiler row represents an eligible block container (module, struct, enum, function, or extern). Hierarchical projection selects the nearest earlier container only when its indentation-derived extent contains the child line and indentation strictly increases; sibling rows outside that extent remain separate. `test/document_symbols_test.sh` adds a nested module/function case (`Outer` → `Outer::Inner` → `leaf`) with a later outer sibling and verifies source order and ranges. This improves hierarchy only for rows already exposed by the compiler. Struct fields, enum cases, and impl/protocol members remain omitted until exact source spans and stable owner identities exist; syntax-node declaration extents also remain an open replacement for indentation-derived ranges. The focused test and full `81/81` canonical suite pass on the 2026-10-05 manifest-pinned build after regenerating compiler-versioned inventories.

**Acceptance:** Outline navigation selects the intended name; all child ranges fit their parents where the syntax contract requires it; duplicate names remain separate entries.

### F03 — Definition, declaration, type definition, and implementation [P1, L]

The first definition slice resolves exact compiler-recorded identifier spans to a unique top-level, unqualified function in the same document. It now also resolves parameters and locals through exact retained `BindingId` occurrence groups, so nested same-spelling locals stay distinct. It includes function declaration self-edges and declines overloaded/module-scoped top-level names and unresolved references. Clients that negotiate `linkSupport` receive exact `LocationLink` origin and target token spans, while legacy clients continue to receive `Location`; the enclosing declaration range is still unavailable from the retained resolver records. This is deliberately narrower than full symbol identity and cross-file navigation; `test/definition_test.sh` verifies the supported cases.

- [x] Implement the narrow first definition slice from exact compiler-resolved reference spans to a unique top-level function.
- [x] Resolve exact parameter/local references to their declaration using retained `BindingId` groups; cover parameter shadowing, locals, and nested same-spelling locals in UTF-8/UTF-16 (`src/features/definition.elisa`, `test/definition_test.sh`).
- [ ] Distinguish declaration and implementation when the language/frontend models them separately; do not advertise aliases of definition as if they were richer semantic features.
- [ ] Add type-definition navigation using structured types and alias policy.
- [ ] Add implementation lookup for protocols/extensions only after the compiler exposes the relationship graph.
- [ ] Return `LocationLink` when supported and simple `Location`s otherwise; include exact origin and target selection ranges plus the enclosing target range.
  - [x] Negotiate link support and emit same-file `LocationLink[]` for exact function and parameter/local targets, with exact origin and target token ranges in UTF-8/UTF-16. `targetRange` currently equals `targetSelectionRange` because the retained resolver records do not include enclosing syntax-node extents (`src/features/definition.elisa`, `test/definition_test.sh`).
  - [ ] Extend retained declaration metadata or project syntax-node extents so `targetRange` covers the full supported declaration without lexical indentation guesses.
- [ ] Return multiple legitimate targets for ambiguous/overloaded cases only when compiler evidence supports them.
- [ ] Extend to imported files after W02; keep unresolved external targets explicit.

**Acceptance:** Cursor navigation reaches the correct declaration through shadowing, aliases, enum cases, member access, generics, and supported UFCS calls; comments and same-spelling unrelated symbols never become targets.

**LocationLink progress (2026-10-01):** Initialize validates the optional
`textDocument.definition.linkSupport` boolean, including escaped-equivalent
duplicate keys, before the capability profile is committed. Supported function
resolver edges and parameter/local `BindingId` matches now return a one-element
`LocationLink[]` with exact origin selection and target selection spans in the
negotiated encoding. The target range remains the exact target token for now;
full declaration extents require reliable syntax-node ranges in retained
metadata. Minimal clients retain the previous `Location` response. Focused
capability and UTF-8/UTF-16 definition tests pass; the current latest-source
canonical suite passes `81/81`.

### F04 — References and document highlights [P1, L]

- [x] Implement exact same-document references for compiler-resolved unique top-level functions and matched parameter/local BindingIds, including a nested f-string interpolation use; honor `includeDeclaration` for logged binder declarations, deduplicate, and sort (`src/features/references.elisa`, `test/references_test.sh`, `test/fstring_semtokens_test.sh`). Pattern bindings, contracts, cross-file, and general reverse symbol-to-occurrence indexes remain open.
- [ ] Expand highlights beyond the unique-function and parameter/local subset; replace direct `<-` syntax recognition with compiler-authoritative read/write/move roles and cover indirect/member/index assignments, using a neutral kind only where the role is unknown.
- [ ] Extend occurrence coverage to pattern bindings, contracts, and type references when they resolve to the same symbol; nested f-string parameter definition/references/rename are covered by the H03 regressions.
- [x] Deduplicate local locations and sort deterministically by position (`test/references_test.sh`).
- [x] Keep high-fanout result assembly subquadratic: collect candidate spans once, heap-sort in place in `O(n log n)`, then deduplicate adjacent equal ranges in a linear compaction pass. A 1,800-use LSP regression checks exact count, strict source ordering, no duplicates, and declaration filtering under UTF-8 and UTF-16; an 8,000-use warmed-analysis comparison is recorded in `bench/references-sort-2026-10-06.json` (three-process median 28.854 ms before / 23.049 ms after on one macOS host, directional only).
- [x] Keep the first results same-document and exact; cross-file completeness remains deferred until a workspace index can establish it.
- [x] Resolve ordinary parameter/local references by `(BindingId.owner, BindingId.serial)` and preserve declaration/use spans through same-line shadow initialization; exact nested-shadow and `includeDeclaration` cases run under UTF-8 and UTF-16 (`test/references_test.sh`). This relies on the adapter's validated row/token correlation and excludes constructs without proven occurrence spans.
- [x] Add same-document `documentHighlight` for the exact unique-function subset; declarations are `Text`, resolved calls are `Read`, and other symbol kinds return `[]` (`src/features/document_highlight.elisa`, `test/document_highlight_test.sh`). Local read/write distinctions remain open.
- [x] Extend highlights to exact parameter/local `BindingId` occurrences, including nested same-spelling locals (`src/features/document_highlight.elisa`, `test/document_highlight_test.sh`).
- [x] Classify binding declarations as `Text`, direct identifier `<-` targets as `Write`, and other exact binding occurrences as `Read`; UTF-8/UTF-16 tests assert declaration, RHS read, and repeated same-line write/read ranges (`src/features/document_highlight.elisa`, `test/document_highlight_test.sh`). The compiler still lacks occurrence-role facts, so indirect member/index mutation forms are not inferred.
- [x] If project analysis is incomplete, surface that limitation through the private `$/elisa/status` response: references and highlights report same-document partial coverage, references state the supported identity subset, and references explicitly say an empty result does not prove project-wide absence; the workspace index reports unavailable (`src/main.elisa`, `test/observability_test.sh`).

**Acceptance:** A fixture containing many same-spelling unrelated declarations returns only the selected symbol's occurrences; declaration inclusion and read/write distinctions are verified independently.

### F05 — Context-sensitive completion [P1, XL]

- [ ] Ask the parser for completion context at an incomplete cursor: declaration, expression, type, member, import/include path, effect list, pattern, or annotation.
- [ ] Collect visible locals/parameters, module members, accessible types, enum variants, builtins, and applicable callable members from the shared semantic model.
- [ ] Respect visibility, shadowing, lexical scope, import qualification, and supported expected-type information.
- [ ] Rank deterministically using prefix quality, scope proximity, expected type, and semantic relevance; measure ranking on real editing examples.
- [x] Compute the replacement range from the complete partially typed token, including Unicode identifiers and the cursor in the middle of a word (`test/completion_test.sh` verifies an interior Unicode cursor under UTF-8 and UTF-16).
- [x] Support plain insertion and capability-gated snippets, insert/replace edits, commit characters, and parameter-name label details for unique retained function signatures.
- [ ] Keep initial responses small; resolve expensive documentation/signatures on demand using snapshot-tagged data.
  - [x] Keep completion items small and resolve the parameter list for a unique retained same-file function on demand. Bind the item to canonical URI, document version, and open-document generation; preserve client fields and make stale/malformed data a no-op. Focused tests cover resolve, stale version/reopen, and field preservation. Documentation and return types remain unimplemented (`src/features/completion.elisa`, `src/json_writer.elisa`, `src/main.elisa`, `test/completion_test.sh`).
- [x] Return `isIncomplete: true` while the implemented same-file candidate sources are intentionally partial; completion tests assert it rather than implying the candidate set is exhaustive (`src/features/completion.elisa`, `test/completion_test.sh`).
- [ ] Add import/include edits only after workspace resolution and safe edit validation exist; completion must not add duplicate or conflicting imports.
- [ ] Avoid type-aware claims in recovery regions when the frontend only has lexical candidates.

**Partial implementation (2026-09-30; enum variants added 2026-10-01):** `textDocument/completion` now reads
same-file function, struct, enum, alias, and constant candidates from the
retained analysis summary, filters by the typed prefix, applies deterministic
prefix/label ranking, and returns a plain `textEdit` over the complete current
identifier by default. When the client explicitly declares
`CompletionItem.snippetSupport`, a unique retained function signature produces
an argument-placeholder snippet; clients without that capability and all
non-function candidates continue to receive plain insertion text. Clients
declaring `CompletionItem.insertReplaceSupport` receive an InsertReplaceEdit:
the insert range ends at the cursor, while the replace range covers the full
identifier token. UTF-8 and UTF-16 edit ranges are covered, including a cursor in the
middle of a token. When a client declares
`CompletionItem.commitCharactersSupport`, plain function-name edits include `(`
only when no opening parenthesis follows the token after horizontal whitespace;
snippets and already-started calls omit the commit character. When a client
declares `CompletionItem.labelDetailsSupport`, a unique retained function
signature contributes `labelDetails.detail` containing its parameter names;
zero-argument functions receive `()`, and ambiguous or unavailable signatures,
non-function candidates, and clients without support omit the field. Label
details and snippets share one bounded signature scan, while each capability
is negotiated independently. Wrong-type and duplicate capability keys are
rejected. A parameter candidate is now added only when its retained
`BindingId.owner` matches the selected function declaration ID and the provider
can confirm a completed function header and an indented body; a parameter
correctly replaces a same-named global function candidate. Declaration-backed
local candidates are available when their exact `OCC_LOCAL` row belongs to
that function and the declaration starts at the body's indentation or a
nested indentation block. The provider scans from the exact binder to the
cursor and withdraws a nested candidate at the first intervening outdent, so
it does not leak across an `else` or back into the enclosing block. This scope
boundary is inferred from the accepted source because the compiler exposes no
local scope-end position; it remains conservative for malformed or unusual
indentation. A visible nested local shadows a same-named parameter only within
its block; the parameter returns in a sibling block after the outdent. Binding
candidates replace same-named file candidates only when the active function
and source interval prove that binding visible, so a local in another function
no longer hides a global candidate. Duplicate file-level declarations remain
ambiguous. Parameters and locals are not offered in type contexts or
multiline incomplete signatures. The provider declines comments, ordinary
quoted strings, and member-access contexts, sets `isIncomplete: true`, and
advertises bounded function-signature resolve. Each resolvable item identifies
the canonical URI, snapshot version, and open-document generation; only the
current ready snapshot can enrich it. Resolve preserves submitted client-owned
properties and returns stale, malformed, or unknown items unchanged. It does
not re-lex or re-parse at request time. Imported/workspace names, members,
f-string interpolation, multiline-string
state, expected types, documentation/return-type resolution, and full
parser-context recovery remain open. Keep the F05 acceptance
gate open until those contexts and exclusions have dedicated tests.

**Nested-block local completion slice (2026-10-06):** Completion now offers a
declaration-backed local from the retained exact `OCC_LOCAL` row when its
`BindingId.owner` is the active function, its name token is a confirmed local
binder, and the cursor remains inside that indentation block. An intervening
outdent ends visibility, which keeps a local from an `if` arm out of the sibling
`else` arm and the enclosing function body while preserving an enclosing local
inside the nested block. `test/completion_test.sh` covers the nested and
enclosing candidates, sibling exclusion, and post-block exclusion. The latest
compiler exposes the exact binding and token span but no scope-end position, so
the scope boundary remains a bounded source-indentation inference rather than
a compiler-proven interval. The focused completion, nested f-string,
definition, references, and rename tests, manifest validation, JSON
validation, strict freshness, and diff checks pass. The previous exact
artifact passed canonical `test/run_all.sh` at `81/81`; that suite has not yet
been rerun after this completion source change. Current artifact: built
`2026-10-06T00:30:28Z` with compiler HEAD
`6b475d894331f0a81c3112167ef7fcf5c642a424`, compiler source fingerprint
`8188a8bcf5ee1f4dc57c6e49e63b247d36720e642141238e472d31392e6cfdf7`, supported
Go stage0 SHA-256
`5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and
`-O2 -fno-builtin -Wl,-v`. The build uses the clean pinned snapshot
`../Elisa-compiler/build/compiler-latest-6b475d` and records
`compiler_dirty=false`; the adjacent working compiler checkout's unrelated
`.gitignore` change is excluded. Manifest tuple:
LSP input SHA-256
`3d083f4f71d116c5dbe93e13c34bb82b3adab7f8d14ac9bbcd1c2685f9387616`, 623-file
compiler-emitted include closure SHA-256
`578fb9e7a910e20568841a910da9a9ed923035577d8b813ee4d7ae5b522e011f`, object
SHA-256 `4bf9cfe4c3fe4e8dd3ec395c744505e9728a37d8cc8bb9cb0eaffaaf1b5ee23b`, and
executable SHA-256
`823c298a8b6e1fb77e5679d1ef472b8ea390d3d4f9c7ed8961972d78ad59badb`. No
latency or stage1 qualification is claimed.

**Scope-exact completion conflict follow-up (2026-10-06):** Removed the
file-wide rule that suppressed a global candidate when any unrelated local or
parameter shared its spelling. A same-named parameter now yields to a local
only when that exact local row belongs to the active function and its
source-derived indentation interval contains the cursor; the parameter returns
after an outdent into a sibling block. Active parameter/local candidates
replace global candidates only when their binding identity and visibility are
proven, so locals in other functions no longer hide a file-level candidate.
`test/completion_test.sh` covers the nested local/parameter switch in `if` and
`else`, and a same-spelled local in an unrelated function. Completion,
manifest, JSON, strict freshness, and diff checks pass. The latest compiler
build is clean and pinned to HEAD `6b475d894331f0a81c3112167ef7fcf5c642a424`,
source fingerprint
`8188a8bcf5ee1f4dc57c6e49e63b247d36720e642141238e472d31392e6cfdf7`, supported
Go stage0 SHA-256
`5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, and
`-O2 -fno-builtin -Wl,-v`. Artifact built `2026-10-06T00:36:24Z`; manifest
tuple: LSP input SHA-256
`2e3840dc052d4ad1f97208e66bcb7095d3eecd04be182dc1ede2de6f5a253798`, 623-file
compiler-emitted include closure SHA-256
`075860034002cac1e3e07448a08832cc31ae273202beb36dc822d3c889501dd8`, object
SHA-256 `5ad4330b057a1f28f8b7236ca8d4594e01ff7a734e5ab40a530469e397a9576d`, and
executable SHA-256
`cf912b7c6fad1af7d396fc7b5a04c519f554a47f01654c02def3f4d7661fbf4c`. The
canonical suite is not rerun for this focused provider change; the previously
verified `81/81` result predates it. No performance claim is made.

**Enum-variant completion slice (2026-10-01):** The frontend adapter contract is
now v12 and validates parallel enum-variant owner/name rows. The worker copies
them into an owned, packet-validated analysis record; completion offers a
unique matching variant as kind `EnumMember` (20) and suppresses same-spelling
variants to avoid guessing between owners. Variants are excluded from type
contexts. Focused tests cover `Fast` completion, kind negotiation, and transfer
through worker packet validation. Imported/member variants, expected-type
filtering, qualified insertion, and snippets for overloads or signatures
outside the validated unique-function index remain open.

- [x] Advertise a bounded plain-text completion baseline and cover cached declaration results, type-prefix filtering, deterministic ranking, exact mid-token/Unicode edits, context declines, and malformed CompletionContext values (`src/features/completion.elisa`, `test/completion_test.sh`).
- [x] Offer uniquely named enum variants as standard EnumMember candidates from validated retained semantic metadata; test worker packet validation and client kind filtering (`src/features/hover.elisa`, `src/features/completion.elisa`, `test/analysis_worker_test.sh`, `test/completion_test.sh`).
- [x] Offer parameters only inside a matching retained function scope; a local shadows its parameter only while the local's source-derived block is active, the parameter returns in a sibling block, and unrelated-function locals do not suppress a global candidate (`src/features/hover.elisa`, `src/features/completion.elisa`, `test/completion_test.sh`).
- [x] Offer declaration-backed locals by exact occurrence owner and source position in the function body and nested indentation blocks. Stop visibility at an outdent so locals do not leak into sibling or enclosing scopes (`src/features/completion.elisa`, `test/completion_test.sh`).
- [x] Negotiate `CompletionItem.snippetSupport`; generate escaped, numbered argument placeholders and `$0` only from one retained signature record, while unsupported clients and candidates retain plain insertion (`src/main.elisa`, `src/features/completion.elisa`, `test/capabilities_test.sh`, `test/completion_test.sh`).
- [x] Negotiate `CompletionItem.insertReplaceSupport`; report insert and replace ranges separately at mid-token positions and retain ordinary `TextEdit` for minimal clients (`src/main.elisa`, `src/features/completion.elisa`, `test/capabilities_test.sh`, `test/completion_test.sh`).
- [x] Negotiate `CompletionItem.commitCharactersSupport`; attach `(` only to plain function insertions, suppress it for snippets, and omit it when an existing call suffix would duplicate the character (`src/main.elisa`, `src/features/completion.elisa`, `test/capabilities_test.sh`, `test/completion_test.sh`).
- [x] Negotiate `CompletionItem.labelDetailsSupport`; emit escaped parameter-name details for unique retained function signatures only (`src/main.elisa`, `src/features/completion.elisa`, `test/capabilities_test.sh`, `test/completion_test.sh`).
- [x] Add bounded completion resolve for unique retained function signatures with canonical URI/version/generation ownership and unchanged stale-item fallback; verify custom-property preservation, stale version, same-version reopen, and malformed input (`src/features/completion.elisa`, `src/json_writer.elisa`, `src/main.elisa`, `test/completion_test.sh`).

**Acceptance:** A curated completion corpus checks candidate inclusion/exclusion, top-ranked results, exact applied edit text, no accidental duplication, snippets on/off, mid-token completion, and recovery after a dangling dot.

### F06 — Signature help [P1, M]

**Implementation status (partial; acceptance remains open):** the current server
retains an owned signature/call index from the normal semantic snapshot, without
reparsing at request time. It serves a single, exact resolver-linked top-level
function declaration and derives the active positional argument from lexer
tokens plus nested delimiter tracking. If an unfinished call at EOF has no
resolver edge, a bounded fail-closed recovery allows only a direct, unqualified
same-file function spelling with one declaration and no other same-spelled
identifier, symbol, module member, or enum variant. Function overloads,
named-argument calls, constructors and enum variants, qualified/UFCS/member/
dynamic calls, and ambiguous or shadowed targets are declined. The focused
integration test covers nested and multiline calls, commas in strings,
incomplete and shadowed-incomplete calls, UTF-8/UTF-16 positions,
shadowing/overload/constructor declines, and LSP 3.18 context validation.
Defaults, variadics, generics, return and effect display, parameter
documentation, overload choice, trigger/retrigger behavior, and protocol-
specific parameter-label offsets remain unimplemented or unverified. Do not
mark F06 complete based on this bounded slice.

- [x] Resolve the single supported call target through an exact resolver edge and compute its positional active argument from lexer-token delimiter nesting.
- [ ] Render optional/default parameters, named arguments, variadics, generics, return type, and effects where modeled.
- [ ] Distinguish function call, constructor/variant construction, UFCS/method call, and callable value.
- [ ] Support trigger and retrigger behavior, overload selection, and markdown/plaintext parameter documentation.
- [ ] Compute parameter-label offsets in the encoding required by that specific protocol field; do not assume all label offsets use negotiated document-position units.

**Acceptance:** Nested calls, strings containing commas, multiline arguments, named/default arguments, overload candidates, and unfinished calls report the correct active parameter.

### F07 — Safe local rename [P1, L]

**Depends on:** F03–F04, D01–D02, A02. **Editing safety gate required.**

- [ ] Implement prepareRename with exact editable name range and useful rejection reasons.
- [ ] Validate the new identifier using the language lexer/parser, including contextual keyword rules and Unicode identifier support.
- [ ] Check scope collisions, capture, shadowing changes, duplicate declarations, and ambiguous references using semantic analysis.
- [ ] Reject builtins, generated-only symbols, unresolved occurrences, or unsupported rename categories.
- [ ] Generate non-overlapping versioned text edits from exact occurrence spans; exclude comments and string content except actual interpolation expressions.
- [ ] Revalidate the source generation before returning edits; never mutate the server's document text as a side effect of returning WorkspaceEdit.
- [ ] For high-confidence validation, apply proposed edits to temporary snapshots and compare binding relationships before/after.

**Partial implementation (2026-10-01):** `prepareRename` and `rename` now
support only exact same-document parameter/local `BindingId`s from the retained
analysis packet. Prepare returns the exact occurrence range and placeholder.
Rename collects the declaration and all retained uses for the selected owner
and serial, sorts and rejects overlapping ranges, then returns a versioned
`TextDocumentEdit` in the negotiated UTF-8/UTF-16 encoding. The dispatch path
rechecks the captured document generation and version immediately before
emitting the edit; returning an edit never mutates the server's source.

The proposed name is JSON-decoded and accepted only when the latest compiler
lexer tokenizes it as exactly one `Ident` followed by EOF, which supports the
compiler's Unicode identifier ranges and rejects reserved-keyword tokens. The
lexer also leaves parser-context words as `Ident`, so until parser-aware
validation exists the provider declines any all-lowercase ASCII word; a new
name must contain an underscore, uppercase letter, digit, or Unicode byte.
Because lexical-scope intervals and scratch semantic re-analysis are not yet
available, a different spelling must be absent byte-for-byte from the entire
current file. This intentionally rejects names mentioned only in comments or
strings, as well as substring collisions, to prevent capture or shadow changes
without guessing. The provider declines top-level symbols, unresolved names,
and any target that is not one exact parameter/local binding. Contextual
keyword rules, full semantic conflict checks, cross-file rename, and post-edit
binding-graph comparison remain open. `test/rename_test.sh` runs both position
encodings, applies returned edits to a copy, verifies only the chosen binding
changes, checks the edit's document version, and exercises keyword, invalid
identifier, existing-spelling, unsupported-target, and malformed-parameter
declines. This is a bounded first slice; F07 acceptance remains open.

- [x] Reject builtins, generated-only rows, unresolved tokens, and unsupported rename categories by requiring one exact parameter/local `BindingId` target; confirm unsupported function/type and unresolved-token positions decline (`src/features/rename.elisa`, `test/rename_test.sh`).
- [x] Emit sorted, non-overlapping, versioned edits from exact retained occurrence ranges and revalidate the source generation/version immediately before returning (`src/features/rename.elisa`, `src/main.elisa`, `test/rename_test.sh`).
- [x] Validate one-token identifiers with the compiler lexer, including Unicode spellings; decline bare lowercase words while parser-context validation is absent; and conservatively reject a different spelling found anywhere in source (`test/rename_test.sh`). Full contextual-keyword/parser-context analysis remains unchecked.

**Acceptance:** Rename preserves the selected symbol's reference graph, leaves unrelated names/comments/strings unchanged, rejects capture/conflicts, and refuses stale or ambiguous edits. Begin with locals/parameters, then widen by separately tested symbol category.

### F08 — Workspace symbols and cross-file references [P1, L]

**Depends on:** W01–W03, F02–F04.

- [ ] Query the workspace index for fuzzy/prefix symbol search with deterministic ranking and bounded results.
- [ ] Include unopened disk files and current unsaved overlays without double-counting a file.
- [ ] Resolve symbol locations lazily when useful and supported; bind resolve data to index/configuration epochs.
- [ ] Track workspace completeness and stream progress for large reference searches.
- [ ] Invalidate locations when files move, disappear, or change outside the editor.

**Acceptance:** Search/navigation works after clean startup without opening every file; unsaved exported-symbol edits affect referencing files and stale disk symbols disappear.

### F09 — Cross-file rename and file operations [P1/P2, XL]

**Depends on:** F07–F08, W02–W04.

- [ ] Extend rename only when the affected project graph is complete enough to prove the edit set.
- [ ] Detect conflicts involving imports, aliases, exported declarations, inherited members, and multi-root visibility.
- [ ] Use documentChanges with open-document versions where supported; revalidate disk-backed file content and metadata immediately before constructing edits.
- [ ] Define behavior for read-only dependencies, external libraries, generated files, and incomplete indexes; reject incomplete edits instead of silently skipping references.
- [ ] Add willRenameFiles/didRenameFiles and import/include path updates where supported; distinguish a symbol rename from a file rename.
- [ ] Respect client support for resource operations and change annotations; degrade or reject predictably when the edit cannot be represented safely.
- [ ] Test edits with a simulated client that applies them, sends resulting notifications, and verifies subsequent analysis.

**Acceptance:** A multi-file rename compiles/analyzes equivalently, updates precisely the intended references, catches collisions, and leaves no stale index entries after file operations.

## 12. M5 — Workspace and project correctness

### W01 — Project discovery and validated configuration [P1, L]

**Locations:** proposed `src/workspace.elisa`, `src/config.elisa`.

- [x] Capture and validate initialize-time workspace folders, preserve legacy `rootUri` fallback, and define unmatched documents as standalone (`$/elisa/workspace`; `test/workspace_roots_test.sh`).
- [x] Document the current restart-based compatibility policy for workspace-folder changes and omit dynamic-folder support from capabilities (`docs/development.md`, `docs/feature-manifest.json`); `test/workspace_roots_test.sh` verifies initial-root ownership, while dynamic updates remain unsupported.
- [ ] Read Elisa project configuration using the compiler's configuration semantics where available. The existing `project.json` describes this server's build; it is evidence of a configuration format, not proof that every client project has identical settings.
- [ ] Resolve source roots, include/module paths, standard library location, selected target, feature options, and language/compiler version.
- [ ] Associate each document with an explicit project context; handle nested and overlapping roots deterministically.
- [ ] Support multiple project contexts for the same file when targets differ, with a visible active-context policy.
- [ ] Validate malformed configuration and expose actionable configuration diagnostics or messages without disabling unrelated projects.
- [ ] Fingerprint semantic configuration and invalidate affected analyses when it changes.
- [ ] Define precedence for defaults, client settings, and per-project configuration. Current behavior has no settings request or schema; if settings are fetched with `workspace/configuration`, first implement the outbound request/response table, timeout, cancellation, and fallback from P03.
- [ ] Treat workspace settings as data: analysis must not execute arbitrary build scripts or shell snippets.

**Acceptance:** Two roots with different include paths and targets stay isolated; a configuration edit updates affected findings; a standalone untitled document remains usable without a project file.

**Implementation note:** Initialize-time URI ownership now has an independently tested longest-root/path-boundary rule, including trailing-slash roots. Clients must restart to change workspace membership; dynamic root notifications are not advertised. This is not project-context isolation: configuration discovery, per-context analysis, and dynamic root updates remain open.

### W02 — Virtual filesystem and real include/module resolution [P1, XL]

**Depends on:** W01, D01, A01. **Compiler coordination likely required.**

- [ ] Provide the compiler a file-loading interface that prefers open unsaved buffers over disk files.
- [ ] Reuse the compiler's include/module search order, qualification rules, standard library resolution, and visibility rules.
- [ ] Assign stable file identities across loading, diagnostics, symbols, and source maps.
- [ ] Detect dependency cycles and missing includes with useful source locations and bounded traversal.
- [ ] Preserve source origins for diagnostics inside included files; publish each finding against its actual document rather than the current root document by default.
- [ ] Avoid parsing/building unrelated files merely because they share a directory.
- [ ] Bound file size, traversal, symlink cycles, and unsupported URI schemes.
- [ ] Handle unreadable, deleted, or changing disk files as structured analysis conditions.

**Acceptance:** Editing an unsaved included file changes diagnostics/completion in an importer without saving; include errors point to the correct URI; cycles and missing files do not hang the server.

### W03 — Dependency graph and incremental invalidation [P1, L]

- [ ] Record direct imports/includes and reverse dependencies per project context.
- [ ] Start with conservative correctness: reanalyze affected transitive dependents when necessary.
- [ ] Add public-interface fingerprints to avoid rechecking dependents for implementation-only changes once equivalence can be demonstrated.
- [ ] Invalidate negative lookups when a previously missing file/module is created.
- [ ] Handle strongly connected components explicitly and avoid infinite reanalysis loops.
- [ ] Separate syntax, local semantic, export-interface, and cross-file reference indexes so invalidation is explainable.
- [ ] Add optional persistent index caching only after in-memory correctness; key it by compiler/schema/configuration/source identity and recover from corrupt caches.
- [ ] Verify incremental results against a clean full workspace analysis in tests.

**Acceptance:** An edit triggers all and only the safely determined affected work; incremental findings and symbol results match a cold rebuild across randomized project edits.

### W04 — File watching and external changes [P1, M]

- [ ] Prefer client file-watch support when available and use a platform watcher or bounded fallback when necessary.
- [ ] Coalesce create/change/delete/rename bursts and handle atomic-save patterns.
- [ ] Never overwrite an open unsaved buffer with a disk event; its overlay remains authoritative.
- [ ] Re-read disk-backed files and invalidate index/dependency state when they change.
- [ ] Exclude build artifacts, VCS data, generated output, and configured vendor directories using documented defaults.
- [ ] Detect watcher overflow/loss and recover by a bounded rescan with progress.
- [ ] Cancel removed-root work and release watcher/index resources.

**Acceptance:** External edits, git-style file replacement, atomic saves, directory moves, and root removal converge to the same state as a fresh workspace load.

## 13. M6 — Scheduling, cancellation, and performance

### Q01 — Responsive event loop and work scheduling [P1, XL]

**Depends on:** D01, A03–A04. Design the interfaces before implementing advanced providers.

**Selected execution model (2026-10-06):** Keep compiler analysis in an isolated one-shot POSIX child and make the parent the sole owner of document state, JSON-RPC responses, and stdout. The parent event loop multiplexes framed client input with worker-pipe readiness; a blocking frontend call or a blocking read of a partially delivered frame cannot remain on the parent path. Every job is tagged with canonical URI, accepted version, generation, source hash, and job ID. Accept edits into the authoritative document immediately, terminate/reap a worker whose generation is obsolete, and start only the newest eligible snapshot. Retain bounded requests that need a `Pending` snapshot and replay them after the matching result is validated; cancellation removes only the matching typed request and must not invalidate a snapshot still needed by another request. Start with one foreground worker and a bounded pending queue; cursor requests and current open-file work precede any future workspace indexing. This selection follows A04's matched benchmark (about 27 ms fixed and 38 ms at 2,048 constants on one Darwin/arm64 host) and its crash/hang-containment evidence. Do not move the compiler into concurrent parent threads without a separate audit of global stores and arena ownership. The execution model is selected; each runtime gate below is tracked against its implementation and tests.

- [x] Keep transport and document acceptance responsive while analysis runs. A queue alone is insufficient if a blocking frontend call prevents reading new messages.
  - [x] Add and native-test a POSIX readiness primitive that reports stdin and active-worker pipe readiness independently or together, while checking the worker deadline and termination signal (`src/analysis_worker_posix.c`, `test/analysis_worker_posix_test.sh`). Tests cover input-only, worker-only, and simultaneous readiness, caller wait timeouts, and worker-deadline expiry.
  - [x] Replace the all-at-once `read_message` path with a bounded resumable frame decoder whose retained state distinguishes header, body, complete frame, clean EOF, truncated input, and malformed framing; preserve all existing header and body limits (`src/main.elisa`, `test/transport_test.sh`, `test/transport_limits_test.sh`).
- [x] Add a readiness-gated stdin read that consumes only available bytes and returns control to the parent loop when a frame is incomplete, without rescanning or reallocating the accumulated frame on every byte. Byte-at-a-time fragmentation, pipelining, framing limits, EOF cases, and signal shutdown pass on the current release.
- [x] Add POSIX incremental worker-pipe reads and nonblocking child-reap primitives, preserving partial packet bytes across readiness turns and rejecting abnormal child exit; native tests cover no-data-yet, chunked reads, EOF, exit status, and descriptor reuse (`src/analysis_worker_posix.c`, `test/analysis_worker_posix_test.sh`).
  - [x] Split worker launch from worker-result completion so an accepted open/change returns to the event loop while the isolated child computes; incrementally drain bounded packet bytes and validate child status before publishing.
- [x] Choose and integrate an isolated worker process supervised by the parent event loop, based on the worker-fault tests, stage0/runtime constraints, and matched A04 overhead evidence.
- [ ] Avoid assuming the frontend is thread-safe; audit global stores, arenas, caches, and mutable state before concurrent in-process analysis.
- [x] Prioritize explicit cursor requests and current open-document analysis over background workspace indexing. Queued cursor-provider requests use priority 0, other analysis-backed requests use priority 1, and unrequested diagnostics use priority 2; ties use the monotonic job ID. `test/analysis_worker_test.sh` holds a slow worker on one document, queues two diagnostic snapshots, then issues hover for the later snapshot and verifies that its response and diagnostics arrive before the earlier background diagnostics.
- [x] Coalesce pending edits per document to the newest eligible snapshot without dropping required document-state transitions.
- [ ] Use a short configurable diagnostic debounce, bypassing or adjusting it for explicit requests and save/open events.
- [ ] Prevent starvation of background work with bounded fairness; cap queued work and explain busy/limited states.
- [x] Keep serialization/output separate from compute tasks and preserve exactly-once completion for queued analysis-backed requests.

**Acceptance:** A slow analysis does not prevent receipt of cancellation, edits, or shutdown; the newest document version is analyzed without processing every obsolete intermediate revision.

**Progress (2026-10-06):** The parent now runs a resumable framed-input loop beside one isolated one-shot analysis child. Jobs carry URI hash, source fingerprint, version, generation, and monotonic job ID; accepted edits abort the active obsolete child, replace the document snapshot immediately, and coalesce to the latest queued job. The parent drains packet bytes incrementally, validates the complete packet and child exit, checks snapshot identity before cache/diagnostic commit, and remains the sole JSON-RPC/stdout owner. Analysis-backed requests for `Pending` documents are copied into a 4 MiB cumulative body budget / 13 MiB logical storage budget, 128-request queue with canonical typed ID keys and exact response-ID spellings; queue bytes compact on removal and requests replay only after the matching job completes. `$/cancelRequest` returns `-32800` for one matching queued request without aborting shared analysis; close cancels its queued requests as `ContentModified`, and shutdown/exit cancel all deferred requests. Queue-wait timing now measures deferral through replay when timings are enabled. Queued semantic-token, hover, completion, signature-help, navigation, rename, and highlight requests promote their document snapshot ahead of diagnostics-only work; the regression holds a worker on one document and verifies a later hover-requested snapshot wins over an older diagnostics-only snapshot. The isolated worker regression test also covers process faults, malformed/corrupt payloads, prompt cancellation and unrelated status/stats requests, integer-versus-string ID isolation, latest-version coalescing, queue-wait timing, shutdown latency, and same-process recovery. Diagnostic debounce, sustained-input fairness, workspace background work, cancellation once provider execution has begun, and broader race permutations remain open.

**Q01 follow-up qualification (2026-10-06):** Hover now joins the bounded deferred-request queue while its accepted snapshot is `Pending`, so a slow analysis cannot turn a semantically answerable hover into an early lexical-only `null`; missing documents and failed analyses still retain the deliberate lexical fallback. Existing test cases that need analysis now wait for the matching request response or diagnostics publication, and cache/resource assertions distinguish pending from ready worker state. The latest release was built with supported stage0 SHA-256 `5f2c14780bb91b25feeef3e4dce685ba9199d264ab75f335b064741a138ea84e`, clean compiler/frontend revision `d4b40e36770d89973de1b8df93f8e0bcd091ae6a` and source fingerprint `32e2a49805f25ad79de69118c741aa75ee6e0ad9856ea27af9b0a0818e927638`, at `-O2 -fno-builtin -Wl,-v`. Strict build freshness passes; `test/run_all.sh` passes `81/81` against that manifest-pinned artifact (SHA-256 `f0fff9b4e94516dbe7e6b91f2cc893468c125a8cb460ed6b2928d97f9a808690`).

### Q02 — Cancellation and stale work [P1, L]

- [x] Track `$/cancelRequest` against canonical typed request IDs and remove a matching deferred analysis-backed request at a safe queue boundary.
- [x] Finish canceled deferred requests through the normal JSON-RPC error response path with `RequestCancelled` (`-32800`); broader in-provider cancellation remains open.
- [x] Check job ID, URI hash, source fingerprint, document generation, and version before publishing diagnostics or storing derived results.
- [x] Do not convert every ordinary edit into a `ContentModified` error. Edits rebind deferred requests to the newest accepted snapshot; close uses `ContentModified` because that document lifetime ended.
- [x] Discard an active obsolete worker when a newer accepted snapshot arrives, even when no client request was canceled.
- [ ] Handle cancellation before execution, during analysis, during result assembly, after completion, and for unknown IDs.
- [x] Ensure canceling one queued request does not abort shared analysis or destroy a snapshot still serving another request.

**Acceptance:** Deterministic scheduling tests cover every race and assert one completion, no stale publication, bounded cancellation latency, and correct latest-version state.

### Q03 — Work progress and resource budgets [P1/P2, M]

- [ ] Use progress only when supported and useful for long workspace indexing/search tasks; keep fast operations quiet.
- [ ] Cap concurrent analyses, total queued snapshots, token histories, loaded disk content, and project index memory.
- [ ] Support a documented large-file mode that prioritizes text synchronization and lightweight features when full semantic work exceeds configured limits.
- [ ] Expose limited-analysis state to the client without repeatedly interrupting the user.
- [ ] Apply bounded worker restart backoff after repeated frontend failures.
- [ ] Separate user-configured limits from hard safety bounds needed to prevent overflow or unbounded allocation.
- [x] Expose the active transport/document/analysis budgets, current usage, and explicit isolated-worker queue/cache policy through the private stats probe (`src/main.elisa`, `test/resource_budget_test.sh`, `docs/development.md`). Worker activity, queued snapshots, pending request count/bytes/storage capacity, and hard queue limits are reported; aggregate derived-cache policy is bounded and explicitly reported as retained-cost LRU eviction.

**Acceptance:** Oversized files/workspaces and slow clients remain controllable; cancellation/shutdown still work and resource-limit behavior is deterministic.

**Progress (2026-09-15):** `$/elisa/stats` now returns a `budgets` object
covering transport header/body/write deadlines, open-document/source/URI
limits and usage, one-shot worker timeout/packet cap, and cache bytes. The
current dispatch model is explicitly reported as synchronous with zero queued,
queued-capacity, and in-flight work at the stats boundary; aggregate cache
eviction is explicitly reported as retained-cost `lru_snapshot` eviction with a
configured byte limit and an eviction counter. `test/resource_budget_test.sh` overrides every configurable limit,
checks exact values before and after an analyzed document, and verifies usage
returns to zero after close. This is observability only; queue scheduling,
aggregate cache enforcement, large-file mode, and restart backoff remain open.

### Q04 — Profile-guided optimization [P1/P2, L]

- [x] Measure stage timings: decode, edit application, line index, lex, parse, semantic check, indexing, provider query, serialization, queue wait, and transport.
  - [x] Opt-in `ELISA_LSP_TIMINGS` collects bounded integer-millisecond observations for every listed stage; worker lex/parse/check/index values cross the validated packet boundary, deferred-request queue wait is measured through replay, and the last completed message is available through `$/elisa/stats` plus bounded `event=stages` logs (`src/diagnostics.elisa`, `src/main.elisa`, `src/transport_posix.c`, `test/timing_test.sh`, `test/analysis_worker_test.sh`). Serialization is frame-header construction and transport covers bounded stdio I/O.
- [ ] Eliminate redundant lexing, JSON copies, per-token scans, and avoidable allocations before introducing complex persistent data structures.
  - [x] Remove the LSP's second whole-source comment lex by using the compiler's combined token/comment pass; exact equivalence and the no-legacy-call guard are covered by `test/combined_lexer_test.sh`.
- [ ] Preserve and triage the pinned compiler's optimization diagnostics (for example, fused declarative darray fills, provable reserve bounds, and struct-padding suggestions). Separate LSP-owned findings from included compiler-source findings; apply suggestions only after checking semantics and measuring a hot-path benefit, and record intentional push loops where mutation order, early exit, or incremental work makes fusion inappropriate.
  - [x] Filter the 2026-10-05 O2 diagnostics for LSP-owned padding, declarative-fill, reserve-bound, scratch-reuse, and bounded-stack recommendations: none were emitted for LSP source in this build. Compiler-owned recommendations remain attributed to the included compiler snapshot; they were not applied to the adjacent compiler checkout, and no speedup is claimed without stage1 eligibility and benchmark evidence.
  - [x] Apply the LSP-owned `DocSymbolEntry` layout suggestion from the current compiler diagnostics. The private record now groups its eight-byte fields before its two booleans; the compiler's estimated per-entry size falls from 80 to 72 bytes, and the rebuilt diagnostics no longer report padding for this record. Behavior is covered by `test/document_symbols_test.sh`, including hierarchy/flat shape, ordering, exact selection ranges, recovery, duplicate names, kind negotiation, and Unicode ranges. A cached-provider experiment used 1,000 declarations, five fresh server processes, and 30 warm requests per process: median-of-process-medians was 4.076 ms before and 4.045 ms after (about 0.8%); per-process p95 was highly noisy, so no latency gain is claimed. The static layout saves 8 KiB for 1,000 allocated entries, without reducing any retained document-cache budget. Before artifact: SHA-256 `a46cecb9ce36a38dcbaca0f7116416cc61ee966ada03bbcdc3c475969d7c9ad2`, input hash `90070ea21f6f12dd4c195439eee55c4c25cdb0c1ed50e4bdab3462fd84c84df4`; after artifact: SHA-256 `ff5cb9c197425e28198ef7b20d377a73da504ac596ef2cf88b1f06432aac8fdd`, input hash `1052100a003062de88437b4766246bdf6e044c7d80f91b4386776a1bec4d017f`. Both use current compiler/frontend HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2`, source fingerprint `ecd23c2e0a2f0ce74760bbf0e4200f06fa3405c5af9383ab70b8d13e2e4b4eb3`, and the qualified stage0 executable SHA-256 `850a8979e17bd28f1cb91e3c88665f6707b71d83e263f280dbd152458184ea6e` at `-O2`; the latest stage1 backend qualification remains open below.
- [ ] Qualify the latest Elisa compiler optimizations against measured LSP hot paths. The compiler documents default helper scratch reuse, counted-fill capacity inference, and bounded stack placement for a narrow local `darray[i64]` subset, plus opt-in `-fnoalias` for its separately gated scalar/darray subset. Candidate LSP state includes the integer link arrays in `src/frontend_adapter.elisa` (`ref_next`, `sym_next`, enum name/owner chains) and the dense profile maps in `src/semtokens.elisa` (`type_map`, `modifier_map`, and negotiation scratch). Source inspection narrows this list: the link arrays are initialized from dynamic semantic-table `.count` values and then updated through indexed writes, while profile maps depend on negotiated JSON arrays; the compiler's documented simple bound/read-only proofs therefore do not establish eligibility for these hot paths. Do not claim that the stage1 optimizations help them until fresh compiler remarks or IR prove an accepted transformation. The high-volume buffers remain predominantly `darray[u8]`, `Lexer::Token`, `SemTok`, AST, JSON, and records; do not change representation or enable alias metadata just to trigger an optimization. Once the backend can emit the LSP, compare identical sources and compiler revisions, prove protocol parity, capture allocation/RSS and latency distributions, and retain the stage0 control.
- **Compiler optimization-integration benchmark (2026-10-06):** The clean d4b40e3 integration was compared with the preceding clean 6b475d8 snapshot using the same stage0 executable, current LSP code, and deterministic 5,000-function/302,780-byte fixture; only the compiler sources and generated diagnostic adapter differ (640 versus 641 diagnostic kinds). Across three independent server processes per scenario, median clean open changed from 1.108 s to 0.925 s, edit from 1.212 s to 0.787 s, and hover from 0.960 s to 0.829 s; cached-token response changed from 0.029 s to 0.035 s. Process peak RSS rose from 111.4 MiB to 113.5 MiB, while each storage soak ended at 0 tracked live bytes. Reports are bench/compiler-6b475d-control-2026-10-06.json and bench/current-compiler-d4b40e3-2026-10-06.json. These three-sample, single-host observations support continued profiling but do not define regression thresholds or establish results for other compilers/platforms; the cached path and RSS change remain follow-up work.
- **Current stable-source stage1 probe (2026-10-05):** Stage1 SHA-256 `27925891cf3185d91c678d902fc14db4d525d0fa47448f2104f91423c16ee1d1` passed the compiler freshness check for HEAD `541788548651d43dd466d0b5210955eb966eb18e` and fingerprint `d348d596db164ab373f8c664df67cc39d181aabc389274367aa1fd4a43848049`. The disposable stage0 control built the current LSP input `6d75200f5e8783514c00775f00b30f4ca5938e3c5d6c34c0c328cff7a608f79c` in 82.582 s. Stage1 failed after 21.565 s because its backend declined 2,108 operations before object emission; tests and benchmarks were skipped. The build-only result is `bench/compiler-upgrade-latest-541-stage1-2026-10-05-build-only.json`, with `qualification_complete=false` and `gate_passed=false`. This replaces the earlier mid-edit probe as the stable-source compatibility result. The full compiler upgrade gate remains open until stage1 emits the object, then passes parity tests and controlled performance measurements.
- [ ] Re-run the full compiler upgrade gate after the current stage1 backend can emit the LSP object. An earlier product for compiler HEAD `54360bf`, source fingerprint `ecd23c2e0a2f0ce74760bbf0e4200f06fa3405c5af9383ab70b8d13e2e4b4eb3`, passed the then-current source-freshness check, but direct LSP object emission failed at `-O2`, `-O1`, and `-O0` with 1,887 backend declines; its product SHA-256 was `109866537fb2889075edf485d829333d795b6468bcafa529343d0f9a1fb1c5cc`. The live compiler source has since advanced to fingerprint `df93e33a1e222cbcb80709a1273371e2d56d24a6250b91cb6ce572565e8145b4`; at the latest check the existing `bin/elisac-stage1` was stale and a reseed already held the shared high-memory build lock, so do not benchmark or gate that binary as current. The newer user-local stage0 SHA-256 `36faef3825056205bec43ca3674b948c76044183bc701e0728e8f59590939ff9` shares the embedded `e42bbdfe…` source revision but is marked dirty; its attempted full LSP build returned 1 with 459 diagnostics in compiler-owned included sources and produced no object, though the updated LSP had zero escaping-reference diagnostics. The release artifact from source fingerprint `ecd23c2…` is now stale against the live checkout; retain the clean pinned stage0 until a current compiler candidate passes the freshness and parity gates. The earlier full gate in `bench/compiler-upgrade-stage1-2026-09-29.json` is for older compiler source `c009…` and reports 73/75 on its disposable stage0 baseline; the direct run on that old tuple passed 75/75. The gate now retains failure names for future runs. After the active reseed settles, recheck stage1 freshness, attempt object emission at `-O2`, `-O1`, and `-O0`, then rerun the unskipped gate and record exact source/product hashes, effective optimization options, complete test result, and multi-sample latency/RSS distributions together. `bench/stage0-current-2026-09-28.json` is a prior control for the older source/artifact tuple, not a measurement of the current build.
  - **Latest compiler attempt (2026-09-29):** The compiler source is still at HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2`, with current source fingerprint `df93e33a1e222cbcb80709a1273371e2d56d24a6250b91cb6ce572565e8145b4`; the fresh stage1 product is SHA-256 `7c9c594d6f2956c3d4e0d542f87d93d26f4fb32236891306efd3ffd5cb3afe71` (2026-09-29 06:05 CEST), and its freshness guard passed. The unskipped disposable upgrade gate compared it with clean stage0 SHA-256 `850a8979e17bd28f1cb91e3c88665f6707b71d83e263f280dbd152458184ea6e` and froze the LSP at input hash `36bbea2f91b596f141d0d57d347bad11610e0eb094517a11e4ee8041f188a0de`. The stage0 control compiled successfully at `-O2` from the current frontend (artifact SHA-256 `15037705eec72aab28f1c0e857ffcf074962c781ab8ea1870dce5b725038a624`; object SHA-256 `9daeb138f8d6238656fedf79e699fbb6e73a0efeac1df73d4cf1fd6eb2e575f6`), but the complete test command reached its 900-second timeout. The report retained failure markers `test/compiler_root_env_test.sh`, `test/build_script_test.sh`, and `test/unsupported_constructs_test.sh`; later direct runs on the real checkout showed the first two pass, while the third passed all 19 probes after its compiler fingerprint was refreshed. The latest stage1 candidate itself failed release `-O2` compilation after 39.470 seconds because the backend declined functions, and it emitted no object; candidate tests and benchmarks therefore did not run. The raw gate record is `bench/compiler-upgrade-stage1-2026-09-29-latest.json`. This is a current negative compatibility result, not optimizer qualification: retain stage0, refresh the LSP release artifact against this source fingerprint, triage the three control test markers, then revisit stage1 after its backend can emit the full LSP unit.
  - **Post-gate verification on the real checkout (2026-09-29):** The authoritative release rebuild against compiler fingerprint `df93e33a1e222cbcb80709a1273371e2d56d24a6250b91cb6ce572565e8145b4` completed at `2026-09-29T04:39:49Z`, using supported stage0 SHA-256 `850a8979e17bd28f1cb91e3c88665f6707b71d83e263f280dbd152458184ea6e`, O2, `-fno-builtin`, and `-Wl,-v`. Its LSP-input hash is `36bbea2f91b596f141d0d57d347bad11610e0eb094517a11e4ee8041f188a0de`, 577-file include-closure hash `3fb13de873aee3d44b51f7998013ee066bcbac82389ca78d058686b986c19cce`, object SHA-256 `244f19c9d7c286c86d4bc9a3e0103976e3025962bfb946a738d94d8ad9ba2aaf`, and executable SHA-256 `92b3f2b73f856ce42d0150a42242648516f85886f8a708fecf85207a135af03b`; the strict build-freshness check passes. The stage1 binary remained fresh at SHA-256 `7c9c594d6f2956c3d4e0d542f87d93d26f4fb32236891306efd3ffd5cb3afe71`; direct current-source O1 and O0 object probes each exited 2 with 1,886 backend declines and no object. The O2 gate also failed to emit an object; its bounded log tail does not retain the decline count. The three baseline test markers were triaged: `compiler_root_env_test.sh` and `build_script_test.sh` pass on this real checkout; the unsupported-construct inventory was stale after compiler edits, so its source fingerprint was refreshed only after `test/unsupported_constructs_test.sh` passed all 19 expected diagnostic probes against the current compiler/stage0 tuple. The initial full gate suite itself timed out at 900 seconds and left a child probe behind; that child was stopped. The subsequent unwrapped `test/run_all.sh` completed against the authoritative release artifact at `pass=77 fail=0`, establishing fresh Darwin/arm64 validation for this tuple. It does not qualify stage1 or Linux.
- **Compiler advancement after that full run (2026-09-29; historical checkpoint):** The shared compiler checkout was then observed advancing from source fingerprint `df93e33a…` to `bfa30404ed03ab5a23cfac832cde3fa577d72c9b7e20e0813bce2ca263eda4b7`, with changes under parser and refinement checking. Stage1 product `7c9c594d…` had become stale because `src/semantic/check_refinement_arg_laws.elisa` was newer, and a new seed was observed compiling. The `77/77` result remained valid for immutable source snapshot `df93e33a…`. Those intermediate release and inventory files required refresh; the later current v11 rebuild and inventory audit against `766f5ead…` are recorded above.
  - **Previous compiler diagnostic inventory (2026-09-29, historical source fingerprint `269b3924…`):** The successful Go-stage0 `-O2` build emitted 381 warnings and no errors. Its 126 fused-fill recommendations included 24 in LSP-owned sources: `src/diagnostics.elisa:309`, `src/documents.elisa:281`, `src/features/definition.elisa:99`, `src/features/document_highlight.elisa:55`, `src/features/hover.elisa:40`, `src/features/references.elisa:168`, `src/features/selection.elisa:134,138,141`, `src/features/signature_help.elisa:465`, `src/main.elisa:1230,1262,1415,1422,1427,1431,2567,2832,3304,3437,3884,3891`, and `src/semtokens.elisa:973,1207`. Those compiler suggestions were triaged and applied as recorded in the 2026-09-30 progress below. The compiler-owned suggestions remain separate. The LSP source also has effect-grant warnings, tracked independently from optimizer remarks. No LSP `-fnoalias` or bounded-stack eligibility remark was emitted, so those transformations remain unproven for the current link arrays and negotiated profile maps.
  - **Latest compiler stage1 attempt (2026-09-30):** The live frontend checkout remains at HEAD `54360bf68398b4da8d63b82a3ad2979667798aa2`, now fingerprint `766f5eadb9518b1c97282e3532e0f300a272e3f61d19356a34ed89e9a1946a5b`; `bin/elisac-stage1` is fresh at SHA-256 `52a3c776e89f4cb7d89ea2aa661edcb6cc3409df1acf913eb5dcb9216fb573b1`, and `scripts/assert_stage1_fresh.sh` passes. A disposable current-source upgrade gate compiled the stage0 baseline at `-O2` successfully, but the candidate stage1 failed before object emission. Diagnostics include `parser_machine_laws.elisa:62` passing `u8` where `sview` is expected, `check_call_argument_exclusivity.elisa:397` giving an integer for the `name` field's `sview`, and LSP `src/main.elisa:1366` targeting `Abort` when no such parameter exists. The stage0 build took 171.767 seconds; the candidate failed after 13.541 seconds. Since no candidate object was emitted, stage1 parity tests, performance measurements, and optimizer qualification did not run. Keep the supported Go stage0 backend for releases and retry stage1 only after the source/backend contract errors are fixed. The gate record is `/tmp/elisa-lsp-stage1-latest-compile-probe.json`.
  - **Latest stage0 optimization audit (2026-09-30):** A fresh `-O2` build against compiler source fingerprint `766f5ead…` emitted 24 recommendations in LSP-owned code to replace whole-array byte-copy loops with declarative fused fills. The suggestions were reviewed for source order and complete traversal, then applied in `src/diagnostics.elisa`, `src/documents.elisa`, `src/features/{definition,document_highlight,hover,references,selection,signature_help}.elisa`, `src/main.elisa`, and `src/semtokens.elisa`. A fresh optimized build passed, and log inspection now reports zero remaining LSP byte/array-copy advisories. The focused provider, document, selection, token, and synchronization tests pass. This is compiler-guided source optimization, but no latency or allocation speedup is claimed without a controlled benchmark; retain semantic parity tests and measure before making a performance claim. No LSP-specific alias or bounded-stack eligibility was established by the current compiler diagnostics.
  - **Latest-source stage1 object probe (2026-09-29):** Stage1 product SHA-256 `ca5d65c417d6f2f0a125ef6e286cd700bbea784c5aba18d04dd4acc2c7f58f4f` passed `scripts/assert_stage1_fresh.sh` while its compiler source fingerprint matched `269b3924da9129d2565596b91ccabd33672e71f118ce013915c7e6cefbd29f02`. Direct object emission for the immutable LSP source failed at each of `-O2`, `-O1`, and `-O0` with no output object. Each log contains the same five diagnostics: `parser_machine_laws.elisa:62` passes `u8` where two `sview` arguments are required; `check_call_argument_exclusivity.elisa:397` initializes a `sview` field from an integer; `src/frontend_adapter.elisa:304` zero-initializes a non-null reference; and `src/main.elisa:1380` uses `Abort` as a target rather than a parameter. Logs are `build/latest-stage1-269b-O2-object.log`, `...-O1-object.log`, and `...-O0-object.log`. Since the candidate fails before object emission, the disposable parity/benchmark gate was not run; this is a compatibility failure, not a measured optimizer result. Preserve Go stage0 for releases and fix these compiler/LSP contract mismatches before another stage1 qualification attempt.
- [x] Measure cold and warm behavior separately and report distributions rather than one best timing (`test/bench.py`, `test/bench_rss_test.py`). Benchmark summaries now include sample count, minimum, median, deterministic nearest-rank p95, and maximum; one-sample runs remain explicitly observational.
- [ ] Benchmark source size, number of symbols, dependency fanout, Unicode density, and edit burst rate independently.
  - [x] `test/bench.py --dimensions source_size,symbols,unicode_density,edit_burst` now runs one axis at a time. Fixed-byte comment padding keeps source-size, declaration-count, and Unicode-density controls from being silently conflated; symbol cases also measure the returned `documentSymbol` count; edit-burst cases preserve UTF-8 byte length while issuing sequential full-text revisions.
  - [x] The benchmark records schema-version 3 corpus controls, exact source metrics/hashes, per-scenario distributions, and strict build-freshness provenance. A stale executable is refused unless `--allow-stale` is explicitly supplied for diagnostics.
  - [ ] True dependency fanout remains blocked by the current server's missing project dependency resolver. `--dimensions dependency_fanout` measures and labels a bounded multi-document fanout surrogate; it must not be presented as dependency-graph traversal evidence until W02/W03 exists.
- [ ] Add regression thresholds only after a stable reference environment exists; investigate changes rather than relying on noisy single-run timing failures.
- [ ] Keep an end-to-end interactive benchmark to catch improvements in one stage that worsen overall latency.

**Acceptance:** Performance changes include before/after evidence, unchanged semantic results, and no regression in retained memory or cancellation responsiveness.

**Progress (2026-09-15):** B04's independent-process scenarios already separate
cold startup/open/edit work from warm cached-token and hover requests. The
benchmark now makes the distribution contract explicit: all multi-sample
scenario and soak summaries include `sample_count`, `min`, `median`, `p95`, and
`max`; p95 uses nearest-rank `ceil(0.95 * N)` so small runs are reproducible and
a one-sample run cannot be mistaken for a stable percentile. Sparse RSS
summaries expose the same p95 and sample count while retaining their warmup and
peak fields. The unit test covers quantile boundaries and the resulting schema.
Stage-level server timings are now implemented as an opt-in diagnostic and have
passed the headless timing probe; calibrated regression thresholds remain open
work under the neighboring Q04 items. The independent corpus harness is now
present, but the dependency-fanout result is
explicitly a document-registry/provider surrogate rather than a project-graph
measurement, and no threshold has been inferred from a single host.

### 13.1 Proposed performance budgets

These are initial engineering targets to calibrate at B04, not measurements of the current server. Record hardware, OS, build type, compiler/frontend versions, fixture corpus, process warmup, and sample count with every report.

| Scenario | Initial target | Measurement boundary |
|---|---|---|
| Initialization without workspace indexing | p95 ≤ 300 ms | Process launch to initialize response |
| Warm hover/local definition | p95 ≤ 30 ms | Framed request sent to complete response |
| Warm completion/signature help | p95 ≤ 75 ms | Request to initial useful response |
| Cached full tokens, 1,000-line fixture | p95 ≤ 30 ms | Request to complete response |
| Diagnostics after edit, 1,000-line fixture | p95 ≤ 200 ms including debounce | Edit sent to current-version publication |
| Diagnostics after edit, 10,000-line fixture | p95 ≤ 750 ms including debounce | Same, with dependency scope stated |
| Cancellation recognition | ≤ 50 ms when transport can receive it | Cancel sent to cancellation state recorded |
| Expensive work stops/releases its slot | ≤ 250 ms target | Cancellation recognized to work cessation |
| Orderly shutdown | ≤ 1 s under ordinary load | Shutdown/exit sequence to process termination |
| Eight-hour representative editing soak | No crashes, protocol violations, or stale-result failures | Recorded deterministic workload plus randomized edits |
| Repeated fixed-size open/edit/close cycles | Retained live allocations plateau | Compare equivalent post-eviction checkpoints |

Use small (approximately 100 lines), normal (1,000 lines), large (10,000 lines), pathological (very long lines/deep nesting/many symbols), and workspace (100/1,000/10,000 files) corpora. Large-workspace indexing budgets must be set after the compiler/project model is understood; never hide a failed target by silently shrinking the corpus.

## 14. M7 — Safe editing and structural polish

### E01 — Code actions and compiler-backed quick fixes [P2, L]

**Depends on:** G03, F07, W02 for cross-file actions.

- [ ] Implement structured, local, compiler-supported fixes first; do not infer fixes by matching human-readable diagnostic wording.
- [ ] Good candidates, only when frontend evidence supports them: add a missing import/include, qualify an ambiguous name, fill missing enum match arms, add required fields, or insert a known annotation.
- [ ] Treat effect/permission additions, `mutable`, casts, unsafe blocks, suppression, and ownership changes as semantic changes requiring explicit, carefully explained user selection; never generic fix-all defaults.
- [ ] Return lazy actions with stable diagnostic/snapshot data and resolve edits against current validated preconditions.
- [ ] Support disabled reasons, preferred actions, action-kind filtering, and client edit capabilities.
- [ ] Validate edits with the shared safe-edit layer and temporary reanalysis where meaningful.
- [ ] Add source actions such as organize imports only when resolution, grouping, comments, and ordering semantics are known.

**Acceptance:** Applying a fix removes its intended problem without introducing unrelated edits or new errors in the fixture. Stale actions do not apply blindly, and fix-all excludes behavior-changing suggestions.

### E02 — Formatting with syntax/trivia preservation [P2, XL]

- [ ] Inventory any existing compiler/ecosystem formatter before building another implementation.
- [ ] Prefer a shared formatter backend or lossless syntax/trivia representation; the current semantic AST must not be assumed sufficient to preserve comments.
- [ ] Define indentation, continuation, blank-line, trailing-comma, newline, and final-newline policies from Elisa syntax and project configuration.
- [ ] Respect spaces/tabs settings, CRLF/LF, string content, comments, directives, and unsupported/recovery regions.
- [ ] Begin with whole-document formatting, then range formatting with clear syntactic expansion boundaries.
- [ ] Add on-type formatting only for small, predictable operations after latency and cursor behavior are proven.
- [ ] Return bounded non-overlapping edits and avoid rewriting an unchanged document.
- [ ] Prove idempotence and semantic equivalence using normalized parse/semantic comparisons; exclude source-location metadata from equivalence checks.

**Acceptance:** Formatting twice equals formatting once, comments and literal values survive, valid programs remain equivalent, malformed regions are handled conservatively, and the editor cursor does not jump unexpectedly.

### E03 — Inlay hints [P2, M]

- [ ] Add configurable inferred-type and parameter-name hints from semantic facts.
- [ ] Suppress obvious/redundant hints, respect explicit annotations, and avoid flooding every expression.
- [ ] Consider effects, captures, or region hints only when they answer a demonstrated user need and the compiler can explain them accurately.
- [ ] Query hints by requested range, resolve documentation lazily, and include optional text edits only when semantically safe.
- [ ] Invalidate on source/configuration changes and honor client refresh/resolve capabilities.

**Acceptance:** Hints have valid positions, are stable during unrelated edits, disappear when explicit syntax makes them redundant, and are usable with hints disabled or supported only partially by the client.

### E04 — Folding, selection ranges, document links, and linked editing [P2, M–L]

- [x] Folding initial slice: indentation regions, comment runs, and doc blocks; line-only results honor `rangeLimit` (`src/features/folding.elisa`, `test/folding_test.sh`). Syntax-backed control-flow regions and partial-syntax behavior remain open.
- [x] Selection-range initial slice: word → line → enclosing indentation blocks → document, with strict containment and shared UTF-8/UTF-16 position handling (`src/features/selection.elisa`, `test/selection_test.sh`). Parser-backed token/expression/statement/declaration nesting remains open.
- [ ] Document links: resolve include/import paths through the workspace resolver, avoid links to unrelated files, and expose unresolved targets conservatively.
- [ ] Linked editing: implement only for an actual paired-syntax use case in Elisa; do not substitute speculative automatic rename.
- [ ] Use shared snapshots/range conversion and add each capability independently.

**Acceptance:** Nested selection always expands, folds remain valid during partial edits, and a document link opens the same file the compiler resolves.

### E05 — Call/type hierarchy and code lenses [P2/P3, L]

- [ ] Build incoming/outgoing call hierarchy from resolved call edges; distinguish statically known calls from dynamic/ambiguous targets.
- [ ] Build type hierarchy from compiler subtype/protocol relationships, with cycle protection and lazy expansion.
- [ ] Add code lenses only for useful information such as references or recognized test entry points; compute expensive counts lazily.
- [ ] Keep executing tests/builds separate from discovery and require an explicit user action for commands.
- [ ] Bind hierarchy/lens data to snapshot/index epochs and handle stale resolve requests.

**Acceptance:** Hierarchy edges match real semantic relationships, incomplete indexes are not presented as definitive absence, and opening a document never executes project code.

### E06 — Advanced refactorings [P3, XL]

Implement one refactoring at a time after safe rename and formatter infrastructure are mature.

- [ ] Extract local: preserve evaluation count/order, control flow, effects, and region lifetime.
- [ ] Extract function: compute captures, mutation, escaping values, return/control-flow behavior, generic parameters, and permissions; reject unsupported cases.
- [ ] Inline local/function: prevent duplicated side effects, name capture, lifetime changes, and changed evaluation order.
- [ ] Change signature: update supported call sites with explicit handling of named/default/variadic arguments and overloads.
- [ ] Move declaration: update visibility/imports and dependency cycles across the verified workspace.
- [ ] Present a complete WorkspaceEdit with meaningful annotations when supported; prove intended semantic preservation via temporary analysis and targeted execution tests where appropriate.

**Acceptance:** Each refactoring has a published supported-case matrix, rejection cases, positive/negative semantic tests, and a reviewed edit preview. Unsupported ownership/effect/control-flow cases reject clearly.

## 15. Elisa-specific completeness matrix

Use this matrix to prevent features from being “complete” only for simple functions and primitive types. Actual supported syntax must be verified against the pinned frontend; taxonomy documentation alone is not proof a language construct is implemented.

| Language area | Required semantic evidence | Feature coverage to validate |
|---|---|---|
| Functions, extern/export, callable values | Target identity, signature, visibility, calling context | Hover, completion, signature help, navigation, references, rename |
| Structs and fields | Owner identity, field type, access, mutability | Member completion, field navigation, field rename, hints |
| Enums and payloads | Variant owner, payload fields, pattern scope | Highlighting, constructor completion, match actions, references |
| Aliases, modules, include/using | Qualified resolution and origin | Workspace navigation, path links, organize imports, rename |
| Generics and region parameters | Binder identity, substitutions, constraints | Type hover, completions, signature help, references |
| UFCS/extensions/protocols | Resolved target and applicability rules | Member completion, implementation lookup, call hierarchy |
| Effects and permissions | Canonical effect identity, grants, requirements | Hover, diagnostics, effect-list completion, cautious actions |
| Regions, borrowing, move, storage qualifiers | Lifetime/ownership facts and syntax role | Diagnostic locations, explanatory hover, safe-refactoring rejection |
| Mutable, linear, affine state | Binding role and mutation/consumption facts | Modifiers, read/write highlights, rename, refactoring safety |
| Patterns and refinement bindings | Scope and occurrence identity | Completion, highlighting, definition, rename |
| Loop captures/accumulators | Header syntax, capture identity, private binders | Existing hover generalized safely, references, hints |
| Lambdas and supported Unicode spellings | Exact spans, capture scope, inferred callable type | Position accuracy, hover, completion, selection |
| Interpolated strings | Embedded syntax and source mapping | Tokens, completion, hover, rename within expressions |
| Contracts/ghost/quantifiers | Specification scope and symbol identity | Highlighting, navigation, diagnostics, optional hints |
| Concurrency constructs | Task/capture semantics where modeled | Hover, diagnostic context, refactoring safety |
| Compile-time/generated code | Original source mapping and provenance | Navigation to origin, conservative edits, stable diagnostics |

For every row, keep valid, invalid, and partially typed examples. Track compiler support separately from LSP provider support, including an explicit “unknown/unavailable” state.

## 16. Test strategy and quality gates

### 16.1 Layered automated coverage

| Layer | Primary purpose | Representative checks |
|---|---|---|
| Unit | Small deterministic contracts | JSON grammar, typed fields, line index, URI conversion, cache keys |
| Property | Broad state/encoding invariants | Position round trips, edit sequence equivalence, token-delta reconstruction |
| Frontend contract | Detect compiler API/semantic drift | Spans, occurrence identities, type/signature queries, ownership |
| Provider golden | Exact feature behavior | Per-occurrence tokens, hover ranges, definition targets, edit text |
| Subprocess protocol | Real framing and lifecycle | Fragmentation, IDs, errors, notification silence, teardown |
| Workspace integration | Multi-file correctness | Overlays, include cycles, invalidation, watched changes, multi-root isolation |
| Client integration | Real editor interoperability | Negotiated features, rendering, applied edits, rapid typing |
| Stress/fuzz | Bounded failure behavior | Malformed bytes, malformed syntax, deep nesting, worker crashes |
| Performance/soak | Responsiveness and retained resources | Percentiles, cancellation, cache effectiveness, eight-hour workload |

### 16.2 Mandatory adversarial regression cases

- [ ] Header split at every byte, multiple frames per read, EOF at each framing state, short writes, interrupted reads, and client disconnect.
- [ ] Invalid JSON syntax, truncated strings, invalid UTF-8, surrogate pairs, unpaired surrogates, excessive depth, oversized numbers, duplicate critical keys, and trailing garbage.
- [ ] Integer and string request IDs, escaped IDs, missing/invalid IDs, unknown methods, malformed params, response-to-server-request handling, and cancellation races.
- [ ] Lifecycle misuse, duplicate initialization/shutdown, exit without shutdown, and no response to notifications.
- [ ] Unicode identifiers/literals/comments, combining sequences, non-BMP symbols, tabs, CRLF, long lines, empty documents, and final-empty lines.
- [ ] Full and incremental sync, ordered multi-edit lists, stale versions, close/reopen, unknown URIs, equivalent JSON escaping, and URI aliasing.
- [ ] Same-line shadowing, identical member names on unrelated types, overloaded call names, aliases, nested binders, contextual keywords as names, and ambiguous enum shorthand.
- [ ] Incomplete syntax in every major construct, nested interpolation, malformed comments/strings, source-map remapping, and synthetic positions.
- [ ] Edit during analysis, close during analysis, config change during analysis, canceled reference search, expired token IDs, and evicted snapshots.
- [ ] Unsaved dependency changes, missing-file creation, include cycles, external file deletion, watcher overflow, multi-root conflicts, and read-only library files.
- [ ] Rename collisions/capture, formatting equivalence, stale code actions, overlapping edits, unsupported client resource operations, and failed edit application.
- [ ] Huge documents, many open URIs, repeated growth/shrink, repeated frontend failure, slow output reader, and long-session RSS/allocation stability.

### 16.3 Test implementation discipline

1. Establish the expected behavior independently of the implementation. For edit application and encoding, use a simple reference model.
2. Test exact occurrences and source slices; token-name aggregation hides shadowing and repeated-reference bugs.
3. Use deterministic scheduling hooks instead of sleeps for races. Timeouts remain a deadlock guard, not synchronization.
4. Keep performance tests separate from correctness tests; normal CI should not fail on uncalibrated machine noise.
5. Use optimized builds as well as debug builds because the existing code documents historical optimizer/arena issues.
6. Keep fuzz seeds, fixture provenance, and minimized failures in the repo; large generated corpora may be reproducibly generated.
7. Compare server and compiler diagnostics on the same configuration and source graph. Treat disagreements as adapter/front-end investigation, not automatic permission to change diagnostic wording locally.
8. Require a regression test for every fixed externally observable defect. Avoid tests that merely repeat the implementation's arithmetic without an independent oracle.

### 16.4 Milestone release gates

**Foundation gate (M0–M2):** Fresh build, structured existing tests, strict protocol corpus, lifecycle matrix, position conversions, versioned document transitions, and reclamation tests pass. No known P0 defect remains.

**Semantic gate (M3):** Diagnostic ranges are bounded and precise when data exists; all semantic-token output validates; owned analysis survives cache eviction; exact identities work for local declarations and references; incomplete source recovers.

**Daily-driver gate (M4–M6):** Essential features pass end-to-end in at least two editor families; unsaved multi-file changes are correct; local/cross-file rename categories are explicitly supported; cancellation and calibrated latency/soak budgets pass.

**Polish gate (M7–M8):** Every advertised optional feature has its own correctness and fallback suite; formatting/refactoring edits meet semantic gates; releases are reproducible and support documentation is complete.

## 17. M8 — Compatibility, documentation, and releases

### R01 — Real-client compatibility matrix [P1, L]

- [ ] Validate the existing JetBrains/LSP4IJ integration referenced by project docs, including its custom token palette and actual negotiated capabilities.
- [ ] Add a generic VS Code-compatible client integration, Neovim built-in LSP, and an Emacs client as test candidates; mark supported versions only after hands-on verification.
- [ ] Validate VS Code extension-manifest contributions independently from the LSP token legend: scope values must use the host schema's array shape, and contributed custom type IDs must meet its identifier constraints. The current server already maps the 48 internal classes to an advertised standard-only legend for clients that offer standard token types; use that compatibility profile first. If VS Code needs all custom classes, add a separately negotiated legend with manifest-safe IDs and keep the dotted legacy profile for clients that use it.
- [ ] Test initialization, open/edit/close, diagnostics, tokens, hover, navigation, completion, rename, and shutdown per supported client.
- [ ] Include minimal capabilities, plaintext hover, no snippets, no delta tokens, no workspace configuration, and restricted WorkspaceEdit support.
- [ ] Capture sanitized wire traces and the exact client/server versions for reproducible interoperability failures.
- [ ] Keep protocol behavior in the server; put editor-specific colors, keybindings, and UI configuration in integration documentation or the relevant client project.

**Acceptance:** A published matrix distinguishes verified, partially supported, and untested clients. Generic clients remain useful without custom Elisa styling.

**Compatibility finding (2026-09-14):** The server's current custom legend uses dotted `elisa.*` token names, while VS Code's extension contributions declare custom token types and map semantic selectors to TextMate scopes; the documented scope-map values are arrays. `semtok_negotiate_profile` already retains the legacy custom legend for clients that omit semantic-token capabilities or offer the complete custom list, and maps other advertised standard-token sets through the existing fallback table. Keep the wire legend stable for now and use that standard fallback in the VS Code integration. A future fine-grained VS Code profile must use identifiers valid in the extension manifest and matching wire names; it should be opt-in so existing dotted-legend clients keep their current mapping. This finding is based on the current server source and VS Code's [Semantic Highlight Guide](https://code.visualstudio.com/api/language-extensions/semantic-highlight-guide) and [Contribution Points](https://code.visualstudio.com/api/references/contribution-points). The sibling extension's exact compiler-backed `Rect`, field-type, and post-`på` UTF-16 token assertions pass against the current LSP executable. Its strict `npm run test:semantic` gate subsequently passed all 9 checks with `ELISA_REQUIRE_FRESH_LSP=1` against the refreshed latest-source LSP build; broader editor-host and client-family validation remain open.

### R02 — Highlight accessibility and visual quality [P2, M]

- [ ] Validate custom colors on actual dark backgrounds and provide a light-theme/high-contrast strategy in the client integration.
- [ ] Evaluate low-salience comments/punctuation for readable contrast rather than assuming palette values are accessible on every background.
- [ ] Use modifiers and editor styling to supplement color for declaration, mutability, deprecated, and ghost distinctions.
- [ ] Test color-vision-deficiency simulations and real screenshots across representative Elisa code.
- [ ] Ensure client themes can override palette choices; the server should transmit semantics, not force RGB styling.

**Acceptance:** Representative screenshots are reviewed for legibility, related categories remain distinguishable, and disabling custom colors preserves meaningful standard semantic tokens.

### R03 — Documentation and troubleshooting [P1, M]

- [x] Add README with supported features, current limitations, build/install/run steps, and initial editor setup (`README.md`).
- [x] Add development documentation for toolchain/frontend compatibility, test commands, module ownership, and region/lifetime constraints (`docs/development.md`).
- [x] Document project discovery, include paths, unsaved-buffer behavior, configuration precedence, and supported URI schemes (`docs/workspace-and-configuration.md`, linked from `README.md` and `docs/development.md`).
- [x] Document position encoding, semantic-token schema, diagnostic policy, and optional feature status (`docs/development.md`, `docs/semantic-token-schema.json`, `docs/feature-manifest.json`).
- [x] Add troubleshooting for missing compiler, incompatible frontend, startup failures, slow projects, and malformed client configuration (`docs/troubleshooting.md`).
- [x] Provide a minimal bug-report recipe with build/client versions, sanitized logs, and an intentionally supplied source reproducer (`docs/troubleshooting.md`).
- [x] Replace the historical `docs/119` identifier in loop-header hover with the user-facing “Loop header” label (`src/main.elisa`, `test/hover_test.sh`). The rule remains traceable in compiler/developer documentation.

**Workspace documentation progress (2026-09-15):**
`docs/workspace-and-configuration.md` now gives one explicit contract for
initialize-time root discovery, longest-root ownership, the distinction between
the server build's compiler include path and future user-project include paths,
open-buffer precedence across the document lifecycle, environment versus
protocol settings precedence, and the URI schemes that remain opaque overlays.
It records the current no-filesystem/no-cross-file scope and the resolver rules
that must be tested before W01/W02 can expand it. README, development notes,
and the feature manifest link to that contract; the existing root,
configuration, document, and URI regressions remain the evidence anchors.

**Acceptance:** A new contributor can build/test from a clean machine, and a user can configure a supported editor without reading server source.

### R04 — CI, packaging, and upgrade safety [P1, L]

- [ ] Add CI for clean compiler/frontend setup and server build on every supported platform/architecture combination.
- [ ] Run unit, provider, protocol, and focused workspace suites on changes; run longer fuzz/soak/performance jobs on a suitable schedule.
- [ ] Cache dependencies by immutable revision and relevant build settings; never let caches hide an unbuildable clean tree.
- [ ] Package binaries with version metadata, dependency/license notices, checksums, and documented runtime requirements.
- [ ] Validate packaged artifacts, not only development executables, using initialization and representative editing tests.
- [ ] Adopt a release policy for frontend compatibility, token-schema changes, configuration migrations, and minimum client requirements.
- [ ] Provide rollback instructions and retain the last known good artifact/configuration compatibility information.
- [ ] Decide Windows support through an explicit platform effort covering transport, paths, watcher/process APIs, linker/runtime, and CI; do not advertise it merely because the protocol is cross-platform.

**Acceptance:** A tagged release can be reproduced from recorded inputs, installed on a clean supported machine, and smoke-tested without the source checkout layout.

### R05 — Observability and maintenance process [P1/P2, M]

- [x] Add bounded stderr logs with levels, method timing, document generation, cache outcome, and compiler status (`src/main.elisa`, `src/transport_posix.c`, `test/observability_test.sh`).
- [x] Keep source text and full document contents out of default logs; verbose wire tracing is explicit and documents sensitive-data implications (`docs/development.md`, `$/elisa/status`).
- [x] Use a process-wide size-limited stderr budget and bounded duplicate-error reporting (`ELISA_LSP_LOG_MAX_BYTES`; `src/main.elisa`).
- [x] Add a self-description/version command or safe diagnostic mode that reports build/configuration compatibility without launching project code (`$/elisa/status`, `test/observability_test.sh`).
- [x] Maintain a known-issues list and capability manifest, with supported/experimental/unavailable status per feature (`docs/known-issues.md`, `docs/feature-manifest.json`, `test/manifest_test.sh`).
- [ ] Review compiler changes for tooling impact using contract tests; keep custom lexer/parser heuristics on a tracked removal list.
- [ ] Revisit performance budgets and corpus coverage periodically; fixed regressions remain permanent tests.

**Known-issues progress (2026-09-15):** `docs/known-issues.md` now records release-facing supported, experimental, and unavailable states for the current stage0/latest-frontend tuple, cross-file scope, editing features, scheduler boundary, platforms, token rendering, and filesystem identity. The feature manifest links it and the manifest test validates the documentation reference.

**R05 progress (2026-09-15):** Structured stderr is now opt in at
`ELISA_LSP_LOG_LEVEL=off|error|warn|info|debug` (default `warn`) and every
server stderr write is capped by `ELISA_LSP_LOG_MAX_BYTES` (65,536 by default,
1,024–4,194,304 allowed). Info lines carry a sanitized method name, monotonic
elapsed milliseconds, document generation, cache outcome, and analysis state;
debug adds accepted document generation/version events. Startup info records
that the compiler frontend is embedded/compiler backed, the frontend contract
version, isolated worker packet version, and generated diagnostic-code status.
The private `$/elisa/status` request reports JSON-RPC/LSP/worker/diagnostic
compatibility versions, effective safety limits, compiler/frontend status,
position encoding, and logging budget/usage. It does not inspect workspace
files or execute project code. The focused test verifies opt in output,
source/URI exclusion, size bounds, status schema, and invalid-log-setting
startup rejection; full wire tracing, log rotation across process lifetimes,
known-issues maintenance, and the remaining maintenance/performance review
items stay open.

**Acceptance:** A failed request can be traced to transport, protocol, document, frontend, provider, or client behavior without dumping user source by default.

## 18. Risk register and decisions that must be made explicitly

| Risk / uncertainty | Current evidence | Mitigation / decision gate |
|---|---|---|
| Stale executable masks build breakage | Existing binary passes; default compiler unavailable | B01 fresh-build provenance before relying on runtime results |
| Frontend API drift | Direct sibling include and side-table access | A01 adapter, pinned revision, upgrade contract tests |
| Region/lifetime regressions | Source comments document historical arena defects | D04/A03 ownership proofs, optimized stress tests, no retained temporary spans |
| Compiler positions only partially populated | `Diagnostic.pos` exists with defaults | G01 coverage inventory, bounded fallback, upstream producer migration |
| Insufficient occurrence identity | Current lookup is line/name/kind | A02 exact spans and symbol IDs before navigation/rename claims |
| Frontend cannot be interrupted safely | Current analysis blocks the server loop | Q01 prototype and A04 containment decision before daily-driver release |
| Semantic coverage differs from language claims | Taxonomy contains planned constructs | Pinned-frontend feature matrix and explicit unavailable state |
| Workspace semantics differ from standalone check | Current adapter checks one parsed file | W02 compiler-owned resolver and unsaved overlay integration |
| Custom token legend fails on generic clients | All 48 types are custom | H01 standard mappings plus R01 client matrix |
| Formatter loses comments or changes semantics | No lossless formatter present in this tree | E02 backend/trivia inventory and equivalence gate |
| Rename produces partial unsafe edits | No current identity/index/edit infrastructure | F07 first, then F09 only with workspace completeness checks |
| Scope becomes unbounded | Many optional LSP features exist | Milestone gates, independently advertised providers, P3 use-case requirement |
| Performance changes compromise recovery | Reuse/concurrency introduces ownership complexity | Immutable snapshots, counters, cold/incremental equivalence tests |
| Watchers miss external changes | No watcher layer today | W04 overflow recovery and full-rescan parity tests |
| Old async results cross close/reopen boundaries | No generation today | D01 internal generations independent of client version |

Required architecture decisions, each recorded as a short document with a prototype or evidence:

1. **Toolchain delivery:** pinned compiler/frontend checkout, package, or vendored artifact; development overrides and release provenance.
2. **Frontend boundary:** embedded adapter versus persistent worker, failure isolation, cancellation mechanism, and ownership serialization.
3. **Document storage:** owned flat snapshots versus slabs/piece table; memory costs and region-system feasibility.
4. **Source identity:** URI canonicalization, multi-root context, include identity, and physical/generated source mapping.
5. **Tooling API:** exact occurrence record, symbol IDs, structured types, documentation attachment, and compatibility versioning.
6. **Diagnostics model:** initial open-file push policy, later project/pull reporting, and ownership of closed-file findings.
7. **Semantic token contract:** canonical manifest, standard fallback mapping, modifier support, and client migration policy.
8. **Formatting ownership:** reuse existing formatter, add compiler trivia/CST support, or implement a carefully bounded standalone formatter.

Do not require all decisions before coding. Make each before the work item that depends on it and use the smallest compiling prototype needed to settle uncertainty.

## 19. Suggested implementation slices

Keep changes reviewable and independently testable. The order below is a concrete starting sequence; split large entries further if compiler work is substantial.

| Slice | Deliverable | Primary gate |
|---|---|---|
| 01 | Toolchain discovery, pinned provenance, fresh build, unified test entry point | B01 |
| 02 | Shared framed subprocess client; migrate current tests to valid JSON and lifecycle | B02–B03 |
| 03 | Strict JSON parser errors and checked values with writer | J01–J03 |
| 04 | Buffered framing and complete output writes | T01–T02 |
| 05 | Envelope validation, unknown-method errors, exactly-once completion | P01 |
| 06 | Initialize/shutdown state machine, explicit capabilities, server info | P02–P03, T03 |
| 07 | Explicit open-state/version/generation store; clear close diagnostics | D01 |
| 08 | Position conversion library and reference tests | U01 |
| 09 | Correct full-sync lists, incremental edit model, Unicode integration | D02, U02 |
| 10 | Reclaimable snapshot ownership and lifetime stress tests | D04 |
| 11 | Frontend adapter and exact existing diagnostic spans | A01, G01–G02 |
| 12 | Compiler tooling occurrence/symbol API and local indexes | A02 |
| 13 | Retained reusable analysis and error-recovery contract | A03–A04 |
| 14 | Token schema, exact semantic precedence, interpolation/range correctness | H01–H04 |
| 15 | General hover and document symbols | F01–F02 |
| 16 | Definition, local references/highlights, local rename | F03–F04, F07 |
| 17 | Completion and signature help | F05–F06 |
| 18 | Project configuration, URI/file identities, overlay resolver | D03, W01–W02, U03 |
| 19 | Dependency invalidation, watchers, workspace index | W03–W04, F08 |
| 20 | Responsive scheduler, cancellation, worker containment if selected | Q01–Q03 |
| 21 | Safe cross-file rename/file operations and rich diagnostics | F09, G03 |
| 22 | Token delta/range, optional pull diagnostics, profile-driven optimization | H05, G04, Q04 |
| 23 | Compiler-backed code actions and formatting | E01–E02 |
| 24 | Hints and structural features; hierarchies only where supported | E03–E05 |
| 25 | Client verification, release packaging, docs, soak gates | R01–R05 |
| 26+ | Individually justified advanced refactorings and later protocol features | E06 and new scoped plans |

Prototype the scheduler/containment mechanism around slices 10–13 so feasibility is known early; slice 20 is the integration/completion gate, not the first investigation. Likewise, begin real-client testing after slice 06 and maintain it throughout.

## 20. Definition of done for every implementation slice

- [ ] The user-visible behavior and failure behavior are stated precisely.
- [ ] The smallest relevant independent regression tests pass on a freshly built executable.
- [ ] Source snapshot, URI, version/generation, and position-encoding invariants are preserved.
- [ ] All retained compiler/source spans have documented ownership and release behavior.
- [ ] Relevant malformed-input, incomplete-source, and stale-state cases are covered.
- [ ] Requests complete exactly once; notifications remain response-free.
- [ ] Capability advertising matches actual tested functionality and client fallbacks.
- [ ] User edits, if any, are non-overlapping, version-aware, and semantically justified.
- [ ] Performance evidence is included for changes to hot paths, scheduling, caching, or indexing.
- [ ] Toolchain/frontend provenance and required cross-repository changes are recorded.
- [ ] Documentation, feature status, token manifest, and known limitations are updated where affected.
- [ ] The change does not overwrite unrelated working-tree edits or bundle unrelated compiler cleanup.

## 21. Final acceptance checklist

### Trust

- [ ] No known P0 protocol, crash, ownership, or stale-source bug remains.
- [ ] Malformed messages and broken Elisa code cannot silently corrupt document state.
- [ ] Unicode source positions and all emitted edit ranges pass reference-model tests.
- [ ] Diagnostics, highlighting, hover, navigation, and rename agree on symbol identity.
- [ ] Current unsaved source is authoritative across the whole project graph.

### Everyday usefulness

- [ ] Precise diagnostics and semantic highlighting work throughout supported Elisa syntax.
- [ ] Hover, document/workspace symbols, definition, references, completion, and signature help work on real projects.
- [ ] Supported rename categories are exact and unsafe cases are rejected clearly.
- [ ] Formatting/actions/hints are available only where their individual gates have passed.
- [ ] At least two editor families pass the full essential-feature workflow.

### Responsiveness and operation

- [ ] Interactive requests meet calibrated latency budgets on documented corpora.
- [ ] Cancellation and shutdown remain responsive during expensive analysis.
- [ ] Long editing sessions do not leak live snapshots or accumulate unbounded closed-document state.
- [ ] Compiler/frontend failures are recoverable or cleanly contained with actionable reporting.
- [ ] Clean builds, packaged artifacts, and upgrade/rollback paths are verified.

### Continued improvement

- [ ] Compiler tooling changes are checked by stable contract tests.
- [ ] Every fixed bug adds a permanent reproducer.
- [ ] Capability status and known limitations are accurate and visible.
- [ ] Performance and semantic coverage are tracked over time.
- [ ] Optional features are expanded only when they can meet the same correctness, ownership, and usability standards as the core.
