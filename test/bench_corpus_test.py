#!/usr/bin/env python3
"""Pure, no-server checks for the independent benchmark corpus controls."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("elisa_lsp_bench", ROOT / "test" / "bench.py")
assert SPEC and SPEC.loader
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)


assert BENCH.parse_dimensions("none") == []
assert BENCH.parse_dimensions("source_size,unicode_density") == [
    "source_size",
    "unicode_density",
]
assert BENCH.parse_dimensions("all") == list(BENCH.DIMENSION_NAMES)
try:
    BENCH.parse_dimensions("symbols,symbols")
except Exception:
    pass
else:  # pragma: no cover - defensive assertion
    raise AssertionError("duplicate benchmark dimensions must be rejected")


default = BENCH.gen_fixture_doc(8)
assert default == BENCH.gen_doc(8), "the historical B04 fixture must remain unchanged"

source_size = [
    BENCH.gen_fixture_doc(
        fixture.functions,
        target_bytes=fixture.target_bytes,
        unicode_density=fixture.unicode_density,
    )
    for fixture in BENCH.INDEPENDENT_FIXTURES["source_size"]
]
assert [len(source.encode("utf-8")) for source in source_size] == [
    4 * 1024,
    64 * 1024,
    256 * 1024,
]
assert all(source.count("def ") == 64 for source in source_size)

symbol_fixtures = BENCH.INDEPENDENT_FIXTURES["symbols"]
symbol_sources = [
    BENCH.gen_fixture_doc(
        fixture.functions,
        target_bytes=fixture.target_bytes,
        unicode_density=fixture.unicode_density,
    )
    for fixture in symbol_fixtures
]
assert len({len(source.encode("utf-8")) for source in symbol_sources}) == 1
assert [source.count("def ") for source in symbol_sources] == [8, 64, 256]

unicode_sources = [
    BENCH.gen_fixture_doc(
        fixture.functions,
        target_bytes=fixture.target_bytes,
        unicode_density=fixture.unicode_density,
    )
    for fixture in BENCH.INDEPENDENT_FIXTURES["unicode_density"]
]
unicode_metrics = [BENCH.fixture_source_metrics(source) for source in unicode_sources]
assert len({metrics["bytes"] for metrics in unicode_metrics}) == 1
assert [metrics["non_ascii_codepoints"] for metrics in unicode_metrics] == sorted(
    metrics["non_ascii_codepoints"] for metrics in unicode_metrics
)
assert unicode_metrics[0]["non_ascii_codepoints"] == 0
assert unicode_metrics[-1]["non_ascii_codepoints"] > 0

burst_fixture = BENCH.INDEPENDENT_FIXTURES["edit_burst"][1]
burst_source = BENCH.gen_fixture_doc(
    burst_fixture.functions,
    target_bytes=burst_fixture.target_bytes,
    unicode_density=burst_fixture.unicode_density,
)
burst_revisions = [
    BENCH.gen_burst_revision(burst_source, revision)
    for revision in range(burst_fixture.burst_count)
]
assert all(
    len(revision.encode("utf-8")) == len(burst_source.encode("utf-8"))
    for revision in burst_revisions
)
assert all(revision.encode("utf-8").decode("utf-8") == revision for revision in burst_revisions)
assert len({revision for revision in burst_revisions}) == burst_fixture.burst_count

fanout = BENCH.INDEPENDENT_FIXTURES["dependency_fanout"]
assert [fixture.fanout_documents for fixture in fanout] == [1, 8, 32]
assert len(
    {
        BENCH.fixture_source_metrics(
            BENCH.gen_fixture_doc(
                fixture.functions,
                target_bytes=fixture.target_bytes,
                unicode_density=fixture.unicode_density,
            )
        )["sha256"]
        for fixture in fanout
    }
) == 1

assert BENCH.count_document_symbols(
    [{"name": "outer", "children": [{"name": "inner"}]}]
) == 2

print("benchmark corpus OK: independent byte, symbol, Unicode, fanout, and burst controls")
