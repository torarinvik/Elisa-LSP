#!/usr/bin/env python3
"""Build and compare two Elisa compiler candidates in disposable LSP trees.

The gate is deliberately separate from ``build.sh`` publication.  It copies
this repository into a temporary directory, gives each backend a non-stage1
probe name, builds with the exact frontend root requested by the caller, runs
the same protocol corpus, and records benchmark distributions.  A candidate is
never copied into ``build/`` in the real checkout and can only be considered
for release after this command exits successfully.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def failed_test_names(output: str) -> list[str]:
    """Extract canonical-suite failures before the temporary log is removed."""
    prefix = "FAILED: "
    failures: list[str] = []
    for line in output.splitlines():
        line = line.strip()
        if line.startswith(prefix):
            name = line[len(prefix):].strip()
            if name and name not in failures:
                failures.append(name)
    return failures


def failure_diagnostic_lines(output: str, limit: int = 40) -> list[str]:
    """Keep actionable build diagnostics when disposable logs are removed."""
    markers = (
        "error:",
        "backend could not produce",
        "backend declines made this unit unsafe",
        "object was not written",
    )
    lines: list[str] = []
    for line in output.splitlines():
        clean = line.strip()
        if clean and any(marker in clean.lower() for marker in markers) and clean not in lines:
            lines.append(clean)
            if len(lines) >= limit:
                break
    return lines


def run(command: list[str], *, cwd: Path, env: dict[str, str], log: Path, timeout: float | None = None) -> dict[str, Any]:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
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
        timed_out = False
        returncode = completed.returncode
        output = completed.stdout
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        returncode = 124
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", "replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", "replace")
        output = stdout + stderr
    log.write_text(output, encoding="utf-8")
    return {
        "command": command,
        "returncode": returncode,
        "timed_out": timed_out,
        "seconds": round(time.monotonic() - started, 3),
        "log": str(log),
        "tail": output[-4000:],
        "failure_diagnostics": failure_diagnostic_lines(output),
        # run_all.sh prints one `FAILED: test/...` marker per failed test.
        # Preserve these separately because the temporary log is removed and
        # the bounded tail may omit failures that happened earlier in a suite.
        "failure_markers": failed_test_names(output),
    }


def copy_repo(root: Path, destination: Path) -> None:
    ignored = shutil.ignore_patterns(
        ".git",
        "build",
        "__pycache__",
        ".pytest_cache",
        ".elisa-lsp-source-v1.*",
        ".elisa-lsp-build.*",
    )
    shutil.copytree(root, destination, ignore=ignored, symlinks=False)


def mount_adjacent_frontend(tree: Path, frontend: Path) -> Path:
    """Recreate the documented sibling compiler checkout for the disposable tree."""
    adjacent = tree.parent / "Elisa-compiler"
    if adjacent.is_symlink() or adjacent.exists():
        if adjacent.is_dir() and not adjacent.is_symlink():
            shutil.rmtree(adjacent)
        else:
            adjacent.unlink()
    adjacent.symlink_to(frontend.resolve(), target_is_directory=True)
    return adjacent


def candidate_environments(base: dict[str, str], backend: Path) -> tuple[dict[str, str], dict[str, str]]:
    """Scope the stage1 opt-in to the build, so nested tests still exercise the guard."""
    build_env = base.copy()
    test_env = base.copy()
    build_env.pop("ELISA_LSP_ALLOW_STAGE1_GATE", None)
    test_env.pop("ELISA_LSP_ALLOW_STAGE1_GATE", None)
    if backend.name.startswith("elisac-stage1"):
        build_env["ELISA_LSP_ALLOW_STAGE1_GATE"] = "1"
    return build_env, test_env


def full_qualification_requested(skip_tests: bool, skip_benchmark: bool) -> bool:
    return not skip_tests and not skip_benchmark


def flatten_numbers(value: Any, prefix: str = "") -> dict[str, float]:
    result: dict[str, float] = {}
    if isinstance(value, dict):
        for key, child in value.items():
            result.update(flatten_numbers(child, f"{prefix}.{key}" if prefix else str(key)))
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        result[prefix] = float(value)
    return result


def summarize_benchmark(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    summaries: dict[str, float] = {}
    for case in data.get("cases", []):
        size = case.get("functions")
        for scenario, payload in case.get("scenarios", {}).items():
            summary = payload.get("summary", {})
            # bench.py summarizes each metric independently; latency lives at
            # summary.wall_s.p95 (in seconds), not summary.p95. Preserve the
            # gate's millisecond policy and only compare measured wall time.
            wall = summary.get("wall_s", {})
            p95 = wall.get("p95") if isinstance(wall, dict) else None
            if isinstance(p95, (int, float)) and not isinstance(p95, bool) and math.isfinite(p95):
                summaries[f"{size}.{scenario}.p95_ms"] = float(p95) * 1000.0
    return {"raw": data, "p95_ms": summaries}


def candidate_run(
    label: str,
    root: Path,
    backend: Path,
    frontend: Path,
    work: Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    tree_parent = work / label
    tree_parent.mkdir()
    tree = tree_parent / "Elisa-LSP"
    copy_repo(root, tree)
    mount_adjacent_frontend(tree, frontend)
    toolchain = tree / ".upgrade-toolchain"
    toolchain.mkdir()
    probe_backend = toolchain / ("elisac-stage0-" + label)
    shutil.copy2(backend, probe_backend)
    probe_backend.chmod(probe_backend.stat().st_mode | 0o111)
    logs = work / "logs" / label
    logs.mkdir(parents=True)
    env = os.environ.copy()
    env.update(
        {
            "ELISAC": str(probe_backend),
            "ELISA_COMPILER_ROOT": str(frontend.resolve()),
            "PYTHONUNBUFFERED": "1",
        }
    )
    build_env, test_env = candidate_environments(env, backend)
    record: dict[str, Any] = {
        "label": label,
        "backend": str(backend.resolve()),
        "backend_sha256": sha256(backend),
        "frontend": str(frontend.resolve()),
        "started_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    build = run(["bash", "build.sh", "--release"], cwd=tree, env=build_env, log=logs / "build.log", timeout=args.build_timeout)
    record["build"] = build
    binary = tree / "build" / "elisa-lsp"
    manifest_path = tree / "build" / "manifest.json"
    if build["returncode"] != 0 or not binary.is_file() or not manifest_path.is_file():
        record["status"] = "build-failed"
        return record
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    closure = manifest.get("include_closure") if isinstance(manifest, dict) else None
    record["manifest"] = {
        "artifact_sha256": manifest.get("artifact_sha256"),
        "object_sha256": manifest.get("object_sha256"),
        "compiler_sources_sha256": manifest.get("compiler_sources_sha256"),
        "include_closure_sha256": closure.get("sha256") if isinstance(closure, dict) else None,
        "include_closure_mode": closure.get("mode") if isinstance(closure, dict) else None,
        "include_closure_file_count": closure.get("file_count") if isinstance(closure, dict) else None,
        "lsp_inputs_sha256": manifest.get("lsp_inputs_sha256"),
        "build_flags": manifest.get("build_flags"),
        "artifact_bytes": binary.stat().st_size,
    }
    if args.skip_tests:
        record["tests"] = {"skipped": True}
    else:
        tests = run(["bash", "test/run_all.sh"], cwd=tree, env=test_env, log=logs / "tests.log", timeout=args.test_timeout)
        tests["failed_tests"] = tests.pop("failure_markers", [])
        record["tests"] = tests
        if tests["returncode"] != 0:
            record["status"] = "tests-failed"
            return record
    if args.skip_benchmark:
        record["benchmark"] = {"skipped": True}
    else:
        benchmark_path = tree / "bench" / f"upgrade-{label}.json"
        benchmark_path.parent.mkdir(exist_ok=True)
        benchmark = run(
            [
                "python3",
                "test/bench.py",
                "--sizes",
                args.benchmark_sizes,
                "--samples",
                str(args.samples),
                "--out",
                str(benchmark_path),
            ],
            cwd=tree,
            env=test_env,
            log=logs / "benchmark.log",
            timeout=args.benchmark_timeout,
        )
        record["benchmark_run"] = benchmark
        if benchmark["returncode"] != 0 or not benchmark_path.is_file():
            record["status"] = "benchmark-failed"
            return record
        record["benchmark"] = summarize_benchmark(benchmark_path)
    record["status"] = "passed"
    return record


def compare_benchmarks(baseline: dict[str, Any], candidate: dict[str, Any], max_regression: float) -> list[str]:
    old = baseline.get("benchmark", {}).get("p95_ms")
    new = candidate.get("benchmark", {}).get("p95_ms")
    if not isinstance(old, dict) or not old:
        return ["baseline benchmark contains no finite wall-time p95 measurements"]
    if not isinstance(new, dict) or not new:
        return ["candidate benchmark contains no finite wall-time p95 measurements"]
    if set(old) != set(new):
        missing = sorted(set(old) - set(new))
        extra = sorted(set(new) - set(old))
        return [f"benchmark scenario mismatch: missing={missing}, extra={extra}"]
    problems = []
    for key, before in old.items():
        after = new[key]
        if not math.isfinite(before) or not math.isfinite(after) or before <= 0 or after < 0:
            problems.append(f"{key}: invalid baseline/candidate p95 values {before!r}/{after!r} ms")
            continue
        if after > before * (1.0 + max_regression):
            problems.append(f"{key}: candidate p95 {after:.3f} ms exceeds baseline {before:.3f} ms by > {max_regression:.0%}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--baseline-compiler", required=True, type=Path)
    parser.add_argument("--baseline-frontend", required=True, type=Path)
    parser.add_argument("--candidate-compiler", required=True, type=Path)
    parser.add_argument("--candidate-frontend", required=True, type=Path)
    parser.add_argument("--out", type=Path, default=Path("bench/compiler-upgrade-gate.json"))
    parser.add_argument("--build-timeout", type=float, default=600.0)
    parser.add_argument("--test-timeout", type=float, default=900.0)
    parser.add_argument("--benchmark-timeout", type=float, default=900.0)
    parser.add_argument("--benchmark-sizes", default="100,1000")
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--max-latency-regression", type=float, default=0.50)
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--skip-benchmark", action="store_true")
    args = parser.parse_args()
    if args.samples <= 0 or args.max_latency_regression < 0:
        parser.error("samples must be positive and max latency regression must be non-negative")
    root = args.root.resolve(strict=True)
    for path, label in (
        (args.baseline_compiler, "baseline compiler"),
        (args.baseline_frontend, "baseline frontend"),
        (args.candidate_compiler, "candidate compiler"),
        (args.candidate_frontend, "candidate frontend"),
    ):
        if not path.exists():
            parser.error(f"{label} does not exist: {path}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="elisa-lsp-upgrade-") as temporary:
        work = Path(temporary)
        baseline = candidate_run("baseline", root, args.baseline_compiler.resolve(), args.baseline_frontend.resolve(), work, args)
        candidate = candidate_run("candidate", root, args.candidate_compiler.resolve(), args.candidate_frontend.resolve(), work, args)
        latency_problems = compare_benchmarks(baseline, candidate, args.max_latency_regression)
        qualification_complete = full_qualification_requested(args.skip_tests, args.skip_benchmark)
        result = {
            "schema_version": 1,
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "root": str(root),
            "benchmark_policy": {
                "sizes": args.benchmark_sizes,
                "samples": args.samples,
                "max_latency_regression": args.max_latency_regression,
            },
            "baseline": baseline,
            "candidate": candidate,
            "latency_regressions": latency_problems,
            "qualification_complete": qualification_complete,
            "gate_passed": qualification_complete and baseline.get("status") == "passed" and candidate.get("status") == "passed" and not latency_problems,
        }
        args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({
            "gate_passed": result["gate_passed"],
            "qualification_complete": result["qualification_complete"],
            "baseline_status": baseline.get("status"),
            "candidate_status": candidate.get("status"),
            "latency_regressions": latency_problems,
            "report": str(args.out.resolve()),
        }, indent=2))
        if not result["gate_passed"]:
            if not qualification_complete:
                print("compiler upgrade qualification incomplete; skipped gates cannot qualify a release", file=sys.stderr)
            else:
                print("compiler upgrade gate failed; keep the supported stage0 release compiler", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
