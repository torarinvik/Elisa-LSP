# Frontend adapter contract

The adapter contract is **version 13**. `frontend_contract_version()` in
`src/frontend_adapter.elisa` is the runtime identifier exposed by the server
status probe and compiled by `test/frontend_contract_test.sh`. Bump it whenever
the frontend operation surface, result shape, interpretation, or ownership
rules below change. A frontend update must pass the contract fixture before
providers can rely on the changed surface.

The server owns the physical source snapshot for the complete analysis job. Its
`source_len` excludes the trailing NUL sentinel. Compiler positions and token
spans are byte offsets into that exact source; compiler display names and
`#line` remapping do not change document identity or provider coordinates.

The latest frontend represents parameter/local occurrences in parallel
`ref_line`, `ref_name`, `ref_kind`, `ref_binding_ids`, and `ref_pos` arrays.
Parsed parameter declarations, local declarations, loop binders, assignment
targets, and resolved identifier uses carry their exact physical `Ast::Pos`.
Generated occurrences without an exact source token may use either an all-zero
position sentinel or a line-only sentinel whose line and end-line match
`ref_line` and whose columns and offsets are zero. The adapter validates every
concrete span against the accepted source and uses it directly; only these
zero-span sentinel rows enter the conservative `(line, name)` fallback, which
pairs candidates only when counts and roles are unambiguous.
This removes traversal-order pairing for ordinary parameter/local references,
including same-line shadow initializers. Pattern binders, interpolation rows,
and other compiler constructs that still lack occurrence records or physical
positions remain explicit follow-up work.

| Operation | Adapter boundary and result | Ownership and lifetime |
| --- | --- | --- |
| Lex | `tokenize_frontend_source(source, source_len)` calls the expanded-unit lexer and returns `LspFrontendTokenBatch` with parser tokens and comment tokens. | The batch descriptors and backing arrays belong to the current analysis-job region. Token/comment text is represented by spans into the source. Keep source and batch alive together through parsing, queries, and serialization; do not store either descriptor or borrowed text in the session document store. |
| Parse | `frontend_parser_parse_file(source, tokens)` returns `Ast::File`, including parser errors and recovery nodes. | The file belongs to the current job. It may refer to the source and token stream; keep both alive through semantic analysis and every adapter query. Parser errors are part of the result even when recovery produced usable declarations. |
| Analyze | `Semantic::check(file)` returns `Semantic::SymbolTable`, including compiler diagnostics and the semantic side tables consumed by the adapter. In the current frontend, each `Symbol.id` is a `DeclId` equal to that symbol's row index in this table. | The table is job-local and is consumed while its source, token batch, and AST remain alive. Treat all table arrays and any views into them as borrowed from this job; never retain frontend pointers or container descriptors in `LspDocument`. A declaration ID is table-local and expires with this analysis result; it is not a cross-file or cross-version identity. |
| Query | Named `frontend_*` accessors read symbol, occurrence, enum-variant owner/name, definition-edge, and diagnostic facts from a validated symbol table. The enum variant arrays must have equal lengths and contain nonempty owner and name views. | Scalar results are copied values. Returned `sview` values and source positions are borrowed from the source or table and may be used only during the same job. Copy bytes into an owned result before the job ends. |
| Snapshot projection | `LspFrontendAnalysisSnapshot` groups the contract version, source length, token/comment batch, recovered `Ast::File`, `Semantic::SymbolTable`, symbol and diagnostic arrays, occurrence positions, and a `Complete` / `Recovered` / `Rejected` state. The worker builds semantic tokens, symbols, hover/navigation/signature indexes, and diagnostics from that value before serializing the result packet. | The record is a job-local shallow projection; it does not extend the lifetime of its source, token, AST, or table owners. The packet owns serialized bytes and scalar snapshot identity. The parent validates identity, completeness, payload shape, and spans before copying cache bytes into document-store storage. No AST, table, token, comment, or borrowed view crosses the process boundary. |

Completeness is explicit and has two gates. `Complete` means the parser
returned no syntax errors; `Recovered` means it returned at least one syntax
error together with bounded recovery facts; `Rejected` means a contract check
failed and is never a provider-ready snapshot. The snapshot validator checks
that these states agree with `Ast::File.errors` and that symbol/diagnostic
sidecars match their semantic-table arrays. First, parser recovery is ordinary
frontend output: syntax diagnostics and bounded recovery facts may be published
when the returned table satisfies the adapter contract. Second,
`frontend_table_valid` and `frontend_occurrence_positions` must validate the
normal-return tables and source-backed spans before semantic projections are
built. A malformed result is rejected as an incomplete snapshot; the LSP
clears derived caches, marks the accepted document `Failed`, and publishes
empty diagnostics for that version. A later accepted version starts a fresh
job. A panic, abort, or hang inside the frontend is handled by the process
boundary documented under A04, not by this in-process validation contract.

Only the adapter may interpret compiler `SymbolTable` field layout, numeric
reference roles, declaration-ID representation, or enum metadata. The
`symbol_declaration_id` accessor exposes a validated table-local ID and
`frontend_table_valid` requires every current symbol row's ID to equal its row
index; this is not a promise that every declaration kind has a `Symbol` row.
Providers consume named adapter facts or serialized projections. Diagnostic
wording and severity remain compiler-owned; token presentation, LSP coordinate
conversion, and JSON framing remain server-owned.
