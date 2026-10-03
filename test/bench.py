#!/usr/bin/env python3
"""Reproducible B04 LSP baseline measurements.

Run from any directory with:

    python3 test/bench.py --out bench/results.json

The default fixture sizes are 100, 1,000, and 5,000 functions. Each measured
scenario gets a fresh server process. Its wall time is the operation's client
round-trip (except startup, which includes process launch through the initialize
response). CPU and peak RSS are measured for that scenario's entire server
process lifetime, including setup requests. A separate bounded storage soak
repeats open/change/close with distinct URIs and records the private server
storage counters after every operation. Results are observations, not
performance pass/fail gates. When more than one sample is requested, every
summary includes a nearest-rank p95 so tail latency is visible alongside the
minimum and median. A one-sample run reports that sample as p95 and is still
only an observation. The historical matrix is unchanged; ``--dimensions``
adds one independent workload axis at a time for source bytes, declaration /
symbol count, document fanout, Unicode density, or edit-burst rate. The
dependency-fanout case is explicitly a multi-document surrogate while
workspace dependency resolution is unavailable. The benchmark refuses a stale
server/build manifest by default; use ``--allow-stale`` only for diagnostics,
never for a release comparison.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import hashlib
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import time
from typing import Any

try:
    import resource
except ImportError:  # pragma: no cover - unavailable on some platforms
    resource = None


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, "build", "elisa-lsp")
MANIFEST = os.path.join(ROOT, "build", "manifest.json")
SCENARIOS = ("startup", "clean_open", "edit", "cached_tokens", "hover")
DEFAULT_SIZES = (100, 1000, 5000)
DIMENSION_NAMES = (
    "source_size",
    "symbols",
    "dependency_fanout",
    "unicode_density",
    "edit_burst",
)


class FixtureSpec:
    """A benchmark fixture with independently recorded workload controls.

    ``functions`` is the number of repeated top-level declarations.  The
    optional byte target is filled with comments, so source-size and Unicode
    experiments can hold declaration count constant.  A fixture is always
    generated locally and deterministically; it is never read from or written
    to the user's project.
    """

    __slots__ = (
        "name",
        "functions",
        "target_bytes",
        "unicode_density",
        "fanout_documents",
        "burst_count",
    )

    def __init__(
        self,
        name: str,
        functions: int,
        target_bytes: int | None = None,
        unicode_density: float = 0.0,
        fanout_documents: int = 1,
        burst_count: int = 1,
    ) -> None:
        self.name = name
        self.functions = functions
        self.target_bytes = target_bytes
        self.unicode_density = unicode_density
        self.fanout_documents = fanout_documents
        self.burst_count = burst_count


# These are deliberately modest opt-in cases.  The ordinary B04 matrix keeps
# its historical declaration-size cases; ``--dimensions`` adds one axis at a
# time so a run can attribute a change to a workload property instead of to a
# combinatorial matrix.  The fixed byte targets are large enough for every
# declaration count in their axis and are checked when the fixture is built.
INDEPENDENT_FIXTURES: dict[str, tuple[FixtureSpec, ...]] = {
    "source_size": (
        FixtureSpec("4KiB", functions=64, target_bytes=4 * 1024),
        FixtureSpec("64KiB", functions=64, target_bytes=64 * 1024),
        FixtureSpec("256KiB", functions=64, target_bytes=256 * 1024),
    ),
    "symbols": (
        FixtureSpec("8-functions", functions=8, target_bytes=64 * 1024),
        FixtureSpec("64-functions", functions=64, target_bytes=64 * 1024),
        FixtureSpec("256-functions", functions=256, target_bytes=64 * 1024),
    ),
    "dependency_fanout": (
        FixtureSpec("1-document", functions=16, target_bytes=16 * 1024, fanout_documents=1),
        FixtureSpec("8-documents", functions=16, target_bytes=16 * 1024, fanout_documents=8),
        FixtureSpec("32-documents", functions=16, target_bytes=16 * 1024, fanout_documents=32),
    ),
    "unicode_density": (
        FixtureSpec("ascii", functions=64, target_bytes=64 * 1024, unicode_density=0.0),
        FixtureSpec("mixed", functions=64, target_bytes=64 * 1024, unicode_density=0.35),
        FixtureSpec("unicode-heavy", functions=64, target_bytes=64 * 1024, unicode_density=0.85),
    ),
    "edit_burst": (
        FixtureSpec("4-edits", functions=64, target_bytes=64 * 1024, burst_count=4),
        FixtureSpec("32-edits", functions=64, target_bytes=64 * 1024, burst_count=32),
        FixtureSpec("128-edits", functions=64, target_bytes=64 * 1024, burst_count=128),
    ),
}


class _DarwinRusageInfoV2(ctypes.Structure):
    """The public libproc rusage_info_v2 layout used for live child RSS."""

    _fields_ = [
        ("ri_uuid", ctypes.c_ubyte * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
    ]


class BenchmarkError(RuntimeError):
    pass


def nearest_rank(values: list[float | int], quantile: float) -> float | int:
    """Return a deterministic nearest-rank quantile for non-empty samples.

    Nearest-rank keeps the result independent of interpolation libraries and
    makes small benchmark runs easy to reproduce: rank 1 is the minimum and
    rank ``ceil(q * n)`` is selected. The 0 and 1 endpoints are supported so
    callers can use the same helper for p50, p95, or extrema.
    """
    if not values:
        raise ValueError("quantile requires at least one value")
    if not 0.0 <= quantile <= 1.0:
        raise ValueError("quantile must be between 0 and 1")
    ordered = sorted(values)
    rank = max(1, math.ceil(quantile * len(ordered)))
    return ordered[min(len(ordered), rank) - 1]


def distribution_summary(
    values: list[float | int], *, decimals: int | None = None
) -> dict[str, float | int]:
    """Summarize a measured distribution without hiding the upper tail."""
    if not values:
        raise ValueError("distribution requires at least one value")

    def maybe_round(value: float | int) -> float | int:
        return round(value, decimals) if decimals is not None else value

    median = statistics.median(values)
    return {
        "sample_count": len(values),
        "min": maybe_round(min(values)),
        "median": maybe_round(median),
        "p95": maybe_round(nearest_rank(values, 0.95)),
        "max": maybe_round(max(values)),
    }


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def frame(message: dict[str, Any]) -> bytes:
    body = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode(
        "utf-8"
    )
    return b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body


def gen_doc(functions: int) -> str:
    """Generate a deterministic declaration-heavy Elisa source fixture."""
    rows: list[str] = []
    for i in range(functions):
        rows.append(f"def f{i}(x: i64) -> i64:")
        rows.append(f"    y: i64 = x + {i}")
        rows.append("    return y")
    return "\n".join(rows) + "\n"


def _fixture_padding(remaining_bytes: int, unicode_density: float) -> bytes:
    """Return valid UTF-8 comment bytes of exactly ``remaining_bytes``.

    Padding is deliberately a comment.  It changes lexer/position work and
    source bytes without adding declarations or changing the semantic result.
    The final ASCII run is also an edit-safe region for the burst benchmark.
    """
    if remaining_bytes < 0:
        raise ValueError("fixture target is smaller than its declaration source")
    if remaining_bytes == 0:
        return b""
    if remaining_bytes == 1:
        return b"#"

    density = float(unicode_density)
    if not math.isfinite(density) or not 0.0 <= density <= 1.0:
        raise ValueError("unicode density must be finite and between 0 and 1")

    # Keep the marker separate from the payload.  The ASCII tail is retained
    # even for a Unicode-heavy fixture so edit_burst can change a comment byte
    # without ever touching Elisa code or splitting a UTF-8 sequence.
    payload_bytes = remaining_bytes - 1
    unicode_pattern = "λé🌍".encode("utf-8")
    wanted_unicode_bytes = int(payload_bytes * density)
    unicode_bytes = wanted_unicode_bytes - (wanted_unicode_bytes % len(unicode_pattern))
    unicode_part = unicode_pattern * (unicode_bytes // len(unicode_pattern))
    ascii_part = b"x" * (payload_bytes - len(unicode_part))
    result = b"#" + unicode_part + ascii_part
    if len(result) != remaining_bytes:
        raise AssertionError("fixture padding length calculation drifted")
    result.decode("utf-8")
    return result


def gen_fixture_doc(
    functions: int,
    *,
    target_bytes: int | None = None,
    unicode_density: float = 0.0,
) -> str:
    """Generate a deterministic, valid source fixture for one benchmark axis.

    With no byte target and zero Unicode density this is exactly the original
    B04 fixture.  With a target, comments pad the UTF-8 byte length exactly;
    this is what lets symbol-count and Unicode-density runs vary one control
    while keeping the other measured dimensions stable.
    """
    if functions <= 0:
        raise ValueError("fixture function count must be positive")
    base = gen_doc(functions)
    if target_bytes is None:
        if unicode_density == 0.0:
            return base
        target_bytes = len(base.encode("utf-8")) + 4096
    if target_bytes <= 0:
        raise ValueError("fixture target byte count must be positive")
    base_bytes = base.encode("utf-8")
    if target_bytes < len(base_bytes):
        raise ValueError(
            f"fixture target {target_bytes} is smaller than declaration source {len(base_bytes)}"
        )
    raw = base_bytes + _fixture_padding(target_bytes - len(base_bytes), unicode_density)
    if len(raw) != target_bytes:
        raise AssertionError("generated fixture did not reach its requested byte size")
    return raw.decode("utf-8")


def fixture_source_metrics(source: str) -> dict[str, int | float]:
    """Return measured byte/code-point/Unicode dimensions for a fixture."""
    raw = source.encode("utf-8")
    non_ascii_codepoints = sum(1 for character in source if ord(character) > 127)
    non_ascii_bytes = sum(
        len(character.encode("utf-8")) for character in source if ord(character) > 127
    )
    return {
        "bytes": len(raw),
        "lines": source.count("\n"),
        "codepoints": len(source),
        "non_ascii_codepoints": non_ascii_codepoints,
        "non_ascii_bytes": non_ascii_bytes,
        "unicode_codepoint_density": round(
            non_ascii_codepoints / len(source), 6
        )
        if source
        else 0.0,
        "unicode_byte_density": round(non_ascii_bytes / len(raw), 6) if raw else 0.0,
        "sha256": sha256(raw),
    }


def gen_burst_revision(source: str, revision: int) -> str:
    """Change one padding byte while preserving source size and UTF-8 validity."""
    marker = source.rfind("\n#")
    if marker < 0:
        raise ValueError("edit-burst fixture has no comment padding")
    candidates = [
        index
        for index in range(marker + 2, len(source))
        if source[index] == "x"
    ]
    if not candidates:
        raise ValueError("edit-burst fixture has no ASCII edit-safe padding")
    index = candidates[revision % len(candidates)]
    replacement = chr(ord("a") + (revision % 26))
    if replacement == "x":
        replacement = "y"
    return source[:index] + replacement + source[index + 1 :]


def count_document_symbols(value: Any) -> int:
    """Count hierarchical DocumentSymbol entries without trusting shape."""
    if not isinstance(value, list):
        raise BenchmarkError("textDocument/documentSymbol returned a non-list result")
    total = 0
    for item in value:
        if not isinstance(item, dict):
            raise BenchmarkError("documentSymbol result contains a non-object entry")
        total += 1
        children = item.get("children")
        if children is not None:
            total += count_document_symbols(children)
    return total


class LspSession:
    """Small synchronous JSON-RPC client with framed, ID-matched responses."""

    def __init__(self, timeout_s: float):
        self.timeout_s = timeout_s
        self.process_started = time.perf_counter()
        self.proc = subprocess.Popen(
            [SERVER],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
        )
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.stdin = self.proc.stdin
        self.stdout = self.proc.stdout
        self.read_buffer = bytearray()
        self.next_id = 1

    def send(self, message: dict[str, Any]) -> None:
        try:
            self.stdin.write(frame(message))
            self.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise BenchmarkError(f"server closed its input: {exc}") from exc

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        message: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def _read_frame(self) -> dict[str, Any]:
        import select

        deadline = time.perf_counter() + self.timeout_s
        marker = b"\r\n\r\n"
        while True:
            header_end = self.read_buffer.find(marker)
            if header_end >= 0:
                header = bytes(self.read_buffer[:header_end])
                length = None
                for line in header.split(b"\r\n"):
                    key, separator, value = line.partition(b":")
                    if separator and key.strip().lower() == b"content-length":
                        try:
                            length = int(value.strip())
                        except ValueError as exc:
                            raise BenchmarkError("server sent invalid Content-Length") from exc
                if length is None or length < 0:
                    raise BenchmarkError("server response omitted a valid Content-Length")
                body_start = header_end + len(marker)
                body_end = body_start + length
                if len(self.read_buffer) >= body_end:
                    body = bytes(self.read_buffer[body_start:body_end])
                    del self.read_buffer[:body_end]
                    try:
                        message = json.loads(body)
                    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                        raise BenchmarkError(f"server sent invalid JSON: {exc}") from exc
                    if not isinstance(message, dict):
                        raise BenchmarkError("server response was not a JSON object")
                    return message

            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                raise BenchmarkError("timed out waiting for a server response")
            ready, _, _ = select.select([self.stdout.fileno()], [], [], remaining)
            if not ready:
                raise BenchmarkError("timed out waiting for a server response")
            chunk = os.read(self.stdout.fileno(), 65536)
            if not chunk:
                status = self.proc.poll()
                raise BenchmarkError(
                    f"server closed stdout before replying (exit status {status})"
                )
            self.read_buffer.extend(chunk)

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        message: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
        }
        if params is not None:
            message["params"] = params
        self.send(message)
        while True:
            response = self._read_frame()
            if response.get("id") != request_id:
                # Notifications such as publishDiagnostics are expected while
                # waiting for a request response and are discarded here.
                continue
            if "error" in response:
                raise BenchmarkError(
                    f"{method} returned JSON-RPC error: {response['error']}"
                )
            return response

    def initialize(self) -> dict[str, Any]:
        response = self.request("initialize", {"capabilities": {}})
        self.notify("initialized", {})
        return response

    def finish(self) -> float:
        """Perform a clean LSP shutdown and return server-process wall time."""
        if self.proc.poll() is None:
            self.request("shutdown")
            self.notify("exit")
        try:
            self.stdin.close()
        except OSError:
            pass
        try:
            status = self.proc.wait(timeout=self.timeout_s)
        except subprocess.TimeoutExpired as exc:
            self.proc.kill()
            self.proc.wait()
            raise BenchmarkError("server did not exit after shutdown") from exc
        self.stdout.close()
        if status != 0:
            raise BenchmarkError(f"server exited with status {status}")
        return time.perf_counter() - self.process_started

    def abort(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        for stream in (self.stdin, self.stdout):
            try:
                stream.close()
            except OSError:
                pass


def document_params(uri: str, text: str, version: int = 1) -> dict[str, Any]:
    return {
        "textDocument": {
            "uri": uri,
            "languageId": "elisa",
            "version": version,
            "text": text,
        }
    }


def token_count(response: dict[str, Any]) -> int:
    result = response.get("result")
    data = result.get("data") if isinstance(result, dict) else None
    if not isinstance(data, list) or len(data) % 5:
        raise BenchmarkError("semanticTokens/full returned malformed token data")
    return len(data) // 5


def process_metrics() -> dict[str, Any]:
    """Read metrics for this worker's sole child (the LSP server)."""
    result: dict[str, Any] = {
        "cpu_user_s": None,
        "cpu_system_s": None,
        "cpu_total_s": None,
        "peak_rss_bytes": None,
        "cpu_rss_scope": "server process lifetime, including scenario setup",
    }
    if resource is None:
        return result
    try:
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    except (AttributeError, OSError, ValueError):
        return result

    user = float(usage.ru_utime)
    system = float(usage.ru_stime)
    result["cpu_user_s"] = round(user, 6)
    result["cpu_system_s"] = round(system, 6)
    result["cpu_total_s"] = round(user + system, 6)

    try:
        rss = int(usage.ru_maxrss)
        # Darwin reports bytes; Linux and the common BSD resource interfaces
        # report kibibytes. Normalize the schema to bytes.
        if sys.platform != "darwin":
            rss *= 1024
        result["peak_rss_bytes"] = rss
    except (AttributeError, TypeError, ValueError, OverflowError):
        pass
    return result


def current_rss_bytes(pid: int) -> tuple[int | None, str]:
    """Read a live process's resident set without spawning a measurement helper."""
    if pid <= 0:
        return None, "unavailable"
    if sys.platform == "darwin":
        try:
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
            proc_pid_rusage = libproc.proc_pid_rusage
            proc_pid_rusage.argtypes = [
                ctypes.c_int,
                ctypes.c_int,
                ctypes.POINTER(_DarwinRusageInfoV2),
            ]
            proc_pid_rusage.restype = ctypes.c_int
            usage = _DarwinRusageInfoV2()
            if proc_pid_rusage(pid, 2, ctypes.byref(usage)) == 0:
                return int(usage.ri_resident_size), "libproc.proc_pid_rusage:RUSAGE_INFO_V2"
        except (AttributeError, OSError, TypeError, ValueError):
            pass
        return None, "unavailable"

    if sys.platform.startswith("linux"):
        try:
            with open(f"/proc/{pid}/statm", "r", encoding="ascii") as statm:
                fields = statm.read().split()
            if len(fields) >= 2:
                resident_pages = int(fields[1])
                page_bytes = int(os.sysconf("SC_PAGE_SIZE"))
                if resident_pages >= 0 and page_bytes > 0:
                    return resident_pages * page_bytes, "/proc/<pid>/statm:resident_pages"
        except (OSError, ValueError, OverflowError):
            pass
        return None, "unavailable"

    return None, "unavailable"


def resident_set_sample(
    session: LspSession,
    cycle: int,
    phase: str,
    stats: dict[str, int],
) -> dict[str, Any]:
    """Pair a sparse live RSS reading with the LSP's logical-storage counters."""
    pid = session.proc.pid if session.proc is not None else -1
    rss_bytes, source = current_rss_bytes(pid)
    return {
        "cycle": cycle,
        "phase": phase,
        "rss_bytes": rss_bytes,
        "source": source,
        "storage_stats": {key: stats[key] for key in STORAGE_COUNTERS},
    }


def sampled_rss_summary(samples: list[dict[str, Any]]) -> dict[str, int | None]:
    values = [sample["rss_bytes"] for sample in samples if sample["rss_bytes"] is not None]
    warmup = next(
        (sample["rss_bytes"] for sample in samples if sample["phase"] == "after_warmup_close"),
        None,
    )
    final = samples[-1]["rss_bytes"] if samples else None
    return {
        "initial_bytes": samples[0]["rss_bytes"] if samples else None,
        "after_warmup_bytes": warmup,
        "final_bytes": final,
        "peak_sampled_bytes": max(values) if values else None,
        "p95_sampled_bytes": (
            nearest_rank(values, 0.95) if values else None
        ),
        "sample_count": len(values),
        "delta_from_warmup_bytes": (
            final - warmup
            if final is not None and warmup is not None
            else None
        ),
    }


def run_scenario(
    functions: int,
    scenario: str,
    timeout_s: float,
    *,
    target_bytes: int | None = None,
    unicode_density: float = 0.0,
    fanout_documents: int = 1,
    burst_count: int = 1,
) -> dict[str, Any]:
    text = gen_fixture_doc(
        functions,
        target_bytes=target_bytes,
        unicode_density=unicode_density,
    )
    uri = f"file:///bench-{functions}.elisa"
    edited = text + "def extra() -> i64:\n    return 1\n"
    session = LspSession(timeout_s)
    metric: dict[str, Any] = {}
    try:
        if scenario == "startup":
            operation_started = session.process_started
            session.initialize()
            metric["wall_s"] = round(time.perf_counter() - operation_started, 6)
        else:
            session.initialize()

            if scenario == "clean_open":
                operation_started = time.perf_counter()
                session.notify("textDocument/didOpen", document_params(uri, text))
                response = session.request(
                    "textDocument/semanticTokens/full",
                    {"textDocument": {"uri": uri}},
                )
                metric["token_count"] = token_count(response)
                metric["wall_s"] = round(time.perf_counter() - operation_started, 6)

            elif scenario == "edit":
                session.notify("textDocument/didOpen", document_params(uri, text))
                session.request(
                    "textDocument/semanticTokens/full",
                    {"textDocument": {"uri": uri}},
                )
                operation_started = time.perf_counter()
                session.notify(
                    "textDocument/didChange",
                    {
                        "textDocument": {"uri": uri, "version": 2},
                        "contentChanges": [{"text": edited}],
                    },
                )
                response = session.request(
                    "textDocument/semanticTokens/full",
                    {"textDocument": {"uri": uri}},
                )
                metric["token_count"] = token_count(response)
                metric["wall_s"] = round(time.perf_counter() - operation_started, 6)

            elif scenario == "cached_tokens":
                session.notify("textDocument/didOpen", document_params(uri, text))
                warm = session.request(
                    "textDocument/semanticTokens/full",
                    {"textDocument": {"uri": uri}},
                )
                warm_count = token_count(warm)
                operation_started = time.perf_counter()
                response = session.request(
                    "textDocument/semanticTokens/full",
                    {"textDocument": {"uri": uri}},
                )
                metric["token_count"] = token_count(response)
                if metric["token_count"] != warm_count:
                    raise BenchmarkError("cached semantic token count changed without an edit")
                metric["wall_s"] = round(time.perf_counter() - operation_started, 6)

            elif scenario == "hover":
                session.notify("textDocument/didOpen", document_params(uri, text))
                operation_started = time.perf_counter()
                response = session.request(
                    "textDocument/hover",
                    {
                        "textDocument": {"uri": uri},
                        "position": {"line": 1, "character": 5},
                    },
                )
                metric["wall_s"] = round(time.perf_counter() - operation_started, 6)
                metric["has_result"] = response.get("result") is not None

            elif scenario == "symbol_count":
                session.notify("textDocument/didOpen", document_params(uri, text))
                operation_started = time.perf_counter()
                response = session.request(
                    "textDocument/documentSymbol",
                    {"textDocument": {"uri": uri}},
                )
                metric["wall_s"] = round(time.perf_counter() - operation_started, 6)
                metric["symbol_count"] = count_document_symbols(response.get("result"))

            elif scenario == "fanout":
                if fanout_documents <= 0:
                    raise BenchmarkError("document fanout must be positive")
                operation_started = time.perf_counter()
                uris = [
                    f"file:///bench-fanout-{index}.elisa"
                    for index in range(fanout_documents)
                ]
                for fanout_uri in uris:
                    session.notify(
                        "textDocument/didOpen",
                        document_params(fanout_uri, text),
                    )
                total_tokens = 0
                for fanout_uri in uris:
                    response = session.request(
                        "textDocument/semanticTokens/full",
                        {"textDocument": {"uri": fanout_uri}},
                    )
                    total_tokens += token_count(response)
                metric["wall_s"] = round(time.perf_counter() - operation_started, 6)
                metric["fanout_documents"] = fanout_documents
                metric["total_token_count"] = total_tokens

            elif scenario == "edit_burst":
                if burst_count <= 0:
                    raise BenchmarkError("edit burst count must be positive")
                session.notify("textDocument/didOpen", document_params(uri, text))
                session.request(
                    "textDocument/semanticTokens/full",
                    {"textDocument": {"uri": uri}},
                )
                operation_wall_s: list[float] = []
                last_token_count = 0
                for revision in range(burst_count):
                    burst_source = gen_burst_revision(text, revision)
                    operation_started = time.perf_counter()
                    session.notify(
                        "textDocument/didChange",
                        {
                            "textDocument": {"uri": uri, "version": revision + 2},
                            "contentChanges": [{"text": burst_source}],
                        },
                    )
                    response = session.request(
                        "textDocument/semanticTokens/full",
                        {"textDocument": {"uri": uri}},
                    )
                    last_token_count = token_count(response)
                    operation_wall_s.append(time.perf_counter() - operation_started)
                metric["wall_s"] = round(sum(operation_wall_s), 6)
                metric["burst_count"] = burst_count
                metric["token_count"] = last_token_count
                metric["burst_operation_wall_s"] = [
                    round(value, 6) for value in operation_wall_s
                ]

            else:  # pragma: no cover - guarded by CLI/schema
                raise BenchmarkError(f"unknown scenario {scenario}")

        metric["server_process_wall_s"] = round(session.finish(), 6)
        metric.update(process_metrics())
        return metric
    except BaseException:
        session.abort()
        raise


STORAGE_COUNTERS = (
    "storage_bytes",
    "storage_capacity",
    "live_bytes",
    "dead_storage_bytes",
    "documents",
    "documents_capacity",
    "open",
    "open_uri_bytes",
    "open_source_bytes",
    "derived_cache_bytes",
    "max_document_cache_bytes",
)


def read_storage_stats(session: LspSession) -> dict[str, int]:
    """Read the server's private storage probe and validate its stable shape."""
    response = session.request("$/elisa/stats", {})
    result = response.get("result")
    if not isinstance(result, dict):
        raise BenchmarkError("$/elisa/stats returned a non-object result")
    counters: dict[str, int] = {}
    for key in STORAGE_COUNTERS:
        value = result.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise BenchmarkError(f"$/elisa/stats returned invalid {key}: {value!r}")
        counters[key] = value
    snapshots = result.get("snapshots")
    if not isinstance(snapshots, dict):
        raise BenchmarkError("$/elisa/stats returned an invalid snapshots object")
    for key in ("open", "pending", "ready", "failed"):
        value = snapshots.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise BenchmarkError(f"$/elisa/stats returned invalid snapshots.{key}: {value!r}")
        counters[f"snapshot_{key}"] = value
    line_index = result.get("line_index")
    if not isinstance(line_index, dict):
        raise BenchmarkError("$/elisa/stats returned an invalid line_index object")
    for key in ("entries", "cached_documents", "stored_entries", "capacity_entries", "build_calls", "fallback_build_calls"):
        value = line_index.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise BenchmarkError(f"$/elisa/stats returned invalid line_index.{key}: {value!r}")
        counters[f"line_index_{key}"] = value
    if counters["storage_capacity"] < counters["storage_bytes"]:
        raise BenchmarkError("$/elisa/stats reported storage capacity below its byte count")
    if counters["documents_capacity"] < counters["documents"]:
        raise BenchmarkError("$/elisa/stats reported document capacity below its slot count")
    if counters["line_index_capacity_entries"] < counters["line_index_stored_entries"]:
        raise BenchmarkError("$/elisa/stats reported line-index capacity below its stored entries")
    if counters["line_index_stored_entries"] > 1_048_576:
        raise BenchmarkError("$/elisa/stats exceeded the retained line-index entry budget")
    if counters["storage_bytes"] != counters["live_bytes"] + counters["dead_storage_bytes"]:
        raise BenchmarkError("$/elisa/stats returned inconsistent live/dead storage accounting")
    if counters["snapshot_open"] != counters["open"]:
        raise BenchmarkError("$/elisa/stats returned inconsistent open snapshot count")
    if counters["snapshot_pending"] + counters["snapshot_ready"] + counters["snapshot_failed"] != counters["open"]:
        raise BenchmarkError("$/elisa/stats returned inconsistent analysis-state snapshot counts")
    if counters["derived_cache_bytes"] > counters["live_bytes"]:
        raise BenchmarkError("$/elisa/stats returned more cache bytes than live document storage")
    if counters["max_document_cache_bytes"] > counters["derived_cache_bytes"]:
        raise BenchmarkError("$/elisa/stats returned a per-document cache larger than aggregate caches")
    if counters["live_bytes"] != (
        counters["open_uri_bytes"] + counters["open_source_bytes"]
        + counters["derived_cache_bytes"] + counters["open"]
    ):
        raise BenchmarkError("$/elisa/stats returned inconsistent live-storage component totals")
    return counters


def run_storage_soak(
    functions: int, cycles: int, timeout_s: float
) -> dict[str, Any]:
    """Measure bounded document-storage churn in one long-lived server process.

    Each cycle opens a fresh URI, changes its contents to a slightly larger
    deterministic revision, then closes it. A stats request after each
    operation records live document/storage state. Sparse live RSS readings
    correlate allocator/process memory with the same logical-storage counters;
    they are diagnostic observations, not a leak threshold.
    """
    text = gen_doc(functions)
    # The edit forces replacement/growth while remaining bounded independently
    # of cycle count. Use comments so source semantics remain deterministic.
    edited = text + "# bounded storage-soak edit\n" * 64
    session = LspSession(timeout_s)
    stats_samples: list[dict[str, Any]] = []
    rss_samples: list[dict[str, Any]] = []
    rss_sample_interval = max(1, (cycles + 7) // 8)
    operation_samples: dict[str, list[float]] = {
        "open": [],
        "change": [],
        "close": [],
    }
    soak_started = 0.0
    try:
        session.initialize()
        soak_started = time.perf_counter()
        initial_stats = read_storage_stats(session)
        rss_samples.append(
            resident_set_sample(session, 0, "after_initialize", initial_stats)
        )
        for cycle in range(cycles):
            uri = f"file:///bench-storage-soak-{cycle}.elisa"

            started = time.perf_counter()
            session.notify(
                "textDocument/didOpen",
                document_params(uri, text, version=1),
            )
            stats = read_storage_stats(session)
            elapsed = time.perf_counter() - started
            operation_samples["open"].append(elapsed)
            stats_samples.append(
                {
                    "cycle": cycle + 1,
                    "phase": "after_open",
                    **stats,
                    "wall_s": round(elapsed, 6),
                }
            )

            started = time.perf_counter()
            session.notify(
                "textDocument/didChange",
                {
                    "textDocument": {"uri": uri, "version": 2},
                    "contentChanges": [{"text": edited}],
                },
            )
            stats = read_storage_stats(session)
            elapsed = time.perf_counter() - started
            operation_samples["change"].append(elapsed)
            stats_samples.append(
                {
                    "cycle": cycle + 1,
                    "phase": "after_change",
                    **stats,
                    "wall_s": round(elapsed, 6),
                }
            )

            started = time.perf_counter()
            session.notify(
                "textDocument/didClose",
                {"textDocument": {"uri": uri}},
            )
            stats = read_storage_stats(session)
            elapsed = time.perf_counter() - started
            operation_samples["close"].append(elapsed)
            stats_samples.append(
                {
                    "cycle": cycle + 1,
                    "phase": "after_close",
                    **stats,
                    "wall_s": round(elapsed, 6),
                }
            )
            completed_cycles = cycle + 1
            if (
                completed_cycles == 1
                or completed_cycles % rss_sample_interval == 0
                or completed_cycles == cycles
            ):
                phase = "after_warmup_close" if completed_cycles == 1 else "after_close_batch"
                rss_samples.append(
                    resident_set_sample(session, completed_cycles, phase, stats)
                )

        soak_wall_s = time.perf_counter() - soak_started
        final_stats = {key: stats_samples[-1][key] for key in STORAGE_COUNTERS}
        peak_stats = {
            key: max(sample[key] for sample in stats_samples)
            for key in STORAGE_COUNTERS
        }
        metric: dict[str, Any] = {
            "cycles_requested": cycles,
            "cycles_completed": cycles,
            "uri_policy": "one distinct URI per cycle; each document is closed before the next opens",
            "source": {
                "functions": functions,
                "open_bytes": len(text.encode("utf-8")),
                "changed_bytes": len(edited.encode("utf-8")),
                "open_sha256": sha256(text.encode("utf-8")),
                "changed_sha256": sha256(edited.encode("utf-8")),
            },
            "operation_wall_s": {
                phase: {
                    **distribution_summary(values, decimals=6),
                    "total": round(sum(values), 6),
                }
                for phase, values in operation_samples.items()
            },
            "soak_wall_s": round(soak_wall_s, 6),
            "final_stats": final_stats,
            "peak_stats": peak_stats,
            "stats_samples": stats_samples,
            "rss_sampling": {
                "platform": platform.system(),
                "machine": platform.machine(),
                "units": "bytes",
                "interval_cycles": rss_sample_interval,
                "maximum_samples": 10,
                "samples": rss_samples,
                "summary": sampled_rss_summary(rss_samples),
            },
        }
        metric["server_process_wall_s"] = round(session.finish(), 6)
        metric.update(process_metrics())
        return metric
    except BaseException:
        session.abort()
        raise


def worker_main() -> int:
    try:
        request = json.load(sys.stdin)
        scenario = str(request["scenario"])
        functions = int(request["functions"])
        timeout_s = float(request["timeout_s"])
        target_raw = request.get("target_bytes")
        target_bytes = None if target_raw is None else int(target_raw)
        unicode_density = float(request.get("unicode_density", 0.0))
        fanout_documents = int(request.get("fanout_documents", 1))
        burst_count = int(request.get("burst_count", 1))
        if scenario == "storage_soak":
            result = run_storage_soak(
                functions,
                int(request["soak_cycles"]),
                timeout_s,
            )
        else:
            result = run_scenario(
                functions,
                scenario,
                timeout_s,
                target_bytes=target_bytes,
                unicode_density=unicode_density,
                fanout_documents=fanout_documents,
                burst_count=burst_count,
            )
        json.dump(result, sys.stdout, separators=(",", ":"))
        sys.stdout.write("\n")
        return 0
    except Exception as exc:
        json.dump({"error": f"{type(exc).__name__}: {exc}"}, sys.stdout)
        sys.stdout.write("\n")
        return 1


def sha256_file(path: str) -> str | None:
    try:
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        return digest.hexdigest()
    except OSError:
        return None


def git_metadata() -> dict[str, Any]:
    def git(*args: str) -> str | None:
        try:
            return subprocess.check_output(
                ["git", *args], cwd=ROOT, stderr=subprocess.DEVNULL, text=True
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            return None

    status = git("status", "--porcelain")
    return {
        "head": git("rev-parse", "HEAD"),
        "working_tree_dirty": None if status is None else bool(status),
    }


def verify_freshness(*, allow_stale: bool) -> dict[str, Any]:
    """Require the measured executable to match the current build inputs."""
    checker = os.path.join(ROOT, "scripts", "check_build_freshness.py")
    command = [
        sys.executable,
        checker,
        "--root",
        ROOT,
        "--binary",
        SERVER,
        "--manifest",
        MANIFEST,
    ]
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        if not allow_stale:
            raise BenchmarkError(f"could not run build freshness check: {exc}") from exc
        return {
            "checked": False,
            "fresh": False,
            "allow_stale": True,
            "detail": str(exc),
        }
    detail = (completed.stdout + completed.stderr).strip()
    report = {
        "checked": True,
        "fresh": completed.returncode == 0,
        "allow_stale": allow_stale,
        "detail": detail[-2000:] if detail else None,
    }
    if completed.returncode != 0 and not allow_stale:
        raise BenchmarkError(
            "refusing to benchmark a stale LSP executable; rebuild with bash build.sh\n"
            + (detail[-2000:] if detail else "freshness checker returned a failure")
        )
    return report


def provenance(*, allow_stale: bool = False) -> dict[str, Any]:
    if not os.path.isfile(SERVER):
        raise BenchmarkError(f"server executable not found: {SERVER}; build it first")
    freshness = verify_freshness(allow_stale=allow_stale)
    try:
        with open(MANIFEST, "rb") as stream:
            manifest_bytes = stream.read()
        manifest = json.loads(manifest_bytes)
    except FileNotFoundError:
        manifest_bytes = None
        manifest = None
    except (OSError, json.JSONDecodeError) as exc:
        raise BenchmarkError(f"could not read build manifest {MANIFEST}: {exc}") from exc

    stat = os.stat(SERVER)
    return {
        "server": {
            "path": os.path.realpath(SERVER),
            "sha256": sha256_file(SERVER),
            "size_bytes": stat.st_size,
            "mtime_utc": dt.datetime.fromtimestamp(
                stat.st_mtime, dt.timezone.utc
            ).isoformat(timespec="seconds").replace("+00:00", "Z"),
        },
        "manifest": {
            "path": os.path.realpath(MANIFEST),
            "sha256": None if manifest_bytes is None else sha256(manifest_bytes),
            "data": manifest,
        },
        "freshness": freshness,
        "toolchain": {
            "python": sys.version.split()[0],
            "platform": platform.platform(),
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "processor": platform.processor() or None,
            "lsp_git": git_metadata(),
            "build_manifest_fields": {
                key: (manifest or {}).get(key)
                for key in (
                    "built_at_utc",
                    "profile",
                    "opt",
                    "elisac",
                    "compiler_root",
                    "compiler_rev",
                    "clang",
                    "target_triple",
                    "os_arch",
                    "lsp_rev",
                )
            },
        },
    }


def summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    keys = (
        "wall_s",
        "server_process_wall_s",
        "cpu_user_s",
        "cpu_system_s",
        "cpu_total_s",
        "peak_rss_bytes",
    )
    summary: dict[str, Any] = {}
    for key in keys:
        values = [sample[key] for sample in samples if sample.get(key) is not None]
        if values:
            summary[key] = distribution_summary(values)
        else:
            summary[key] = None
    return summary


def run_sample(
    functions: int,
    scenario: str,
    timeout_s: float,
    soak_cycles: int | None = None,
    *,
    target_bytes: int | None = None,
    unicode_density: float = 0.0,
    fanout_documents: int = 1,
    burst_count: int = 1,
) -> dict[str, Any]:
    worker_request: dict[str, Any] = {
        "functions": functions,
        "scenario": scenario,
        "timeout_s": timeout_s,
        "target_bytes": target_bytes,
        "unicode_density": unicode_density,
        "fanout_documents": fanout_documents,
        "burst_count": burst_count,
    }
    if soak_cycles is not None:
        worker_request["soak_cycles"] = soak_cycles
    payload = json.dumps(worker_request).encode("utf-8")
    worker_timeout_s = timeout_s * 2 + 15
    if soak_cycles is not None:
        # Each cycle waits for one stats response after open/change/close.
        worker_timeout_s = timeout_s * (soak_cycles * 3 + 2) + 15
    elif scenario == "edit_burst":
        # Every revision performs a bounded change plus a semantic-token
        # response; do not let the parent worker timeout erase the dimension's
        # own per-request timeout contract.
        worker_timeout_s = timeout_s * (burst_count + 2) + 15
    elif scenario == "fanout":
        # Each document is analyzed on didOpen and then queried once.
        worker_timeout_s = timeout_s * (fanout_documents * 2 + 2) + 15
    try:
        completed = subprocess.run(
            [sys.executable, os.path.abspath(__file__), "--_worker"],
            input=payload,
            capture_output=True,
            timeout=worker_timeout_s,
            cwd=ROOT,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise BenchmarkError(f"benchmark worker timed out for {scenario}") from exc
    try:
        result = json.loads(completed.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        detail = completed.stderr.decode("utf-8", "replace")[-1000:]
        raise BenchmarkError(f"benchmark worker produced invalid output: {detail}") from exc
    if completed.returncode != 0 or "error" in result:
        raise BenchmarkError(result.get("error", "benchmark worker failed"))
    return result


def parse_sizes(value: str) -> list[int]:
    try:
        sizes = [int(part.strip()) for part in value.split(",") if part.strip()]
    except ValueError as exc:
        raise argparse.ArgumentTypeError("sizes must be comma-separated integers") from exc
    if not sizes or any(size <= 0 for size in sizes):
        raise argparse.ArgumentTypeError("sizes must contain positive function counts")
    return sizes


def parse_dimensions(value: str) -> list[str]:
    """Parse a comma-separated list of one-at-a-time benchmark axes."""
    parts = [part.strip() for part in value.split(",") if part.strip()]
    if not parts or parts == ["none"]:
        return []
    if parts == ["all"]:
        return list(DIMENSION_NAMES)
    unknown = [part for part in parts if part not in DIMENSION_NAMES]
    if unknown:
        names = ", ".join(DIMENSION_NAMES)
        raise argparse.ArgumentTypeError(
            f"unknown dimension {unknown[0]!r}; choose from {names}, all, or none"
        )
    if len(set(parts)) != len(parts):
        raise argparse.ArgumentTypeError("dimensions must not contain duplicates")
    return parts


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sizes",
        type=parse_sizes,
        default=list(DEFAULT_SIZES),
        metavar="N[,N...]",
        help="number of functions in each synthetic source fixture",
    )
    parser.add_argument(
        "--dimensions",
        type=parse_dimensions,
        default=[],
        metavar="AXIS[,AXIS...]",
        help=(
            "opt-in independent workload axes: source_size, symbols, "
            "dependency_fanout, unicode_density, edit_burst, all, or none"
        ),
    )
    parser.add_argument(
        "--samples",
        type=int,
        default=1,
        help="independent server-process samples per size and scenario (default: 1)",
    )
    parser.add_argument(
        "--soak-cycles",
        type=int,
        default=20,
        help="open/change/close cycles per storage-soak sample (default: 20)",
    )
    parser.add_argument(
        "--soak-functions",
        type=int,
        default=100,
        help="functions in each bounded storage-soak document (default: 100)",
    )
    parser.add_argument("--timeout", type=float, default=120.0, help="per-scenario timeout in seconds")
    parser.add_argument(
        "--allow-stale",
        action="store_true",
        help=(
            "run only for stale-artifact diagnostics; record the override and "
            "never use the result as a release comparison"
        ),
    )
    parser.add_argument("--out", help="write JSON to this path; default is JSON on stdout")
    return parser


def scenarios_for_dimension(dimension: str) -> tuple[str, ...]:
    if dimension == "dependency_fanout":
        return ("fanout",)
    if dimension == "edit_burst":
        return ("edit_burst",)
    if dimension == "symbols":
        return (*SCENARIOS, "symbol_count")
    return SCENARIOS


def dimension_policy(dimension: str) -> dict[str, Any]:
    """Describe what each independent axis controls and what it cannot prove."""
    policies: dict[str, dict[str, Any]] = {
        "source_size": {
            "controlled": "UTF-8 source byte length",
            "held_constant": "top-level declaration count and Unicode density",
            "scenario": "the ordinary cold/warm request matrix",
        },
        "symbols": {
            "controlled": "repeated function declarations, with returned document-symbol count",
            "held_constant": "UTF-8 source byte length",
            "scenario": "the ordinary matrix plus documentSymbol",
        },
        "dependency_fanout": {
            "controlled": "number of distinct open documents queried in one session",
            "held_constant": "source fixture and per-document declaration count",
            "scenario": "open-document fanout plus semantic-token queries",
            "limitation": (
                "the current LSP has no project dependency resolver; this is an explicit "
                "document-fanout surrogate, not a claim about dependency traversal"
            ),
        },
        "unicode_density": {
            "controlled": "non-ASCII comment density in a fixed-size UTF-8 source",
            "held_constant": "source byte length and declaration count",
            "scenario": "the ordinary cold/warm request matrix",
        },
        "edit_burst": {
            "controlled": "number of back-to-back full-text didChange revisions",
            "held_constant": "initial source fixture and per-edit byte length",
            "scenario": "sequential change plus semantic-token round trips",
        },
    }
    return policies[dimension]


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--_worker":
        return worker_main()

    parser = build_parser()
    args = parser.parse_args()
    if args.samples <= 0:
        parser.error("--samples must be positive")
    if args.soak_cycles <= 0:
        parser.error("--soak-cycles must be positive")
    if args.soak_functions <= 0:
        parser.error("--soak-functions must be positive")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    try:
        prov = provenance(allow_stale=args.allow_stale)
        cases = []
        for functions in args.sizes:
            source = gen_doc(functions).encode("utf-8")
            edited = (source.decode("utf-8") + "def extra() -> i64:\n    return 1\n").encode(
                "utf-8"
            )
            print(
                f"benchmarking functions={functions} source_bytes={len(source)}",
                file=sys.stderr,
                flush=True,
            )
            scenario_data: dict[str, Any] = {}
            for scenario in SCENARIOS:
                samples = []
                for sample_number in range(args.samples):
                    print(
                        f"  {scenario}: sample {sample_number + 1}/{args.samples}",
                        file=sys.stderr,
                        flush=True,
                    )
                    samples.append(run_sample(functions, scenario, args.timeout))
                scenario_data[scenario] = {
                    "samples": samples,
                    "summary": summarize(samples),
                }

            cases.append(
                {
                    "functions": functions,
                    "source": {
                        "lines": functions * 3,
                        "bytes": len(source),
                        "sha256": sha256(source),
                        "edited_bytes": len(edited),
                        "edited_sha256": sha256(edited),
                    },
                    "scenarios": scenario_data,
                }
            )

        independent_dimensions: dict[str, Any] = {}
        for dimension in args.dimensions:
            dimension_cases: list[dict[str, Any]] = []
            print(
                f"independent dimension: {dimension}",
                file=sys.stderr,
                flush=True,
            )
            for fixture in INDEPENDENT_FIXTURES[dimension]:
                source_text = gen_fixture_doc(
                    fixture.functions,
                    target_bytes=fixture.target_bytes,
                    unicode_density=fixture.unicode_density,
                )
                source = source_text.encode("utf-8")
                metrics = fixture_source_metrics(source_text)
                controls = {
                    "name": fixture.name,
                    "functions": fixture.functions,
                    "target_bytes": fixture.target_bytes,
                    "unicode_density_requested": fixture.unicode_density,
                    "fanout_documents": fixture.fanout_documents,
                    "burst_count": fixture.burst_count,
                }
                print(
                    f"  {fixture.name}: source_bytes={len(source)}",
                    file=sys.stderr,
                    flush=True,
                )
                scenario_data: dict[str, Any] = {}
                for scenario in scenarios_for_dimension(dimension):
                    samples = []
                    for sample_number in range(args.samples):
                        print(
                            f"    {scenario}: sample {sample_number + 1}/{args.samples}",
                            file=sys.stderr,
                            flush=True,
                        )
                        samples.append(
                            run_sample(
                                fixture.functions,
                                scenario,
                                args.timeout,
                                target_bytes=fixture.target_bytes,
                                unicode_density=fixture.unicode_density,
                                fanout_documents=fixture.fanout_documents,
                                burst_count=fixture.burst_count,
                            )
                        )
                    scenario_data[scenario] = {
                        "samples": samples,
                        "summary": summarize(samples),
                    }
                dimension_cases.append(
                    {
                        "controls": controls,
                        "source": metrics,
                        "scenarios": scenario_data,
                    }
                )
            independent_dimensions[dimension] = {
                "policy": dimension_policy(dimension),
                "cases": dimension_cases,
            }

        soak_samples = []
        print(
            f"storage soak: cycles={args.soak_cycles} functions={args.soak_functions}",
            file=sys.stderr,
            flush=True,
        )
        for sample_number in range(args.samples):
            print(
                f"  storage_soak: sample {sample_number + 1}/{args.samples}",
                file=sys.stderr,
                flush=True,
            )
            soak_samples.append(
                run_sample(
                    args.soak_functions,
                    "storage_soak",
                    args.timeout,
                    args.soak_cycles,
                )
            )

        soak_summary_keys = (
            "soak_wall_s",
            "server_process_wall_s",
            "cpu_user_s",
            "cpu_system_s",
            "cpu_total_s",
            "peak_rss_bytes",
        )
        soak_summary: dict[str, Any] = {}
        for key in soak_summary_keys:
            values = [
                sample[key]
                for sample in soak_samples
                if sample.get(key) is not None
            ]
            soak_summary[key] = (
                distribution_summary(values)
                if values
                else None
            )
        for key in STORAGE_COUNTERS:
            for prefix in ("peak", "final"):
                values = [
                    sample[f"{prefix}_stats"][key]
                    for sample in soak_samples
                    if sample.get(f"{prefix}_stats") is not None
                ]
                soak_summary[f"{prefix}_{key}"] = (
                    distribution_summary(values)
                    if values
                    else None
                )
        for key in (
            "initial_bytes",
            "after_warmup_bytes",
            "final_bytes",
            "peak_sampled_bytes",
            "delta_from_warmup_bytes",
        ):
            values = [
                sample["rss_sampling"]["summary"][key]
                for sample in soak_samples
                if sample.get("rss_sampling", {}).get("summary", {}).get(key) is not None
            ]
            soak_summary[f"rss_{key}"] = (
                distribution_summary(values)
                if values
                else None
            )

        result = {
            "schema_version": 3,
            "created_at_utc": utc_now(),
            "measurement_policy": {
                "performance_gates": False,
                "sample_count": args.samples,
                "distribution": (
                    "summary objects report sample_count, min, median, nearest-rank p95, "
                    "and max; nearest-rank selects the ceil(q*n) sorted sample, so a "
                    "one-sample run reports that sample as p95"
                ),
                "wall_time": (
                    "startup is process launch through initialize response; clean_open "
                    "is didOpen through first semanticTokens/full response; edit is "
                    "didChange through semanticTokens/full response; cached_tokens "
                    "is a repeated semanticTokens/full response after warmup; hover "
                    "is one hover request/response"
                ),
                "cpu_and_peak_rss": (
                    "whole server process lifetime, including initialization and "
                    "scenario setup; null when the platform does not expose a metric"
                ),
                "current_rss_samples": (
                    "Sparse current resident-set readings of the live server process, in bytes; "
                    "read through libproc on Darwin and /proc on Linux, null when unavailable. "
                    "These samples can miss short peaks and do not identify which allocator or "
                    "arena owns retained pages; they are diagnostic, not a performance gate."
                ),
                "storage_soak": (
                    "one server process repeats distinct-URI open/change/close cycles; each "
                    "stats sample is taken after the named operation. Stats report the LSP "
                    "server's flat document buffer and slot counts only, not allocator-retained "
                    "memory or a process-wide leak measurement; documents is the registry slot "
                    "count (including free reusable slots), while open is the active-open count"
                ),
                "independent_dimensions": (
                    "Opt-in one-axis-at-a-time cases. Fixed-byte fixtures use comment padding "
                    "so declaration and Unicode controls are not silently conflated. The "
                    "dependency_fanout axis is explicitly a multi-document surrogate until "
                    "the workspace dependency resolver exists. Raw timings remain observations."
                ),
            },
            "provenance": prov,
            "cases": cases,
            "independent_dimensions": independent_dimensions,
            "storage_soak": {
                "configuration": {
                    "cycles_per_sample": args.soak_cycles,
                    "functions_per_document": args.soak_functions,
                    "sample_count": args.samples,
                    "distinct_uri_per_cycle": True,
                    "stats_phases": ["after_open", "after_change", "after_close"],
                    "resident_set_sampling": {
                        "platform": platform.system(),
                        "machine": platform.machine(),
                        "units": "bytes",
                        "initial_phase": "after_initialize",
                        "later_phases": "after first close, periodically by cycle, and always after the final close",
                        "maximum_samples_per_server": 10,
                        "interval_cycles": max(1, (args.soak_cycles + 7) // 8),
                    },
                    "counter_semantics": {
                        "documents": "registry slot count, including free reusable slots",
                        "open": "number of currently open documents",
                    },
                },
                "samples": soak_samples,
                "summary": soak_summary,
            },
        }
        serialized = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.out:
            output_path = os.path.abspath(args.out)
            os.makedirs(os.path.dirname(output_path), exist_ok=True)
            with open(output_path, "w", encoding="utf-8") as stream:
                stream.write(serialized)
            print(f"wrote benchmark JSON: {output_path}", file=sys.stderr)
        else:
            sys.stdout.write(serialized)
        return 0
    except BenchmarkError as exc:
        print(f"benchmark failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
