#!/usr/bin/env python3
"""Unit checks for the benchmark's portable live-RSS reader and summary."""

from __future__ import annotations

import importlib.util
import os
import platform
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("elisa_lsp_bench", ROOT / "test" / "bench.py")
assert SPEC and SPEC.loader
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)


rss_bytes, source = BENCH.current_rss_bytes(os.getpid())
if platform.system() in ("Darwin", "Linux"):
    assert isinstance(rss_bytes, int) and rss_bytes > 0, (rss_bytes, source)
    assert source != "unavailable", source
else:
    assert rss_bytes is None and source == "unavailable", (rss_bytes, source)

assert BENCH.current_rss_bytes(-1) == (None, "unavailable")
summary = BENCH.sampled_rss_summary([
    {"phase": "after_initialize", "rss_bytes": 1000},
    {"phase": "after_warmup_close", "rss_bytes": 1100},
    {"phase": "after_close_batch", "rss_bytes": 1250},
])
assert summary == {
    "initial_bytes": 1000,
    "after_warmup_bytes": 1100,
    "final_bytes": 1250,
    "peak_sampled_bytes": 1250,
    "p95_sampled_bytes": 1250,
    "sample_count": 3,
    "delta_from_warmup_bytes": 150,
}, summary

assert BENCH.nearest_rank([10, 20, 30, 40], 0.95) == 40
assert BENCH.nearest_rank([10, 20, 30, 40], 0.5) == 20
assert BENCH.nearest_rank([10], 0.95) == 10
assert BENCH.distribution_summary([0.1, 0.3, 0.2], decimals=2) == {
    "sample_count": 3,
    "min": 0.1,
    "median": 0.2,
    "p95": 0.3,
    "max": 0.3,
}
try:
    BENCH.nearest_rank([], 0.95)
except ValueError:
    pass
else:  # pragma: no cover - defensive assertion
    raise AssertionError("empty percentile input must fail")

print(f"benchmark RSS OK: {source}, bytes, warmup-relative sample summary")
