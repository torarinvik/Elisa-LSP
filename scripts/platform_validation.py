#!/usr/bin/env python3
"""Run and record the reproducible macOS/Linux validation contract.

This command is intentionally a host validation runner, not a cross-compiler.
It never labels a platform as supported from ``uname`` alone.  A report is
``validated`` only after the caller requested both a fresh release build and
the canonical test suite, and the resulting executable passes the manifest
freshness check.  Without those phases the report remains an explicit
``incomplete`` candidate record.

Typical usage on a validation host::

    python3 scripts/platform_validation.py --build --tests \
      --out bench/platform-validation-$(uname -s)-$(uname -m).json

The output is safe to retain as release evidence: command output is limited to
the tail of each command, canonical-suite failure names are retained as short
markers, and no source text is copied into the report.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
from typing import Any, Sequence


SUPPORTED_SYSTEMS = ("Darwin", "Linux")
REPORT_SCHEMA_VERSION = 2
OUTPUT_TAIL_CHARS = 4000


def failure_markers(output: str) -> list[str]:
    """Retain concise test-runner failure names even when their logs are tailed."""
    markers: list[str] = []
    for line in output.splitlines():
        marker = line.strip()
        if marker.startswith("FAILED: ") and marker not in markers:
            markers.append(marker)
    return markers[:100]


def sha256_file(path: Path) -> str | None:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        return digest.hexdigest()
    except OSError:
        return None


def command_record(
    command: Sequence[str],
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
    timeout: float = 30.0,
) -> dict[str, Any]:
    """Run one bounded command and return a JSON-safe evidence record."""
    started = time.monotonic()
    try:
        completed = subprocess.run(
            list(command),
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
        output = completed.stdout or ""
        returncode = completed.returncode
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", "replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", "replace")
        output = stdout + stderr
        returncode = 124
        timed_out = True
    except OSError as exc:
        output = f"{type(exc).__name__}: {exc}"
        returncode = 127
        timed_out = False

    # Keep reports useful for CI while bounding retained compiler/linker text.
    tail = output[-OUTPUT_TAIL_CHARS:]
    return {
        "command": list(command),
        "returncode": returncode,
        "timed_out": timed_out,
        "seconds": round(time.monotonic() - started, 3),
        "output_tail": tail,
        "failure_markers": failure_markers(output),
    }


def resolve_path(value: str | None, *, fallback: Path | None = None) -> Path | None:
    """Resolve a user path without silently substituting a different tool."""
    if value:
        candidate = Path(value).expanduser()
        if not candidate.is_absolute():
            candidate = Path.cwd() / candidate
        return candidate.resolve(strict=False)
    if fallback is None:
        return None
    return fallback.resolve(strict=False)


def discover_compiler(root: Path, explicit: str | None) -> Path | None:
    if explicit:
        return resolve_path(explicit)
    for candidate in (
        Path.home() / ".elisac" / "elisac-stage0",
        Path.home() / ".elisac" / "elisac",
    ):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    return None


def git_value(path: Path, *arguments: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(path), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def toolchain_identity(
    root: Path,
    compiler: Path | None,
    frontend: Path | None,
    manifest: dict[str, Any] | None,
) -> dict[str, Any]:
    """Collect host and input identities without requiring a successful build."""
    compiler_hash = sha256_file(compiler) if compiler and compiler.is_file() else None
    frontend_hash = None
    frontend_closure_hash = None
    frontend_closure_mode = None
    frontend_closure_file_count = None
    if frontend and frontend.is_dir():
        # Import the repository's canonical source fingerprint rather than
        # duplicating its include-closure rules in this validation tool.
        try:
            sys.path.insert(0, str(root / "scripts"))
            from build_hashes import compiler_sources_sha256, compiler_include_closure

            frontend_hash = compiler_sources_sha256(frontend)
            if manifest and compiler and compiler.is_file():
                closure = compiler_include_closure(
                    root,
                    frontend,
                    compiler,
                    str(manifest.get("entry", "src/main.elisa")),
                )
                frontend_closure_hash = closure.get("sha256")
                frontend_closure_mode = closure.get("mode")
                frontend_closure_file_count = closure.get("file_count")
        except (ImportError, OSError, RuntimeError, ValueError):
            frontend_hash = None

    clang = shutil.which("clang")
    clang_version = None
    clang_target = None
    clang_record: dict[str, Any] | None = None
    if clang:
        clang_record = command_record([clang, "--version"], cwd=root)
        clang_version = clang_record.get("output_tail", "").splitlines()[0] if clang_record.get("output_tail") else None
        target_record = command_record([clang, "-dumpmachine"], cwd=root)
        if target_record["returncode"] == 0:
            clang_target = target_record.get("output_tail", "").strip() or None

    identity = {
        "system": platform.system(),
        "release": platform.release(),
        "version": platform.version(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "compiler": str(compiler) if compiler else None,
        "compiler_sha256": compiler_hash,
        "compiler_stage1_named": bool(compiler and compiler.name.startswith("elisac-stage1")),
        "frontend": str(frontend) if frontend else None,
        "frontend_revision": git_value(frontend, "rev-parse", "HEAD") if frontend else None,
        "frontend_dirty": (
            (status := git_value(frontend, "status", "--porcelain")) is not None and status != ""
            if frontend
            else None
        ),
        "frontend_sources_sha256": frontend_hash,
        "frontend_include_closure_sha256": frontend_closure_hash,
        "frontend_include_closure_mode": frontend_closure_mode,
        "frontend_include_closure_file_count": frontend_closure_file_count,
        "clang": clang,
        "clang_version": clang_version,
        "clang_target": clang_target,
        "manifest_os_arch": manifest.get("os_arch") if manifest else None,
        "manifest_compiler_sha256": manifest.get("elisac_sha256") if manifest else None,
    }
    if clang_record is not None:
        identity["clang_version_probe"] = clang_record
    return identity


def platform_gate_status(
    *,
    system: str,
    build_requested: bool,
    build_passed: bool,
    tests_requested: bool,
    tests_passed: bool,
    freshness_passed: bool,
) -> str:
    """Return the only support label this command is allowed to publish."""
    if system not in SUPPORTED_SYSTEMS:
        return "unsupported-platform"
    if not build_requested or not tests_requested:
        return "incomplete" if freshness_passed else "failed"
    if not build_passed or not tests_passed or not freshness_passed:
        return "failed"
    return "validated"


def read_manifest(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return None, f"cannot read manifest: {exc}"
    if not isinstance(value, dict):
        return None, "manifest root is not an object"
    return value, None


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--compiler", help="stage0 compiler executable; defaults to the documented discovery order")
    parser.add_argument("--frontend", help="Elisa compiler checkout; defaults to ELISA_COMPILER_ROOT or ../Elisa-compiler")
    parser.add_argument("--binary", type=Path, help="LSP executable; defaults to root/build/elisa-lsp")
    parser.add_argument("--manifest", type=Path, help="build manifest; defaults to root/build/manifest.json")
    parser.add_argument("--out", type=Path, default=Path("bench/platform-validation.json"))
    parser.add_argument("--build", action="store_true", help="run a fresh release build before validation")
    parser.add_argument("--tests", action="store_true", help="run the canonical test suite after the build/freshness check")
    parser.add_argument("--require-platform", choices=SUPPORTED_SYSTEMS, help="fail unless running on this host OS")
    parser.add_argument("--build-timeout", type=float, default=900.0)
    parser.add_argument("--test-timeout", type=float, default=1800.0)
    args = parser.parse_args(argv)

    root = args.root.resolve(strict=True)
    binary = (args.binary or root / "build" / "elisa-lsp").resolve(strict=False)
    manifest_path = (args.manifest or root / "build" / "manifest.json").resolve(strict=False)
    compiler = discover_compiler(root, args.compiler or os.environ.get("ELISAC"))
    frontend_value = args.frontend or os.environ.get("ELISA_COMPILER_ROOT")
    frontend = resolve_path(frontend_value, fallback=root.parent / "Elisa-compiler")
    system = platform.system()
    report: dict[str, Any] = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "root": str(root),
        "policy": {
            "validation_candidates": list(SUPPORTED_SYSTEMS),
            "validated_requires": ["--build", "--tests", "freshness check"],
            "cross_compilation": "not performed",
        },
        "requested": {"build": args.build, "tests": args.tests, "require_platform": args.require_platform},
        "platform": {"system": system, "machine": platform.machine(), "release": platform.release()},
        "commands": {},
        "errors": [],
    }
    if args.require_platform and system != args.require_platform:
        report["errors"].append(f"host platform is {system}, expected {args.require_platform}")

    env = os.environ.copy()
    # This runner validates an ordinary supported release. Stage1 admission is
    # reserved for scripts/compiler_upgrade_gate.py's disposable probe trees.
    env.pop("ELISA_LSP_ALLOW_STAGE1_GATE", None)
    if compiler:
        env["ELISAC"] = str(compiler)
    if frontend:
        env["ELISA_COMPILER_ROOT"] = str(frontend)

    build_passed = not args.build
    if args.build:
        record = command_record(["bash", "build.sh", "--release"], cwd=root, env=env, timeout=args.build_timeout)
        report["commands"]["build"] = record
        build_passed = record["returncode"] == 0 and not record["timed_out"]
        if not build_passed:
            report["errors"].append("fresh release build failed")

    manifest, manifest_error = read_manifest(manifest_path)
    if manifest_error:
        report["errors"].append(manifest_error)

    freshness_record = command_record(
        [
            "python3",
            "scripts/check_build_freshness.py",
            "--root",
            str(root),
            "--binary",
            str(binary),
            "--manifest",
            str(manifest_path),
        ],
        cwd=root,
        env=env,
        timeout=60.0,
    )
    report["commands"]["freshness"] = freshness_record
    freshness_passed = freshness_record["returncode"] == 0 and not freshness_record["timed_out"]
    if not freshness_passed:
        report["errors"].append("build freshness check failed")

    tests_passed = not args.tests
    if args.tests:
        # run_all pins temporary fixture builds to the validated manifest. Keep
        # that behavior by passing only the same explicit source identities.
        record = command_record(["bash", "test/run_all.sh"], cwd=root, env=env, timeout=args.test_timeout)
        report["commands"]["tests"] = record
        tests_passed = record["returncode"] == 0 and not record["timed_out"]
        if not tests_passed:
            report["errors"].append("canonical test suite failed")

    report["toolchain"] = toolchain_identity(root, compiler, frontend, manifest)
    report["manifest"] = {
        "path": str(manifest_path),
        "schema_version": manifest.get("schema_version") if manifest else None,
        "artifact_sha256": manifest.get("artifact_sha256") if manifest else None,
        "compiler_sources_sha256": manifest.get("compiler_sources_sha256") if manifest else None,
        "built_at_utc": manifest.get("built_at_utc") if manifest else None,
        "os_arch": manifest.get("os_arch") if manifest else None,
    }
    expected_os_arch = f"{system}/{platform.machine()}"
    if manifest and manifest.get("os_arch") not in (None, expected_os_arch):
        report["errors"].append(
            f"manifest target {manifest.get('os_arch')!r} does not match host {expected_os_arch}"
        )
    report["status"] = platform_gate_status(
        system=system,
        build_requested=args.build,
        build_passed=build_passed,
        tests_requested=args.tests,
        tests_passed=tests_passed,
        freshness_passed=freshness_passed,
    )
    if report["status"] == "unsupported-platform":
        report["errors"].append(f"{system}/{platform.machine()} is outside the validation candidate set")

    if args.require_platform and system != args.require_platform:
        report["status"] = "failed"
    if manifest and manifest.get("os_arch") not in (None, expected_os_arch):
        report["status"] = "failed"

    output_path = args.out if args.out.is_absolute() else root / args.out
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "report": str(output_path.resolve()), "errors": report["errors"]}, indent=2))
    return 0 if report["status"] == "validated" else 1


if __name__ == "__main__":
    raise SystemExit(main())
