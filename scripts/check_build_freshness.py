#!/usr/bin/env python3
"""Reject test runs whose executable no longer matches recorded build inputs."""

import argparse
import json
import os
import stat
import sys
from pathlib import Path

from build_hashes import (
    build_pipeline_sha256,
    compiler_include_closure,
    compiler_sources_sha256,
    dependency_closure_sha256,
    dependency_closure_sha256_for_roots,
    lsp_inputs_sha256,
    sha256_file,
)


def reject(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def verify_source_snapshot(manifest: dict, repository_root: Path) -> None:
    snapshot_value = manifest.get("source_snapshot_root")
    staged_compiler_value = manifest.get("staged_compiler_root")
    if not isinstance(snapshot_value, str) or not isinstance(staged_compiler_value, str):
        reject("build manifest lacks the immutable compiler source snapshot; rebuild with bash build.sh")

    snapshot = Path(snapshot_value)
    staged_compiler = Path(staged_compiler_value)
    if not snapshot.is_absolute() or not staged_compiler.is_absolute():
        reject("build manifest source snapshot paths must be absolute")

    try:
        resolved_snapshot = snapshot.resolve(strict=True)
        resolved_compiler = staged_compiler.resolve(strict=True)
        build_directory = (repository_root / "build").resolve(strict=True)
    except OSError as exc:
        reject(f"cannot resolve the build source snapshot: {exc}")

    if snapshot != resolved_snapshot or staged_compiler != resolved_compiler:
        reject("build source snapshot paths must not traverse symlinks")
    try:
        resolved_snapshot.relative_to(build_directory)
    except ValueError:
        reject("build source snapshot is outside Elisa-LSP/build")
    if resolved_snapshot.parent.parent != build_directory or resolved_snapshot.name != "source":
        reject("build source snapshot has an unexpected layout")
    expected_snapshot_name = (
        ".elisa-lsp-source-v1."
        + str(manifest.get("lsp_inputs_sha256", ""))
        + "."
        + str(manifest.get("compiler_sources_sha256", ""))
    )
    if resolved_snapshot.parent.name != expected_snapshot_name:
        reject("build source snapshot path does not match its recorded input fingerprints")
    if resolved_compiler != resolved_snapshot / "Elisa-compiler":
        reject("staged compiler path does not match the recorded source snapshot")

    lsp_root = resolved_snapshot / "Elisa-LSP"
    compiler_root = resolved_compiler
    for source_root in (resolved_snapshot, lsp_root, compiler_root):
        if not source_root.is_dir():
            reject(f"build source snapshot directory is missing: {source_root}")

    # The build treats the content-addressed tree as immutable. Reject symlinks
    # and writable files/directories so a later check cannot silently follow
    # mutable data outside the verified snapshot or race a path replacement.
    for source_root in (resolved_snapshot,):
        for directory, directories, filenames in os.walk(source_root, followlinks=False):
            current = Path(directory)
            entries = [current, *(current / name for name in directories + filenames)]
            for entry in entries:
                try:
                    metadata = entry.lstat()
                except OSError as exc:
                    reject(f"cannot inspect build source snapshot entry {entry}: {exc}")
                if stat.S_ISLNK(metadata.st_mode):
                    reject(f"build source snapshot contains a symlink: {entry}")
                if stat.S_ISREG(metadata.st_mode) and metadata.st_mode & 0o222:
                    reject(f"build source snapshot file is writable: {entry}")
                if stat.S_ISDIR(metadata.st_mode) and metadata.st_mode & 0o222:
                    reject(f"build source snapshot directory is writable: {entry}")

    try:
        snapshot_lsp_hash = lsp_inputs_sha256(lsp_root)
        snapshot_compiler_hash = compiler_sources_sha256(compiler_root)
    except OSError as exc:
        reject(f"cannot fingerprint the immutable build source snapshot: {exc}")
    if snapshot_lsp_hash != manifest.get("lsp_inputs_sha256"):
        reject("staged Elisa-LSP source snapshot differs from the build manifest")
    if snapshot_compiler_hash != manifest.get("compiler_sources_sha256"):
        reject("staged Elisa-compiler source snapshot differs from the build manifest")

    closure = manifest.get("include_closure")
    if not isinstance(closure, dict):
        reject("build manifest lacks the compiler include-closure fingerprint; rebuild with bash build.sh")
    if closure.get("schema_version") != 1 or not isinstance(closure.get("files"), list):
        reject("build manifest compiler include closure is malformed; rebuild with bash build.sh")
    try:
        snapshot_closure_hash = dependency_closure_sha256_for_roots(
            lsp_root,
            compiler_root,
            closure["files"],
        )
        recorded_closure_hash = dependency_closure_sha256(closure["files"])
    except (KeyError, TypeError, ValueError, OSError, RuntimeError) as exc:
        reject(f"cannot fingerprint the staged compiler include closure: {exc}")
    if recorded_closure_hash != closure.get("sha256"):
        reject("build manifest compiler include closure has inconsistent records")
    if snapshot_closure_hash != recorded_closure_hash:
        reject("staged compiler include closure differs from the build manifest")


def verify_live_include_closure(manifest: dict, repository_root: Path) -> bool:
    """Re-run the compiler's resolver when the recorded toolchain is present.

    Returns whether a new-style closure was available.  Older manifests retain
    the conservative whole-tree behavior until they are rebuilt.
    """
    closure = manifest.get("include_closure")
    if not isinstance(closure, dict):
        return False
    compiler_root_value = manifest.get("compiler_root")
    compiler_binary_value = manifest.get("elisac")
    entry = manifest.get("entry")
    if (
        not isinstance(compiler_root_value, str)
        or not isinstance(compiler_binary_value, str)
        or not isinstance(entry, str)
    ):
        return True
    compiler_root = Path(compiler_root_value)
    compiler_binary = Path(compiler_binary_value)
    if not compiler_root.is_dir() or not compiler_binary.is_file():
        # The immutable snapshot has already been checked.  A binary-only
        # deployment cannot re-run the compiler's dependency reporter, so the
        # recorded closure remains the strongest available evidence.
        return True
    try:
        current = compiler_include_closure(
            repository_root,
            compiler_root,
            compiler_binary,
            entry,
        )
    except (OSError, RuntimeError, ValueError) as exc:
        reject(f"cannot fingerprint the live compiler include closure: {exc}")
    if current.get("sha256") != closure.get("sha256"):
        reject("Elisa compiler include closure differs from the build manifest; rebuild with bash build.sh")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="Elisa-LSP repository root")
    parser.add_argument("--binary", required=True, type=Path, help="built LSP executable")
    parser.add_argument("--manifest", required=True, type=Path, help="build provenance manifest")
    args = parser.parse_args()

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        reject(f"cannot read valid build manifest {args.manifest}: {exc}; rebuild with bash build.sh")
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 3:
        reject(f"unsupported or malformed build manifest {args.manifest}; rebuild with current build.sh")
    if manifest.get("artifact") != args.binary.name:
        reject(f"manifest artifact {manifest.get('artifact')!r} does not describe {args.binary.name!r}")
    if not args.binary.is_file():
        reject(f"built executable is missing: {args.binary}; rebuild with bash build.sh")

    try:
        recorded_artifact = manifest.get("artifact_sha256")
        current_artifact = sha256_file(args.binary)
    except OSError as exc:
        reject(f"cannot fingerprint executable {args.binary}: {exc}")
    if not isinstance(recorded_artifact, str) or recorded_artifact != current_artifact:
        reject(f"{args.binary} does not match artifact_sha256 in {args.manifest}; rebuild with bash build.sh")

    try:
        current_lsp_inputs = lsp_inputs_sha256(args.root)
    except OSError as exc:
        reject(f"cannot fingerprint Elisa-LSP build inputs under {args.root}: {exc}")
    if manifest.get("lsp_inputs_sha256") != current_lsp_inputs:
        reject(f"Elisa-LSP source/project inputs differ from the build manifest; rebuild with bash build.sh")

    recorded_pipeline = manifest.get("build_pipeline_sha256")
    if (
        not isinstance(recorded_pipeline, str)
        or len(recorded_pipeline) != 64
        or any(character not in "0123456789abcdef" for character in recorded_pipeline)
    ):
        reject(f"build manifest lacks a valid build-pipeline fingerprint; rebuild with bash build.sh")
    try:
        current_pipeline = build_pipeline_sha256(args.root)
    except OSError as exc:
        reject(f"cannot fingerprint Elisa-LSP build-pipeline inputs under {args.root}: {exc}")
    if recorded_pipeline != current_pipeline:
        reject("Elisa-LSP build-pipeline inputs differ from the build manifest; rebuild with bash build.sh")

    verify_source_snapshot(manifest, args.root.resolve())
    closure_verified = verify_live_include_closure(manifest, args.root.resolve())

    # The recorded compiler checkout and stage0 binary are build dependencies.
    # Check them when they are still available at their recorded paths; a
    # binary-only deployment can still validate its artifact/source provenance.
    compiler_root_value = manifest.get("compiler_root")
    compiler_hash = manifest.get("compiler_sources_sha256")
    if isinstance(compiler_root_value, str) and isinstance(compiler_hash, str) and not closure_verified:
        compiler_root = Path(compiler_root_value)
        if compiler_root.is_dir():
            try:
                current_compiler_hash = compiler_sources_sha256(compiler_root)
            except OSError as exc:
                reject(f"cannot fingerprint compiler sources under {compiler_root}: {exc}")
            if current_compiler_hash != compiler_hash:
                reject("Elisa-compiler frontend sources differ from the build manifest; rebuild with bash build.sh")

    compiler_binary_value = manifest.get("elisac")
    compiler_binary_hash = manifest.get("elisac_sha256")
    if isinstance(compiler_binary_value, str) and isinstance(compiler_binary_hash, str):
        compiler_binary = Path(compiler_binary_value)
        if compiler_binary.is_file():
            try:
                current_compiler_binary_hash = sha256_file(compiler_binary)
            except OSError as exc:
                reject(f"cannot fingerprint stage0 compiler {compiler_binary}: {exc}")
            if current_compiler_binary_hash != compiler_binary_hash:
                reject("stage0 compiler binary differs from the build manifest; rebuild with bash build.sh")

    print(f"build freshness OK: {args.binary}")


if __name__ == "__main__":
    main()
