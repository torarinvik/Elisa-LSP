#!/usr/bin/env python3
"""Stable build-input fingerprints shared by the LSP build and its manifest.

The compiler's ``-emit deps-json`` report is the authoritative definition of
the source files consumed by a compilation.  The small recursive parser below
is deliberately kept as a compatibility path for older stage0 binaries (and
for the tiny fake compiler used by the isolated build contract).  Both paths
produce the same normalized logical-path/content records, so callers never
need to duplicate include-graph rules.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Iterable, Set

BUILD_PIPELINE_FILES = ("build.sh", "project.json", "scripts/build_hashes.py", "scripts/generate_diagnostic_codes.py")
STAGE0_REBUILD_RECIPE = (
    "go build -C <stage0-source-root>/compiler "
    "-o <stage0-output>/elisac-stage0 ./src"
)

INCLUDE_CLOSURE_SCHEMA_VERSION = 1
INCLUDE_CLOSURE_DIGEST_TAG = b"elisa-lsp-compiler-include-closure-v1\0"
INCLUDE_DIRECTIVE_RE = re.compile(
    rb"^[ \t]*#?[ \t]*include[ \t]+\"([^\"]*)\"[ \t\r]*$",
    re.MULTILINE,
)


class DependencyClosureError(RuntimeError):
    """A closure cannot be proven safe for the selected source roots."""


class _CompilerDependencyUnavailable(DependencyClosureError):
    """The selected compiler cannot emit a dependency manifest."""


class _CompilerDependencyInvalid(DependencyClosureError):
    """The compiler emitted a malformed or out-of-scope dependency manifest."""


def sha256_file(path: Path) -> str:
    path = Path(path)
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_digest(root: Path, suffixes: Set[str]) -> str:
    digest = hashlib.sha256()
    files = sorted(path for path in root.rglob("*") if path.is_file())
    for path in files:
        if path.suffix not in suffixes:
            continue
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(bytes.fromhex(sha256_file(path)))
    return digest.hexdigest()


def _resolve_file(path: Path, label: str) -> Path:
    """Resolve a source path without allowing a missing or non-file entry."""
    try:
        resolved = Path(path).resolve(strict=True)
    except OSError as exc:
        raise DependencyClosureError(f"cannot resolve {label} {path}: {exc}") from exc
    if not resolved.is_file():
        raise DependencyClosureError(f"{label} is not a regular file: {resolved}")
    return resolved


def _logical_path(path: Path, lsp_root: Path, compiler_root: Path) -> str:
    """Map a compiler-reported absolute path into a portable manifest name."""
    resolved = _resolve_file(path, "dependency")
    lsp_resolved = Path(lsp_root).resolve(strict=True)
    compiler_resolved = Path(compiler_root).resolve(strict=True)
    for prefix, root in (("lsp", lsp_resolved), ("compiler", compiler_resolved)):
        try:
            relative = resolved.relative_to(root)
        except ValueError:
            continue
        if not relative.parts:
            raise _CompilerDependencyInvalid(f"dependency resolves to a source root: {resolved}")
        return prefix + "/" + relative.as_posix()
    raise _CompilerDependencyInvalid(
        f"compiler dependency escapes configured LSP/compiler roots: {resolved}"
    )


def _closure_records(
    paths: Iterable[Path],
    lsp_root: Path,
    compiler_root: Path,
) -> list[dict[str, str]]:
    """Create sorted logical-path/content records and reject duplicate aliases."""
    records: dict[str, dict[str, str]] = {}
    resolved_paths: dict[str, Path] = {}
    for path in paths:
        resolved = _resolve_file(path, "dependency")
        logical = _logical_path(resolved, lsp_root, compiler_root)
        if logical in resolved_paths:
            if resolved_paths[logical] != resolved:
                raise _CompilerDependencyInvalid(
                    f"two physical files map to one logical dependency path: {logical}"
                )
            continue
        resolved_paths[logical] = resolved
        records[logical] = {"path": logical, "sha256": sha256_file(resolved)}
    if not records:
        raise DependencyClosureError("compiler dependency manifest contains no files")
    return [records[key] for key in sorted(records)]


def dependency_closure_sha256(records: Iterable[dict[str, str]]) -> str:
    """Hash normalized dependency paths and their content hashes.

    Sorting is intentional: compiler reports are ordered for diagnostics, but
    the set of paths and their bytes is the identity used for freshness.  A
    changed include directive is still detected because its containing file is
    itself part of the records.
    """
    normalized: list[tuple[str, str]] = []
    for record in records:
        if not isinstance(record, dict):
            raise DependencyClosureError("dependency closure record is not an object")
        logical = record.get("path")
        content_hash = record.get("sha256")
        if (
            not isinstance(logical, str)
            or not logical
            or not isinstance(content_hash, str)
            or len(content_hash) != 64
            or any(character not in "0123456789abcdef" for character in content_hash)
        ):
            raise DependencyClosureError("dependency closure record has an invalid path or SHA-256")
        normalized.append((logical, content_hash))
    normalized.sort()
    if not normalized:
        raise DependencyClosureError("dependency closure contains no files")
    if len({logical for logical, _ in normalized}) != len(normalized):
        raise DependencyClosureError("dependency closure contains duplicate logical paths")
    digest = hashlib.sha256()
    digest.update(INCLUDE_CLOSURE_DIGEST_TAG)
    for logical, content_hash in normalized:
        encoded = logical.encode("utf-8")
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
        digest.update(bytes.fromhex(content_hash))
    return digest.hexdigest()


def dependency_closure_sha256_for_roots(
    lsp_root: Path,
    compiler_root: Path,
    records: Iterable[dict[str, str]],
    *,
    verify_record_hashes: bool = True,
) -> str:
    """Re-hash recorded logical paths against a live or staged source tree."""
    lsp_root = Path(lsp_root).resolve(strict=True)
    compiler_root = Path(compiler_root).resolve(strict=True)
    refreshed: list[dict[str, str]] = []
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise DependencyClosureError("dependency closure record has no logical path")
        logical = record["path"]
        if logical.startswith("lsp/"):
            path = lsp_root / logical.removeprefix("lsp/")
        elif logical.startswith("compiler/"):
            path = compiler_root / logical.removeprefix("compiler/")
        else:
            raise DependencyClosureError(f"dependency closure has unknown logical path: {logical}")
        resolved = _resolve_file(path, "recorded dependency")
        expected_root = lsp_root if logical.startswith("lsp/") else compiler_root
        try:
            resolved.relative_to(expected_root)
        except ValueError as exc:
            raise DependencyClosureError(f"recorded dependency escapes its source root: {logical}") from exc
        content_hash = sha256_file(resolved)
        if verify_record_hashes and content_hash != record.get("sha256"):
            raise DependencyClosureError(f"recorded dependency content changed: {logical}")
        refreshed.append({"path": logical, "sha256": content_hash})
    return dependency_closure_sha256(refreshed)


def _compiler_report_paths(compiler_bin: Path, source_path: Path) -> list[Path]:
    """Ask stage0 for its native include graph, rejecting unsafe reports."""
    try:
        result = subprocess.run(
            [str(compiler_bin), "-emit", "deps-json", str(source_path)],
            cwd=str(source_path.parent),
            check=False,
            capture_output=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise _CompilerDependencyUnavailable(f"compiler dependency report unavailable: {exc}") from exc
    if result.returncode != 0:
        raise _CompilerDependencyUnavailable(
            f"compiler dependency report exited {result.returncode}"
        )
    try:
        output = result.stdout.decode("utf-8")
        payload = json.loads(output)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise _CompilerDependencyUnavailable(
            "compiler dependency report was not valid UTF-8 JSON"
        ) from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("root"), str):
        raise _CompilerDependencyInvalid("compiler dependency report lacks a string root")
    try:
        expected_root = Path(source_path).resolve(strict=True)
        reported_root = Path(payload["root"]).resolve(strict=True)
    except OSError as exc:
        raise _CompilerDependencyInvalid(f"compiler dependency report has an invalid root: {exc}") from exc
    if reported_root != expected_root:
        raise _CompilerDependencyInvalid(
            f"compiler dependency report root {reported_root} does not match {expected_root}"
        )
    reported_files = payload.get("files")
    if not isinstance(reported_files, list) or not reported_files:
        raise _CompilerDependencyInvalid("compiler dependency report lacks a non-empty files list")
    paths: list[Path] = []
    for value in reported_files:
        if not isinstance(value, str) or not value:
            raise _CompilerDependencyInvalid("compiler dependency report contains a non-string path")
        paths.append(Path(value))
    return paths


def _parser_include_paths(source_path: Path) -> list[Path]:
    """Return quoted includes using the compiler's line-oriented grammar."""
    try:
        source = source_path.read_bytes()
    except OSError as exc:
        raise DependencyClosureError(f"cannot read source {source_path}: {exc}") from exc
    paths: list[Path] = []
    for match in INCLUDE_DIRECTIVE_RE.finditer(source):
        try:
            requested = os.fsdecode(match.group(1))
        except UnicodeDecodeError as exc:
            raise DependencyClosureError(f"include path is not decodable in {source_path}: {exc}") from exc
        if not requested:
            raise DependencyClosureError(f"empty include path in {source_path}")
        include_path = Path(requested)
        if not include_path.is_absolute():
            include_path = source_path.parent / include_path
        paths.append(include_path)
    return paths


def _recursive_include_paths(source_path: Path) -> list[Path]:
    """Mirror the compiler's include-once, depth-first traversal for old stage0."""
    ordered: list[Path] = []
    seen: set[Path] = set()
    active: list[Path] = []

    def visit(path: Path) -> None:
        resolved = _resolve_file(path, "included source")
        if resolved in active:
            cycle = " -> ".join(str(item) for item in [*active, resolved])
            raise DependencyClosureError(f"cyclic include in compiler closure: {cycle}")
        if resolved in seen:
            return
        seen.add(resolved)
        ordered.append(resolved)
        active.append(resolved)
        for child in _parser_include_paths(resolved):
            visit(child)
        active.pop()

    visit(source_path)
    return ordered


def _conservative_source_paths(lsp_root: Path, compiler_root: Path) -> list[Path]:
    """Fallback for a compiler too old to report or parse its include graph."""
    paths: list[Path] = []
    for root, suffixes in (
        (Path(lsp_root) / "src", {".elisa", ".elisai", ".c", ".h"}),
        (Path(compiler_root) / "src", {".elisa", ".elisai"}),
        (Path(compiler_root) / "elisacore_std", {".elisa", ".elisai"}),
    ):
        paths.extend(path for path in root.rglob("*") if path.is_file() and path.suffix in suffixes)
    return sorted(paths)


def compiler_include_closure(
    lsp_root: Path,
    compiler_root: Path,
    compiler_bin: Path,
    entry: str = "src/main.elisa",
) -> dict[str, Any]:
    """Return the compiler include closure in a portable, hashable form.

    ``-emit deps-json`` is preferred because it is emitted by the compiler's
    own resolver.  The parser fallback mirrors the same quoted-line grammar;
    if neither is possible, a conservative source-tree set preserves safety
    at the cost of invalidating on unrelated source edits.
    """
    lsp_root = Path(lsp_root).resolve(strict=True)
    compiler_root = Path(compiler_root).resolve(strict=True)
    try:
        compiler_path = _resolve_file(Path(compiler_bin), "compiler executable")
    except DependencyClosureError:
        compiler_path = Path(compiler_bin)
    # Includes in the language-server source use the stable sibling name
    # `Elisa-compiler`. Resolve the selected compiler checkout through that
    # layout in a private source view; otherwise an explicit
    # ELISA_COMPILER_ROOT is fingerprinted against whichever checkout happens
    # to sit beside the live LSP directory.
    mode = "compiler-emitted-deps-json"
    fallback_reason: str | None = None
    with tempfile.TemporaryDirectory(prefix="elisa-lsp-deps-") as temporary:
        view_root = Path(temporary)
        source_view = view_root / "Elisa-LSP"
        shutil.copytree(lsp_root / "src", source_view / "src")
        compiler_alias = view_root / "Elisa-compiler"
        compiler_alias.symlink_to(compiler_root, target_is_directory=True)
        source_path = _resolve_file(source_view / entry, "LSP entry")
        try:
            paths = _compiler_report_paths(compiler_path, source_path)
        except _CompilerDependencyUnavailable as exc:
            fallback_reason = str(exc)
            try:
                paths = _recursive_include_paths(source_path)
                mode = "recursive-include-parser"
            except DependencyClosureError as parser_exc:
                fallback_reason = f"{fallback_reason}; parser fallback: {parser_exc}"
                paths = _conservative_source_paths(source_view, compiler_root)
                mode = "conservative-source-tree"
        records = _closure_records(paths, source_view, compiler_root)
        root_name = "lsp/" + Path(entry).as_posix()
    info: dict[str, Any] = {
        "schema_version": INCLUDE_CLOSURE_SCHEMA_VERSION,
        "mode": mode,
        "root": root_name,
        "file_count": len(records),
        "files": records,
        "sha256": dependency_closure_sha256(records),
    }
    if fallback_reason:
        # Keep the reason bounded and diagnostic only; it is useful in a build
        # report while avoiding compiler stderr/source text in the manifest.
        info["fallback_reason"] = fallback_reason[:512]
    return info


def lsp_inputs_sha256(root: Path) -> str:
    source_hash = tree_digest(root / "src", {".elisa", ".elisai", ".c", ".h"})
    project_hash = sha256_file(root / "project.json")
    return hashlib.sha256((source_hash + project_hash).encode("ascii")).hexdigest()


def compiler_sources_sha256(root: Path) -> str:
    suffixes = {".elisa", ".elisai"}
    source_hash = tree_digest(root / "src", suffixes)
    standard_library_hash = tree_digest(root / "elisacore_std", suffixes)
    digest = hashlib.sha256()
    digest.update(b"compiler-src\0")
    digest.update(bytes.fromhex(source_hash))
    digest.update(b"compiler-elisacore_std\0")
    digest.update(bytes.fromhex(standard_library_hash))
    return digest.hexdigest()


def build_pipeline_sha256(root: Path) -> str:
    """Fingerprint the scripts/configuration that define this release build."""
    root = Path(root)
    digest = hashlib.sha256()
    digest.update(b"elisa-lsp-build-pipeline-v1\0")
    for relative_name in BUILD_PIPELINE_FILES:
        relative = relative_name.encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(bytes.fromhex(sha256_file(root / relative_name)))
    return digest.hexdigest()


def parse_go_build_info(output: str) -> dict:
    """Extract VCS and target metadata from ``go version -m`` output.

    Go's embedded build information describes the source state used to produce
    the binary. It must remain distinct from the current Elisa frontend
    checkout, which is a separate input to the LSP build.
    """
    go_version = None
    source_module = None
    settings = {}
    for line in output.splitlines():
        if go_version is None:
            match = re.search(r":\s+(go\d+(?:\.\d+)*(?:[A-Za-z0-9.+-]*)?)\s*$", line)
            if match:
                go_version = match.group(1)
        fields = line.split("\t")
        if len(fields) >= 3 and fields[1] == "path":
            source_module = fields[2] or None
        elif len(fields) >= 3 and fields[1] == "build":
            key, separator, value = fields[2].partition("=")
            if separator:
                settings[key] = value

    dirty_value = settings.get("vcs.modified")
    source_dirty = True if dirty_value == "true" else False if dirty_value == "false" else None
    metadata_available = go_version is not None or source_module is not None or bool(settings)
    return {
        "metadata_available": metadata_available,
        "metadata_source": "go version -m",
        "source_module": source_module,
        "source_revision": settings.get("vcs.revision"),
        "source_commit_time_utc": settings.get("vcs.time"),
        "source_dirty_at_build": source_dirty,
        "go_version": go_version,
        "goos": settings.get("GOOS"),
        "goarch": settings.get("GOARCH"),
        "rebuild_recipe": STAGE0_REBUILD_RECIPE,
    }


def stage0_provenance(compiler_binary: Path) -> dict:
    """Read optional Go build metadata without making Go a build dependency."""
    go = shutil.which("go")
    if go is None:
        return parse_go_build_info("")
    try:
        result = subprocess.run(
            [go, "version", "-m", str(compiler_binary)],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return parse_go_build_info("")
    if result.returncode != 0:
        return parse_go_build_info("")
    return parse_go_build_info(result.stdout)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lsp-root", required=True, type=Path)
    parser.add_argument("--compiler-root", type=Path)
    parser.add_argument("--compiler-bin", type=Path)
    parser.add_argument(
        "--entry",
        default="src/main.elisa",
        help="repository-relative LSP entry used for the compiler include closure",
    )
    parser.add_argument(
        "--dependency-closure",
        action="store_true",
        help="emit the normalized compiler include closure as JSON",
    )
    args = parser.parse_args()

    if args.dependency_closure:
        if args.compiler_root is None or args.compiler_bin is None:
            parser.error("--dependency-closure requires --compiler-root and --compiler-bin")
        try:
            info = compiler_include_closure(
                args.lsp_root,
                args.compiler_root,
                args.compiler_bin,
                args.entry,
            )
        except (DependencyClosureError, OSError, ValueError) as exc:
            parser.error(str(exc))
        print(json.dumps(info, indent=2, sort_keys=True))
        return

    print(lsp_inputs_sha256(args.lsp_root), end="")
    if args.compiler_root is not None or args.compiler_bin is not None:
        if args.compiler_root is None or args.compiler_bin is None:
            parser.error("--compiler-root and --compiler-bin must be supplied together")
        print(
            "\t"
            + compiler_sources_sha256(args.compiler_root)
            + "\t"
            + sha256_file(args.compiler_bin)
            + "\t"
            + build_pipeline_sha256(args.lsp_root),
            end="",
        )
    print()


if __name__ == "__main__":
    main()
