#!/usr/bin/env bash
# B03: compiler-rejected language spellings and deliberately unsupported LSP
# provider constructs are kept in separate, provenance-checked inventories.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ELISAC="${ELISAC:-$HOME/.elisac/elisac-stage0}"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-$ROOT/../Elisa-compiler}"

[[ -x "$ELISAC" ]] || { echo "error: no compiler at $ELISAC (set ELISAC)" >&2; exit 2; }
[[ -d "$COMPILER_ROOT/src/semantic" ]] || {
  echo "error: compiler checkout not found at $COMPILER_ROOT (set ELISA_COMPILER_ROOT)" >&2
  exit 2
}

python3 - "$ROOT" "$ELISAC" "$COMPILER_ROOT" <<'PY'
import json
import pathlib
import platform
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
elisac = pathlib.Path(sys.argv[2]).resolve()
compiler_root = pathlib.Path(sys.argv[3]).resolve()
inventory_path = root / "docs" / "unsupported-constructs.json"
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))

assert inventory.get("schema_version") == 1
assert inventory.get("inventory") == "elisa-lsp-language-construct-support"
compiler = inventory.get("compiler")
assert isinstance(compiler, dict)
assert compiler.get("frontend_root_env") == "ELISA_COMPILER_ROOT"
assert compiler.get("backend_binary_env") == "ELISAC"
assert compiler.get("backend_kind") == "stage0"

sys.path.insert(0, str(root))
from scripts.build_hashes import compiler_sources_sha256, sha256_file

expected_frontend_hash = compiler.get("frontend_sources_sha256")
actual_frontend_hash = compiler_sources_sha256(compiler_root)
assert actual_frontend_hash == expected_frontend_hash, (
    "unsupported-construct inventory is stale for the selected compiler frontend: "
    f"expected {expected_frontend_hash}, got {actual_frontend_hash}; "
    "rerun the compiler audit before changing support claims"
)

backend_hashes = compiler.get("backend_sha256_by_target")
assert isinstance(backend_hashes, dict), "inventory has no per-target stage0 compiler hashes"
target = f"{platform.system()}/{platform.machine()}"
expected_backend_hash = backend_hashes.get(target)
assert isinstance(expected_backend_hash, str) and expected_backend_hash, (
    f"unsupported-construct inventory has no stage0 compiler hash for {target}"
)
actual_backend_hash = sha256_file(elisac)
assert actual_backend_hash == expected_backend_hash, (
    "unsupported-construct inventory was verified with a different compiler binary: "
    f"expected {expected_backend_hash}, got {actual_backend_hash}; "
    "rerun the compiler audit with the current pinned compiler"
)

# When a fresh release manifest is present, ensure this focused audit uses the
# same frontend snapshot and backend binary as the server test suite. This
# prevents an isolated test from silently proving behavior on an older compiler.
build_manifest_path = root / "build" / "manifest.json"
if build_manifest_path.is_file():
    build_manifest = json.loads(build_manifest_path.read_text(encoding="utf-8"))
    assert build_manifest.get("compiler_sources_sha256") == expected_frontend_hash, (
        "build manifest and unsupported-construct inventory use different compiler sources"
    )
    assert build_manifest.get("elisac_sha256") == actual_backend_hash, (
        "build manifest and unsupported-construct inventory use different ELISAC binaries"
    )
    manifest_compiler = pathlib.Path(str(build_manifest.get("elisac", ""))).resolve()
    assert manifest_compiler == elisac, (
        f"test compiler {elisac} is not the compiler pinned by build manifest {manifest_compiler}"
    )


def check_paths(entries, field, base, label):
    for entry in entries:
        values = entry.get(field, [])
        assert isinstance(values, list) and values, f"{entry.get('id')} has no {field}"
        for relative in values:
            assert isinstance(relative, str) and relative and not pathlib.PurePath(relative).is_absolute(), (
                f"{entry.get('id')} has an invalid {label} path {relative!r}"
            )
            path = base / relative
            assert path.is_file(), f"{entry.get('id')} references missing {label} {path}"


compiler_entries = inventory.get("compiler_rejected")
provider_entries = inventory.get("lsp_provider_limits")
assert isinstance(compiler_entries, list) and compiler_entries
assert isinstance(provider_entries, list) and provider_entries
entries = compiler_entries + provider_entries
ids = [entry.get("id") for entry in entries]
assert all(isinstance(identifier, str) and identifier for identifier in ids)
assert len(ids) == len(set(ids)), f"duplicate inventory IDs: {ids}"

check_paths(compiler_entries, "source_refs", compiler_root, "compiler source")
for entry in provider_entries:
    check_paths([entry], "compiler_source_refs", compiler_root, "compiler source")
    check_paths([entry], "lsp_source_refs", root, "LSP source")
    check_paths([entry], "tests", root, "test")

assert all(
    entry.get("compiler_status") in {"rejected_removed", "rejected_syntax"}
    and entry.get("lsp_status") == "diagnostic_passthrough"
    for entry in compiler_entries
)
assert all(
    entry.get("compiler_status") == "accepted"
    and entry.get("lsp_status") in {"unsupported", "partial"}
    and isinstance(entry.get("providers"), list)
    and entry["providers"]
    for entry in provider_entries
)


def run_probe(entry, probe, label):
    assert isinstance(probe, dict), f"{entry['id']} {label} probe is not an object"
    source = probe.get("source")
    fragment = probe.get("message_fragment")
    assert isinstance(source, str) and source, f"{entry['id']} {label} probe has no source"
    assert isinstance(fragment, str) and fragment, f"{entry['id']} {label} probe has no message fragment"
    with tempfile.TemporaryDirectory(prefix="elisa-unsupported-") as directory:
        work = pathlib.Path(directory)
        source_path = work / f"{entry['id'].replace('.', '_')}-{label}.elisa"
        object_path = work / "probe.o"
        source_path.write_text(source, encoding="utf-8")
        try:
            result = subprocess.run(
                [str(elisac), "-emit", "obj", "-O0", "-o", str(object_path), str(source_path)],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=20,
            )
        except subprocess.TimeoutExpired as exc:
            raise AssertionError(f"{entry['id']} {label} compiler probe timed out") from exc
        output = result.stdout + result.stderr
        assert result.returncode != 0, (
            f"{entry['id']} {label} was accepted by the pinned compiler; "
            "classify the result as a compiler change before altering LSP claims"
        )
        assert fragment in output, (
            f"{entry['id']} {label} produced a different compiler diagnostic: {output!r}"
        )


probe_count = 0
for entry in compiler_entries:
    run_probe(entry, entry.get("probe"), "primary")
    probe_count += 1
    if entry.get("additional_probe") is not None:
        run_probe(entry, entry["additional_probe"], "additional")
        probe_count += 1

print(
    "unsupported construct inventory OK: "
    f"{len(compiler_entries)} compiler-rejected entries, "
    f"{len(provider_entries)} provider limits, {probe_count} compiler probes, "
    f"frontend {expected_frontend_hash[:12]}, backend {actual_backend_hash[:12]}"
)
PY
