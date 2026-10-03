#!/usr/bin/env python3
"""The disposable compiler gate must retain suite failures before log cleanup."""
from pathlib import Path
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from compiler_upgrade_gate import candidate_environments, compare_benchmarks, failed_test_names, failure_diagnostic_lines, full_qualification_requested, mount_adjacent_frontend, summarize_benchmark


output = """===== test/one.sh =====
ok
FAILED: test/one.sh
===== test/two.py =====
assertion failed
FAILED: test/two.py
FAILED: test/two.py
pass=0 fail=2
"""
assert failed_test_names(output) == ["test/one.sh", "test/two.py"]
assert failed_test_names("pass=3 fail=0\n") == []
assert failure_diagnostic_lines("warning\nerror: bad type\nbackend could not produce an object\n") == [
    "error: bad type",
    "backend could not produce an object",
]
assert full_qualification_requested(False, False)
assert not full_qualification_requested(True, False)
assert not full_qualification_requested(False, True)

with tempfile.TemporaryDirectory() as temporary:
    benchmark = Path(temporary) / "benchmark.json"
    benchmark.write_text(
        '{"cases":[{"functions":100,"scenarios":{'
        '"clean_open":{"summary":{"wall_s":{"p95":0.321}}},'
        '"edit":{"summary":{"wall_s":{"p95":0.654}}},'
        '"missing":{"summary":{"wall_s":null}}}}]}',
        encoding="utf-8",
    )
    summary = summarize_benchmark(benchmark)
    assert summary["p95_ms"] == {
        "100.clean_open.p95_ms": 321.0,
        "100.edit.p95_ms": 654.0,
    }, summary

old = {"benchmark": {"p95_ms": {"100.clean_open.p95_ms": 100.0}}}
new = {"benchmark": {"p95_ms": {"100.clean_open.p95_ms": 140.0}}}
assert compare_benchmarks(old, new, 0.50) == []
assert compare_benchmarks(old, new, 0.25) == [
    "100.clean_open.p95_ms: candidate p95 140.000 ms exceeds baseline 100.000 ms by > 25%"
]
assert "contains no finite" in compare_benchmarks(old, {"benchmark": {"p95_ms": {}}}, 0.50)[0]
assert "scenario mismatch" in compare_benchmarks(
    old, {"benchmark": {"p95_ms": {"100.edit.p95_ms": 50.0}}}, 0.50
)[0]

base = {"ELISA_LSP_ALLOW_STAGE1_GATE": "1", "ELISA_COMPILER_ROOT": "/compiler"}
stage0_build, stage0_tests = candidate_environments(base, Path("elisac-stage0"))
assert "ELISA_LSP_ALLOW_STAGE1_GATE" not in stage0_build
assert "ELISA_LSP_ALLOW_STAGE1_GATE" not in stage0_tests
stage1_build, stage1_tests = candidate_environments(base, Path("elisac-stage1"))
assert stage1_build["ELISA_LSP_ALLOW_STAGE1_GATE"] == "1"
assert "ELISA_LSP_ALLOW_STAGE1_GATE" not in stage1_tests

with tempfile.TemporaryDirectory() as temporary:
    work = Path(temporary)
    case = work / "baseline"
    tree = case / "Elisa-LSP"
    tree.mkdir(parents=True)
    frontend = work / "selected-frontend"
    frontend.mkdir()
    mounted = mount_adjacent_frontend(tree, frontend)
    assert mounted == case / "Elisa-compiler"
    assert mounted.resolve() == frontend.resolve()
print("compiler upgrade gate isolation and failure extraction OK")
