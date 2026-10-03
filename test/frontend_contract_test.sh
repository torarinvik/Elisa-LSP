#!/usr/bin/env bash
# A01 frontend-contract fixture: compile and exercise the frontend adapter
# against the pinned compiler. If the frontend surface changes (renamed field,
# renumbered `ref_kind`, moved enum registries), this fails in the adapter's
# terms — a localized contract break, not a scattered feature regression.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ELISAC="${ELISAC:-$HOME/.elisac/elisac-stage0}"
[[ -x "$ELISAC" ]] || { echo "error: no compiler at $ELISAC (set ELISAC)" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "error: missing clang" >&2; exit 2; }

COMPILER_ROOT="${ELISA_COMPILER_ROOT:-$ROOT/../Elisa-compiler}"
[[ -d "$COMPILER_ROOT/src/semantic" ]] || { echo "error: compiler checkout not found at $COMPILER_ROOT" >&2; exit 2; }
COMPILER_ROOT="$(cd -- "$COMPILER_ROOT" && pwd -P)"

python3 - "$ROOT/docs/frontend-adapter-contract.md" <<'PY'
from pathlib import Path
import sys

contract = Path(sys.argv[1]).read_text(encoding="utf-8")
required = (
    "**version 13**",
    "| Lex |",
    "| Parse |",
    "| Analyze |",
    "| Query |",
    "| Snapshot projection |",
    "Completeness is explicit and has two gates.",
)
missing = [item for item in required if item not in contract]
assert not missing, f"frontend adapter contract is missing: {missing}"
PY

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# diagnostics.elisa keeps a source-relative ../../Elisa-compiler include so
# the normal build can resolve the selected checkout through its staged alias.
# Recreate that layout here instead of letting this standalone probe silently
# compile against a different adjacent checkout.
mkdir -p "$WORK/Elisa-LSP"
cp -R "$ROOT/src" "$WORK/Elisa-LSP/src"
ln -s "$COMPILER_ROOT" "$WORK/Elisa-compiler"

cat > "$WORK/Elisa-LSP/probe.elisa" <<EOF
# The runtime is pulled in transitively via semantic.elisa (same mechanism as
# src/diagnostics.elisa); including it explicitly here made the probe diverge
# from the server build and trip unrelated frontend-source strictness.
include "$WORK/Elisa-LSP/src/json.elisa"
include "$WORK/Elisa-LSP/src/json_writer.elisa"
include "$WORK/Elisa-LSP/src/diagnostics.elisa"
include "$WORK/Elisa-LSP/src/frontend_adapter.elisa"

def main() -> int can[Console.Write, Memory.Allocate, Console.Format, Abort.Panic]:
    text: cstr = "def f(p: i64) -> i64:\n    local: i64 = p\n    return local\nenum Color:\n    Red\n# lexer comment side channel\n"
    buf: mutable darray[u8] = []
    buf.extend(sview(text, 0, -1))
    buf.push(0)
    src: u8& = &buf[0]
    len: usize = buf.count - 1
    token_batch: LspFrontendTokenBatch = tokenize_frontend_source(src, len)
    comment_count: i64 = token_batch.comments.count.i64()
    file: Ast::File = frontend_parser_parse_file(src, token_batch.tokens)
    table: Semantic::SymbolTable = Semantic::check(file)
    # Contract facts the rest of the server relies on.
    v: i64 = frontend_contract_version()
    param_kind: i64 = occurrence_kind_at(table, 1, "p")
    local_kind: i64 = occurrence_kind_at(table, 2, "local")
    missing_kind: i64 = occurrence_kind_at(table, 1, "no_such_name")
    f: i64 = symbol_index_of(table, "f")
    scount: usize = symbol_count(table)
    variant_count: usize = enum_variant_count(table)
    variant_accessors_ok: mutable i64 = 0
    variant_accessors_ok <- 1 if variant_count == 1 and enum_variant_owner(table, 0) == "Color" and enum_variant_name(table, 0) == "Red"
    dcount: usize = diagnostic_count(table)
    has_f: mutable i64 = 1
    has_f <- 0 if f >= 0
    has_syms: mutable i64 = 0
    has_syms <- 1 if scount > 0
    clean: mutable i64 = 0
    clean <- 1 if dcount == 0
    table_valid: mutable i64 = 0
    table_valid <- 1 if frontend_table_valid(table, src, len, file.errors)
    snapshot_occurrences: mutable darray[Ast::Pos] = []
    snapshot_occurrences_valid: bool = frontend_occurrence_positions(table, token_batch.tokens, src, len, snapshot_occurrences)
    snapshot_completeness: mutable LspFrontendCompleteness = LspFrontendCompleteness.Rejected
    snapshot_completeness <- LspFrontendCompleteness.Recovered if table_valid != 0 and snapshot_occurrences_valid and file.errors.count > 0
    snapshot_completeness <- LspFrontendCompleteness.Complete if table_valid != 0 and snapshot_occurrences_valid and file.errors.count == 0
    frontend_snapshot: LspFrontendAnalysisSnapshot = LspFrontendAnalysisSnapshot{
        contract_version: v, source_len: len, token_batch: token_batch,
        syntax: file, semantic: table, symbols: table.symbols,
        diagnostics: table.diagnostics, occurrences: snapshot_occurrences,
        completeness: snapshot_completeness
    }
    clean <- 0 if not frontend_analysis_snapshot_valid(frontend_snapshot, len)
    symbol_identity_rows_ok: mutable i64 = 1
    symbol_identity_index: mutable usize = 0
    while symbol_identity_index < table.symbols.count:
        symbol_identity_rows_ok <- 0 if symbol_declaration_id(table, symbol_identity_index) != symbol_identity_index.i64()
        symbol_identity_index <- symbol_identity_index + 1
    symbol_identity_rows_ok <- 0 if symbol_declaration_id(table, table.symbols.count) != -1
    snapshot_invariants_ok: mutable i64 = 1
    clean_symbol_state: LspFrontendAnalysisSnapshot = LspFrontendAnalysisSnapshot{
        contract_version: v, source_len: len, token_batch: token_batch,
        syntax: file, semantic: table, symbols: table.symbols,
        diagnostics: table.diagnostics, occurrences: snapshot_occurrences,
        completeness: LspFrontendCompleteness.Recovered
    }
    snapshot_invariants_ok <- 0 if frontend_analysis_snapshot_valid(clean_symbol_state, len)
    clean_sidecar_mismatch: LspFrontendAnalysisSnapshot = LspFrontendAnalysisSnapshot{
        contract_version: v, source_len: len, token_batch: token_batch,
        syntax: file, semantic: table, symbols: [],
        diagnostics: table.diagnostics, occurrences: snapshot_occurrences,
        completeness: LspFrontendCompleteness.Complete
    }
    snapshot_invariants_ok <- 0 if table.symbols.count > 0 and frontend_analysis_snapshot_valid(clean_sidecar_mismatch, len)
    table.ref_name.push("extra")
    ref_shape_rejected: mutable i64 = 0
    ref_shape_rejected <- 1 if not frontend_table_valid(table, src, len, file.errors)
    table.ref_name.truncate(table.ref_line.count)
    original_ref_position_count: usize = table.ref_pos.count
    table.ref_pos.push(Ast::Pos{line: 0, column: 0, offset: 0, end_line: 0, end_column: 0, end_offset: 0})
    ref_pos_shape_rejected: mutable i64 = 0
    ref_pos_shape_rejected <- 1 if not frontend_table_valid(table, src, len, file.errors)
    table.ref_pos.truncate(original_ref_position_count)
    parameter_row: mutable usize = 0
    parameter_row_found: mutable bool = false
    for row in 0..<table.ref_line.count |row, parameter_row, parameter_row_found, table|:
        if table.ref_kind[row] == 1 and string_views_eq(table.ref_name[row], "p") != 0:
            parameter_row <- row
            parameter_row_found <- true
            break
    original_ref_position: Ast::Pos = table.ref_pos[parameter_row]
    table.ref_pos[parameter_row] <- Ast::Pos{line: 1, column: 5, offset: 4, end_line: 1, end_column: 6, end_offset: 5}
    bad_ref_position_rejected: mutable i64 = 0
    bad_ref_position_rejected <- 1 if parameter_row_found and not frontend_table_valid(table, src, len, file.errors)
    table.ref_pos[parameter_row] <- original_ref_position
    table.enum_variant_owner.push("broken")
    enum_shape_rejected: mutable i64 = 0
    enum_shape_rejected <- 1 if not frontend_table_valid(table, src, len, file.errors)
    table.enum_variant_owner.truncate(table.enum_variant_name.count)
    original_variant_owner: sview = enum_variant_owner(table, 0)
    original_variant_name: sview = enum_variant_name(table, 0)
    variant_contents_rejected: mutable i64 = 0
    table.enum_variant_owner[0] <- ""
    variant_contents_rejected <- 1 if not frontend_table_valid(table, src, len, file.errors)
    table.enum_variant_owner[0] <- original_variant_owner
    table.enum_variant_name[0] <- ""
    variant_contents_rejected <- 0 if frontend_table_valid(table, src, len, file.errors)
    table.enum_variant_name[0] <- original_variant_name
    table.type_alias_name.push("broken")
    alias_shape_rejected: mutable i64 = 0
    alias_shape_rejected <- 1 if not frontend_table_valid(table, src, len, file.errors)
    table.type_alias_name.truncate(table.type_alias_target.count)
    nav_text: cstr = "def target() -> i64:\n    return 7\ndef caller(π: i64) -> i64:\n    return π + target()\ndef shadow(target: i64) -> i64:\n    return target\n"
    nav_buf: mutable darray[u8] = []
    nav_buf.extend(sview(nav_text, 0, -1))
    nav_buf.push(0)
    nav_src: u8& = &nav_buf[0]
    nav_len: usize = nav_buf.count - 1
    nav_tokens: darray[Token] = Lexer::frontend_tokenize_with_length(nav_src, nav_src, nav_len)
    nav_file: Ast::File = frontend_parser_parse_file(nav_src, nav_tokens)
    nav_table: Semantic::SymbolTable = Semantic::check(nav_file)
    nav_table_valid: mutable i64 = 0
    nav_table_valid <- 1 if frontend_table_valid(nav_table, nav_src, nav_len, nav_file.errors)
    nav_target_index: i64 = symbol_index_of(nav_table, "target")
    symbol_identity_rows_ok <- 0 if symbol_declaration_id(nav_table, nav_target_index.usize()) != nav_target_index
    symbol_identity_rows_ok <- 0 if symbol_declaration_id(nav_table, nav_target_index.usize()) != definition_reference_symbol_index(nav_table, 0).i64()
    nav_target_pos: Ast::Pos = symbol_name_position(nav_table, nav_target_index.usize())
    adapter_getters_ok: mutable i64 = 0
    adapter_getters_ok <- 1 if symbol_category(nav_table, nav_target_index.usize()) == SYMBOL_KIND_FUNCTION and symbol_name(nav_table, nav_target_index.usize()) == "target" and symbol_source_line(nav_table, nav_target_index.usize()) == 1 and symbol_source_offset(nav_table, nav_target_index.usize()) == 0 and not has_module_or_import_context(nav_table) and definition_reference_symbol_index(nav_table, 0) == nav_target_index.usize()
    nav_reference_pos: Ast::Pos = definition_reference_position(nav_table, 0)
    nav_edge_target_pos: Ast::Pos = definition_reference_target_position(nav_table, 0)
    nav_declaration_pos: Ast::Pos = definition_reference_position(nav_table, 1)
    nav_declaration_target_pos: Ast::Pos = definition_reference_target_position(nav_table, 1)
    nav_target_name_ok: mutable i64 = 0
    nav_target_name_ok <- 1 if string_views_eq(definition_reference_target_name(nav_table, 0), "target") != 0
    nav_self_edge_ok: mutable i64 = 0
    nav_self_edge_ok <- 1 if nav_declaration_pos.offset == nav_target_pos.offset and nav_declaration_pos.end_offset == nav_target_pos.end_offset and nav_declaration_target_pos.offset == nav_target_pos.offset and nav_declaration_target_pos.end_offset == nav_target_pos.end_offset
    original_target_index: u32 = nav_table.definition_references[0].declaration_id.value
    original_edge_count: usize = nav_table.definition_references.count
    nav_table.definition_references.push(Semantic::DefinitionReference{pos: nav_reference_pos, declaration_id: Semantic::DeclId{value: 4294967295.u32()}})
    bad_target_rejected: mutable i64 = 0
    bad_target_rejected <- 1 if not frontend_table_valid(nav_table, nav_src, nav_len, nav_file.errors)
    nav_table.definition_references.truncate(original_edge_count)
    bad_pos: Ast::Pos = Ast::Pos{line: nav_reference_pos.line, column: nav_reference_pos.column, offset: nav_reference_pos.offset, end_line: nav_reference_pos.end_line, end_column: nav_reference_pos.end_column, end_offset: nav_len.u32() + 1}
    original_symbol_count: usize = nav_table.symbols.count
    bad_symbol: Semantic::Symbol = Semantic::Symbol{name: "broken", kind: Semantic::SymbolKind.Func, line: 1, name_pos: bad_pos, id: Semantic::DeclId{value: original_symbol_count.u32()}, offset: 0, arity_min: 0, arity_max: 0, return_type: "", return_type_id: 0}
    nav_table.symbols.push(bad_symbol)
    bad_symbol_span_rejected: mutable i64 = 0
    bad_symbol_span_rejected <- 1 if not frontend_table_valid(nav_table, nav_src, nav_len, nav_file.errors)
    nav_table.symbols.truncate(original_symbol_count)
    bad_symbol_id: Semantic::Symbol = Semantic::Symbol{name: "broken", kind: Semantic::SymbolKind.Func, line: 1, name_pos: nav_target_pos, id: Semantic::DeclId{value: 0}, offset: 0, arity_min: 0, arity_max: 0, return_type: "", return_type_id: 0}
    nav_table.symbols.push(bad_symbol_id)
    bad_symbol_id_rejected: mutable i64 = 0
    bad_symbol_id_rejected <- 1 if not frontend_table_valid(nav_table, nav_src, nav_len, nav_file.errors)
    nav_table.symbols.truncate(original_symbol_count)
    nav_table.definition_references.push(Semantic::DefinitionReference{pos: bad_pos, declaration_id: Semantic::DeclId{value: original_target_index}})
    bad_edge_span_rejected: mutable i64 = 0
    bad_edge_span_rejected <- 1 if not frontend_table_valid(nav_table, nav_src, nav_len, nav_file.errors)
    recovery_text: cstr = "def\n"
    recovery_buf: mutable darray[u8] = []
    recovery_buf.extend(sview(recovery_text, 0, -1))
    recovery_buf.push(0)
    recovery_src: u8& = &recovery_buf[0]
    recovery_len: usize = recovery_buf.count - 1
    recovery_batch: LspFrontendTokenBatch = tokenize_frontend_source(recovery_src, recovery_len)
    recovery_file: Ast::File = frontend_parser_parse_file(recovery_src, recovery_batch.tokens)
    recovery_table: Semantic::SymbolTable = Semantic::check(recovery_file)
    recovery_occurrences: mutable darray[Ast::Pos] = []
    recovery_occurrences_valid: bool = frontend_occurrence_positions(recovery_table, recovery_batch.tokens, recovery_src, recovery_len, recovery_occurrences)
    recovery_completeness: mutable LspFrontendCompleteness = LspFrontendCompleteness.Rejected
    recovery_completeness <- LspFrontendCompleteness.Recovered if recovery_file.errors.count > 0 and recovery_occurrences_valid and frontend_table_valid(recovery_table, recovery_src, recovery_len, recovery_file.errors)
    recovery_snapshot: LspFrontendAnalysisSnapshot = LspFrontendAnalysisSnapshot{
        contract_version: v, source_len: recovery_len, token_batch: recovery_batch,
        syntax: recovery_file, semantic: recovery_table, symbols: recovery_table.symbols,
        diagnostics: recovery_table.diagnostics, occurrences: recovery_occurrences,
        completeness: recovery_completeness
    }
    recovered_missing_ident_ok: mutable i64 = 0
    recovered_missing_ident_ok <- 1 if frontend_analysis_snapshot_valid(recovery_snapshot, recovery_len) and recovery_snapshot.completeness == LspFrontendCompleteness.Recovered and recovery_snapshot.syntax.errors.count > 0 and recovery_snapshot.diagnostics.count > 0
    recovery_complete_state: LspFrontendAnalysisSnapshot = LspFrontendAnalysisSnapshot{
        contract_version: v, source_len: recovery_len, token_batch: recovery_batch,
        syntax: recovery_file, semantic: recovery_table, symbols: recovery_table.symbols,
        diagnostics: recovery_table.diagnostics, occurrences: recovery_occurrences,
        completeness: LspFrontendCompleteness.Complete
    }
    snapshot_invariants_ok <- 0 if frontend_analysis_snapshot_valid(recovery_complete_state, recovery_len)
    recovery_sidecar_mismatch: LspFrontendAnalysisSnapshot = LspFrontendAnalysisSnapshot{
        contract_version: v, source_len: recovery_len, token_batch: recovery_batch,
        syntax: recovery_file, semantic: recovery_table, symbols: recovery_table.symbols,
        diagnostics: [], occurrences: recovery_occurrences,
        completeness: LspFrontendCompleteness.Recovered
    }
    snapshot_invariants_ok <- 0 if recovery_table.diagnostics.count > 0 and frontend_analysis_snapshot_valid(recovery_sidecar_mismatch, recovery_len)
    recovery_bad_pos: Ast::Pos = Ast::Pos{line: 1, column: 1, offset: 0, end_line: 1, end_column: 1, end_offset: recovery_len.u32() + 1}
    recovery_table.definition_references.push(Semantic::DefinitionReference{pos: recovery_bad_pos, declaration_id: Semantic::DeclId{value: 0}})
    malformed_edge_with_parse_error_rejected: mutable i64 = 0
    malformed_edge_with_parse_error_rejected <- 1 if not frontend_table_valid(recovery_table, recovery_src, recovery_len, recovery_file.errors)
    nav_table.definition_references.truncate(original_edge_count)
    shadow_text: cstr = "def shadow(p: i64) -> i64:\n    p: i64 = p\n    return p\n"
    shadow_buf: mutable darray[u8] = []
    shadow_buf.extend(sview(shadow_text, 0, -1))
    shadow_buf.push(0)
    shadow_src: u8& = &shadow_buf[0]
    shadow_len: usize = shadow_buf.count - 1
    shadow_tokens: darray[Token] = Lexer::frontend_tokenize_with_length(shadow_src, shadow_src, shadow_len)
    shadow_file: Ast::File = frontend_parser_parse_file(shadow_src, shadow_tokens)
    shadow_table: Semantic::SymbolTable = Semantic::check(shadow_file)
    shadow_positions: mutable darray[Ast::Pos] = []
    shadow_valid: mutable i64 = 0
    shadow_valid <- 1 if frontend_table_valid(shadow_table, shadow_src, shadow_len, shadow_file.errors) and frontend_occurrence_positions(shadow_table, shadow_tokens, shadow_src, shadow_len, shadow_positions)
    shadow_heads: mutable dict[i64, i64] = {}
    shadow_next: mutable darray[i64] = []
    occurrence_index_build(shadow_table, shadow_positions, shadow_heads, shadow_next)
    shadow_local_offset: mutable u32 = 0
    shadow_param_offset: mutable u32 = 0
    shadow_local_serial: mutable u64 = 0
    shadow_param_serial: mutable u64 = 0
    shadow_exact_rows_ok: mutable i64 = 1
    for shadow_index in 0..<occurrence_count(shadow_table) |shadow_index, shadow_table, shadow_local_offset, shadow_param_offset, shadow_local_serial, shadow_param_serial|:
        shadow_pos: Ast::Pos = occurrence_position(shadow_positions, shadow_index)
        compiler_pos: Ast::Pos = shadow_table.ref_pos[shadow_index]
        shadow_exact_rows_ok <- 0 if shadow_pos.offset != compiler_pos.offset or shadow_pos.end_offset != compiler_pos.end_offset or compiler_pos.end_offset <= compiler_pos.offset
        if occurrence_line(shadow_table, shadow_index) == 2 and occurrence_name(shadow_table, shadow_index) == "p":
            if occurrence_kind_index(shadow_table, shadow_index) == OCC_LOCAL:
                shadow_local_offset <- shadow_pos.offset
                shadow_local_serial <- occurrence_binding_serial(shadow_table, shadow_index)
            elif occurrence_kind_index(shadow_table, shadow_index) == OCC_PARAM:
                shadow_param_offset <- shadow_pos.offset
                shadow_param_serial <- occurrence_binding_serial(shadow_table, shadow_index)
    shadow_exact_ok: mutable i64 = 0
    shadow_exact_ok <- 1 if shadow_local_offset > 0 and shadow_param_offset > 0 and shadow_local_offset != shadow_param_offset and occurrence_kind_indexed(shadow_table, shadow_positions, shadow_heads, shadow_next, shadow_local_offset, "p") == OCC_LOCAL and occurrence_kind_indexed(shadow_table, shadow_positions, shadow_heads, shadow_next, shadow_param_offset, "p") == OCC_PARAM and shadow_local_serial != shadow_param_serial
    loop_text: cstr = "def each(xs: darray[i64]) -> i64:\n    for item in xs:\n        return item\n    return 0\n"
    loop_buf: mutable darray[u8] = []
    loop_buf.extend(sview(loop_text, 0, -1))
    loop_buf.push(0)
    loop_src: u8& = &loop_buf[0]
    loop_len: usize = loop_buf.count - 1
    loop_tokens: darray[Token] = Lexer::frontend_tokenize_with_length(loop_src, loop_src, loop_len)
    loop_file: Ast::File = frontend_parser_parse_file(loop_src, loop_tokens)
    loop_table: Semantic::SymbolTable = Semantic::check(loop_file)
    loop_positions: mutable darray[Ast::Pos] = []
    loop_exact_rows_ok: mutable i64 = 0
    loop_exact_rows_ok <- 1 if frontend_table_valid(loop_table, loop_src, loop_len, loop_file.errors) and frontend_occurrence_positions(loop_table, loop_tokens, loop_src, loop_len, loop_positions)
    loop_binder_found: mutable bool = false
    for loop_row in 0..<occurrence_count(loop_table) |loop_row, loop_table, loop_positions, loop_binder_found|:
        loop_pos: Ast::Pos = occurrence_position(loop_positions, loop_row)
        compiler_loop_pos: Ast::Pos = loop_table.ref_pos[loop_row]
        loop_exact_rows_ok <- 0 if loop_pos.offset != compiler_loop_pos.offset or loop_pos.end_offset != compiler_loop_pos.end_offset or compiler_loop_pos.end_offset <= compiler_loop_pos.offset
        loop_binder_found <- true if loop_table.ref_line[loop_row] == 2 and loop_table.ref_name[loop_row] == "item" and loop_pos.end_offset > loop_pos.offset
    loop_exact_rows_ok <- 0 if not loop_binder_found
    changes_text: cstr = "def changes_header(current: i64, changes: i64) -> i64 can[Abort.Panic]:\n    return current + changes\n"
    changes_buf: mutable darray[u8] = []
    changes_buf.extend(sview(changes_text, 0, -1))
    changes_buf.push(0)
    changes_src: u8& = &changes_buf[0]
    changes_len: usize = changes_buf.count - 1
    changes_tokens: darray[Token] = Lexer::frontend_tokenize_with_length(changes_src, changes_src, changes_len)
    changes_file: Ast::File = frontend_parser_parse_file(changes_src, changes_tokens)
    changes_table: Semantic::SymbolTable = Semantic::check(changes_file)
    changes_header_ok: mutable i64 = 0
    changes_header_ok <- 1 if frontend_table_valid(changes_table, changes_src, changes_len, changes_file.errors) and diagnostic_count(changes_table) == 0
    zero_start_pos: Ast::Pos = Ast::Pos{line: 1, column: 1, offset: 0, end_line: 1, end_column: 2, end_offset: 1}
    zero_start_offset_valid: mutable i64 = 0
    zero_start_offset_valid <- 1 if frontend_offsets_valid(zero_start_pos, nav_len)
    default_pos: Ast::Pos = Ast::Pos{line: 0, column: 0, offset: 0, end_line: 0, end_column: 0, end_offset: 0}
    default_offsets_absent: mutable i64 = 0
    default_offsets_absent <- 1 if not frontend_offsets_valid(default_pos, nav_len)
    reversed_pos: Ast::Pos = Ast::Pos{line: 1, column: 2, offset: 1, end_line: 1, end_column: 1, end_offset: 0}
    reversed_offsets_rejected: mutable i64 = 0
    reversed_offsets_rejected <- 1 if not frontend_offsets_valid(reversed_pos, nav_len)
    out_of_source_pos: Ast::Pos = Ast::Pos{line: 1, column: 1, offset: 0, end_line: 1, end_column: 2, end_offset: nav_len.u32() + 1}
    out_of_source_offsets_rejected: mutable i64 = 0
    out_of_source_offsets_rejected <- 1 if not frontend_offsets_valid(out_of_source_pos, nav_len)
    exact_end_pos: Ast::Pos = Ast::Pos{line: 1, column: 1, offset: nav_len.u32() - 1, end_line: 1, end_column: 2, end_offset: nav_len.u32()}
    exact_source_end_valid: mutable i64 = 0
    exact_source_end_valid <- 1 if frontend_offsets_valid(exact_end_pos, nav_len)
    print(v)
    print(comment_count)
    print(shadow_valid)
    print(shadow_exact_ok)
    print(shadow_exact_rows_ok)
    print(loop_exact_rows_ok)
    print(changes_header_ok)
    print(param_kind)
    print(local_kind)
    print(missing_kind)
    print(has_f)
    print(has_syms)
    print(clean)
    print(symbol_identity_rows_ok)
    print(definition_reference_count(nav_table).i64())
    print(nav_target_pos.offset.i64())
    print(nav_target_pos.end_offset.i64())
    print(nav_reference_pos.offset.i64())
    print(nav_reference_pos.end_offset.i64())
    print(nav_target_name_ok)
    print(nav_declaration_pos.offset.i64())
    print(nav_declaration_pos.end_offset.i64())
    print(nav_self_edge_ok)
    print(table_valid)
    print(ref_shape_rejected)
    print(ref_pos_shape_rejected)
    print(bad_ref_position_rejected)
    print(enum_shape_rejected)
    print(alias_shape_rejected)
    print(nav_table_valid)
    print(bad_target_rejected)
    print(bad_symbol_span_rejected)
    print(bad_symbol_id_rejected)
    print(bad_edge_span_rejected)
    print(adapter_getters_ok)
    print(recovered_missing_ident_ok)
    print(snapshot_invariants_ok)
    print(malformed_edge_with_parse_error_rejected)
    print(zero_start_offset_valid)
    print(default_offsets_absent)
    print(reversed_offsets_rejected)
    print(out_of_source_offsets_rejected)
    print(exact_source_end_valid)
    print(variant_accessors_ok)
    print(variant_contents_rejected)
    line_only_occurrence_sentinel: Ast::Pos = Ast::Pos{line: 1, column: 0, offset: 0, end_line: 1, end_column: 0, end_offset: 0}
    line_only_occurrence_accepted: mutable i64 = 0
    line_only_occurrence_accepted <- 1 if frontend_occurrence_row_position_valid(line_only_occurrence_sentinel, 1, "synthetic", src, len)
    mismatched_line_only_occurrence_rejected: mutable i64 = 0
    mismatched_line_only_occurrence_rejected <- 1 if not frontend_occurrence_row_position_valid(line_only_occurrence_sentinel, 2, "synthetic", src, len)
    print(line_only_occurrence_accepted)
    print(mismatched_line_only_occurrence_rejected)
    return 0
EOF

# The probe checks frontend API contracts, not generated-code performance. Keep
# this full-semantic fixture at O0 so the compiler upgrade gate can run it
# without spending several minutes optimizing test-only code.
compile_log="$("$ELISAC" -emit obj -O0 -o "$WORK/probe.o" "$WORK/Elisa-LSP/probe.elisa" 2>&1)" || {
  # Distinguish "the adapter contract broke" from "the frontend checkout does
  # not compile" (external compiler-repo drift, out of this repo's scope).
  if grep -q "frontend_adapter.elisa" <<<"$compile_log"; then
    echo "frontend contract FAILED: adapter no longer matches the frontend surface" >&2
    grep -E "frontend_adapter\.elisa" <<<"$compile_log" | head -n 10 >&2
    exit 1
  fi
  if grep -Eq "$COMPILER_ROOT/src/.*:.*error:" <<<"$compile_log"; then
    echo "frontend contract SKIP: frontend checkout does not compile with the pinned compiler" >&2
    echo "  (external drift; adapter is still compiled by build.sh, so build.sh is the gate)" >&2
    grep -E "^.*: error|is a namespace|undefined identifier" <<<"$compile_log" | head -n 5 >&2 || true
    exit 0
  fi
  echo "frontend contract FAILED: contract probe does not compile" >&2
  tail -n 25 <<<"$compile_log" >&2
  exit 1
}

cat > "$WORK/fallback.c" <<'EOF'
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__) || defined(__clang__)
#define ELISA_WEAK __attribute__((weak))
#else
#define ELISA_WEAK
#endif
ELISA_WEAK uint32_t elisa_profile_allocation_negotiate(uint32_t version) { (void)version; return 0; }
ELISA_WEAK uint32_t elisa_profile_region_layout_negotiate(uint32_t version) { (void)version; return 0; }
ELISA_WEAK void elisa_profile_region_layout_v1(uintptr_t a,size_t b,uintptr_t c,uintptr_t d,size_t e){(void)a;(void)b;(void)c;(void)d;(void)e;}
ELISA_WEAK int64_t elisa_lsp_monotonic_millis(void) { return 0; }
ELISA_WEAK void elisa_profile_allocation_event_v1(uint32_t a,uintptr_t b,size_t c,uintptr_t d,size_t e,uintptr_t f,size_t g){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;}
/* The stage0-generated object contains weak native-callback and varargs
 * fallbacks even though this probe never calls them. Keep the fixture link
 * contract aligned with build.sh on ELF linkers that retain those sections. */
ELISA_WEAK void *elisa_native_callback_ptr(uint8_t *name) { (void)name; return NULL; }
ELISA_WEAK uint32_t elisa_native_callback_call_u32_voidp(uint8_t *name, void *arg, uint32_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK int32_t elisa_native_callback_call_i32_voidp(uint8_t *name, void *arg, int32_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK uintptr_t elisa_native_callback_call_usize_voidp(uint8_t *name, void *arg, uintptr_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK intptr_t elisa_native_callback_call_isize_voidp(uint8_t *name, void *arg, intptr_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK uint32_t elisa_native_callback_spawn_join_u32_voidp(uint8_t *name, void *arg, uint32_t fallback) { (void)name; (void)arg; return fallback; }
ELISA_WEAK void *elisa_native_callback_context_new_u32_voidp(uint8_t *name, void *arg, uint32_t fallback) { (void)name; (void)arg; (void)fallback; return NULL; }
ELISA_WEAK void *elisa_native_callback_context_entry_u32_voidp(void) { return NULL; }
ELISA_WEAK int32_t elisa_native_callback_context_start_u32_voidp(void *ctx, uintptr_t *thread) { (void)ctx; (void)thread; return -1; }
ELISA_WEAK uint32_t elisa_native_callback_context_join_u32_voidp(uintptr_t handle, void *ctx, uint32_t fallback) { (void)handle; (void)ctx; return fallback; }
ELISA_WEAK uint32_t elisa_native_callback_context_spawn_join_u32_voidp(void *ctx, uint32_t fallback) { (void)ctx; return fallback; }
ELISA_WEAK uint32_t elisa_native_callback_context_result_u32(void *ctx, uint32_t fallback) { (void)ctx; return fallback; }
ELISA_WEAK void elisa_native_callback_context_free(void *ctx) { (void)ctx; }
ELISA_WEAK void *va_copy(void *source) { return source; }
ELISA_WEAK void va_end(void *argument) { (void)argument; }
EOF
if [[ "$(uname -s)" == Darwin ]]; then
  DEAD_STRIP_FLAG=-Wl,-dead_strip
else
  # GNU ld and lld use ELF section-garbage-collection spelling. The probe does
  # not depend on dead stripping, but keep equivalent cleanup behavior on Linux.
  DEAD_STRIP_FLAG=-Wl,--gc-sections
fi
clang -O2 -fno-builtin "$DEAD_STRIP_FLAG" -o "$WORK/run" "$WORK/probe.o" "$WORK/fallback.c"

cat > "$WORK/startup_canary.c" <<'EOF'
int main(void) { return 0; }
EOF
clang -O2 -fno-builtin -o "$WORK/startup_canary" "$WORK/startup_canary.c"

python3 - "$WORK/startup_canary" "$WORK/run" <<'PY'
import subprocess
import sys

def run_isolated(path, timeout):
    # Launch each binary in its own session so timeout cleanup can reap the
    # complete process group, matching the LSP harness's process isolation.
    proc = subprocess.Popen(
        [path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=(sys.platform != "win32"),
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        if sys.platform != "win32":
            import os
            import signal
            os.killpg(proc.pid, signal.SIGKILL)
        else:
            proc.kill()
        stdout, stderr = proc.communicate()
        return None, stdout, stderr
    return proc.returncode, stdout, stderr

try:
    canary_returncode, _, _ = run_isolated(sys.argv[1], timeout=5)
except OSError:
    canary_returncode = None
if canary_returncode is None or canary_returncode != 0:
    print("frontend contract SKIP: host cannot start linked executables", file=sys.stderr)
    raise SystemExit(0)

# A malformed frontend-table probe must never be able to hang the canonical
# suite indefinitely; keep the runtime regression check bounded at 30 seconds.
try:
    returncode, stdout, stderr = run_isolated(sys.argv[2], timeout=30)
except OSError as exc:
    print(f"frontend contract FAILED: could not start probe: {exc}", file=sys.stderr)
    raise SystemExit(1)
if returncode is None:
    print("frontend contract FAILED: probe execution exceeded 30 seconds", file=sys.stderr)
    print("probe output before timeout:", repr(stdout), file=sys.stderr)
    if stderr:
        print(stderr[-4000:], file=sys.stderr)
    raise SystemExit(1)
if returncode != 0:
    print(f"frontend contract FAILED: probe exited {returncode}", file=sys.stderr)
    if stderr:
        print(stderr[-4000:], file=sys.stderr)
    raise SystemExit(1)
if stderr:
    print(f"frontend contract FAILED: unexpected stderr: {stderr[-4000:]}", file=sys.stderr)
    raise SystemExit(1)
got = " ".join(stdout.split())
# version=13, comment-side-channel ownership, exact compiler/adapter occurrence spans and same-line shadow identities, line-only missing-span hints, existing adapter facts, exact navigation spans, alias-shape and
# fail-closed checks
# for malformed snapshots, a narrow missing-function-name recovery case, and
# consistency between parser errors, completeness state, and sidecar counts.
want = "13 1 1 1 1 1 1 1 2 -1 0 1 1 1 4 4 10 78 84 1 4 10 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1"
if got != want:
    print(f"frontend contract FAILED: got [{got}] want [{want}]", file=sys.stderr)
    raise SystemExit(1)
PY
echo "frontend contract OK: v13; lexer comment side channel, exact compiler occurrence positions/identities, line-only missing-span hints, enum variant accessors, array shapes, alias metadata, navigation spans, parser recovery, and diagnostic offset boundaries"
