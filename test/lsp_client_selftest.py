#!/usr/bin/env python3
"""Standalone regression checks for the shared subprocess LSP client."""

from __future__ import annotations

import json
import sys
import time

from lsp_client import FrameDecoder, FrameError, LspError, LspSession, frame


def fake_source(mode: str) -> str:
    return r'''
import json, sys, time

def read_one():
    header = sys.stdin.buffer.readline()
    if not header:
        return None
    if not header.endswith(b"\r\n"):
        return None
    name, value = header[:-2].split(b":", 1)
    if name.lower() != b"content-length":
        return None
    count = int(value.strip())
    if sys.stdin.buffer.readline() != b"\r\n":
        return None
    body = sys.stdin.buffer.read(count)
    return json.loads(body.decode("utf-8"))

def emit(raw):
    # Small writes deliberately split frame headers and bodies across reads.
    for size in (1, 2, 5, 3, 11, 7, 19):
        if not raw:
            break
        sys.stdout.buffer.write(raw[:size])
        sys.stdout.buffer.flush()
        raw = raw[size:]
    if raw:
        sys.stdout.buffer.write(raw)
        sys.stdout.buffer.flush()

def fr(obj):
    body = json.dumps(obj, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body

MODE = __MODE__
if MODE == "good":
    first = read_one()
    second = read_one()
    note = {"jsonrpc":"2.0", "method":"window/logMessage", "params":{"message":"ready"}}
    # Numeric 1 and string "1" are distinct IDs. Both responses share one
    # output stream, with the response order reversed and a notification mixed in.
    payload = (fr(note)
               + fr({"jsonrpc":"2.0", "id":"1", "result":{"which":"string"}})
               + fr({"jsonrpc":"2.0", "id":1, "result":{"which":"number"}}))
    emit(payload)
elif MODE == "duplicate":
    request = read_one()
    response = fr({"jsonrpc":"2.0", "id":request["id"], "result":None})
    sys.stdout.buffer.write(response + response)
    sys.stdout.buffer.flush()
elif MODE == "malformed":
    read_one()
    sys.stdout.buffer.write(b"Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}")
    sys.stdout.buffer.flush()
elif MODE == "truncated":
    read_one()
    sys.stdout.buffer.write(b"Content-Length: 40\r\n\r\n{}")
    sys.stdout.buffer.flush()
elif MODE == "crash":
    read_one()
    sys.exit(23)
elif MODE == "hang":
    read_one()
    time.sleep(20)
elif MODE == "drip":
    read_one()
    for index in range(20):
        note = {"jsonrpc":"2.0", "method":"$/progress", "params":{"index":index}}
        emit(fr(note))
        time.sleep(0.025)
elif MODE == "stderr":
    request = read_one()
    sys.stderr.write("warning: expected test warning\nsynthetic error: test failure\n")
    sys.stderr.flush()
    emit(fr({"jsonrpc":"2.0", "id":request["id"], "result":None}))
'''.replace("__MODE__", repr(mode))


def session(mode: str, **kwargs: object) -> LspSession:
    options: dict[str, object] = {
        "startup_timeout": 2.0,
        "request_timeout": 2.0,
        "teardown_timeout": 2.0,
    }
    options.update(kwargs)
    return LspSession(
        command=[sys.executable, "-u", "-c", fake_source(mode)],
        **options,
    )


def test_decoder_fragmented_and_pipelined() -> None:
    first = {"jsonrpc": "2.0", "id": 1, "result": {"text": "🌍"}}
    second = {"jsonrpc": "2.0", "id": "1", "result": {"ok": True}}
    stream = frame(first) + frame(second)
    decoder = FrameDecoder()
    decoded = []
    for byte in stream:
        decoded.extend(decoder.feed(bytes([byte])))
    decoder.finish()
    assert [item.message for item in decoded] == [first, second]
    assert decoded[0].body == json.dumps(first, separators=(",", ":"), ensure_ascii=False).encode()


def test_subprocess_fragmentation_pipelining_and_typed_ids() -> None:
    with session("good") as client:
        # Both requests are delivered in one write. The fake server fragments
        # the combined notification + two response frames into tiny writes.
        client.send_many(
            [
                {"jsonrpc": "2.0", "id": 1, "method": "one"},
                {"jsonrpc": "2.0", "id": "1", "method": "two"},
            ]
        )
        numeric = client.wait_response(1)
        textual = client.wait_response("1")
        assert numeric["result"] == {"which": "number"}
        assert textual["result"] == {"which": "string"}
        note = client.wait_notification("window/logMessage")
        assert note["params"]["message"] == "ready"
        assert len(client.raw_bodies) == 3
    assert client.proc is not None and client.proc.returncode == 0


def test_duplicate_response_is_rejected() -> None:
    client = session("duplicate")
    with client:
        client.send({"jsonrpc": "2.0", "id": 8, "method": "duplicate"})
        try:
            client.wait_response(8)
        except FrameError as exc:
            assert "duplicate" in str(exc).lower()
        else:
            raise AssertionError("duplicate response was accepted")
        assert client.proc is not None and client.proc.poll() is not None


def test_malformed_and_truncated_stdout_are_rejected() -> None:
    for mode, expected in (("malformed", "duplicate stdout header"), ("truncated", "truncated stdout body")):
        client = session(mode)
        with client:
            client.send({"jsonrpc": "2.0", "id": 3, "method": "bad-output"})
            try:
                client.wait_response(3)
            except LspError as exc:
                assert expected in str(exc).lower(), str(exc)
            else:
                raise AssertionError(f"{mode} stdout was accepted")
            assert client.proc is not None and client.proc.poll() is not None


def test_crash_is_reported_and_reaped() -> None:
    client = session("crash")
    with client:
        client.send({"jsonrpc": "2.0", "id": 4, "method": "crash"})
        try:
            client.wait_response(4)
        except LspError as exc:
            assert "23" in str(exc), str(exc)
        else:
            raise AssertionError("crashed subprocess was treated as a response")
        assert client.proc is not None and client.proc.poll() is not None


def test_timeout_kills_and_reaps() -> None:
    client = session("hang", request_timeout=0.1, teardown_timeout=0.5)
    with client:
        client.send({"jsonrpc": "2.0", "id": 5, "method": "hang"})
        started = time.monotonic()
        try:
            client.wait_response(5)
        except LspError as exc:
            assert "killed and reaped" in str(exc), str(exc)
        else:
            raise AssertionError("hung subprocess did not time out")
        assert time.monotonic() - started < 2.0
        assert client.proc is not None and client.proc.poll() is not None


def test_response_deadline_is_absolute_across_notifications() -> None:
    client = session("drip", request_timeout=0.15, teardown_timeout=0.5)
    with client:
        client.send({"jsonrpc": "2.0", "id": 6, "method": "drip"})
        started = time.monotonic()
        try:
            client.wait_response(6)
        except LspError as exc:
            assert "killed and reaped" in str(exc), str(exc)
        else:
            raise AssertionError("notifications reset the response deadline")
        elapsed = time.monotonic() - started
        assert elapsed < 0.8, f"absolute deadline was reset ({elapsed:.3f}s)"
        assert len(client.notifications) >= 2
        assert client.proc is not None and client.proc.poll() is not None


def test_header_and_body_bounds() -> None:
    decoder = FrameDecoder(max_header_bytes=12, max_body_bytes=4)
    try:
        decoder.feed(b"X-Long-Header: abc")
    except FrameError as exc:
        assert "header exceeds" in str(exc)
    else:
        raise AssertionError("oversized header was accepted")
    decoder = FrameDecoder(max_body_bytes=4)
    try:
        decoder.feed(b"Content-Length: 5\r\n\r\n")
    except FrameError as exc:
        assert "exceeds" in str(exc)
    else:
        raise AssertionError("oversized body length was accepted")


def test_stream_bound_is_enforced() -> None:
    client = session("good", max_stream_bytes=80)
    with client:
        client.send_many(
            [
                {"jsonrpc": "2.0", "id": 1, "method": "one"},
                {"jsonrpc": "2.0", "id": "1", "method": "two"},
            ]
        )
        try:
            client.wait_response(1)
        except FrameError as exc:
            assert "stdout stream exceeds" in str(exc), str(exc)
        else:
            raise AssertionError("oversized stdout stream was accepted")
        assert client.proc is not None and client.proc.poll() is not None


def test_configurable_stderr_error_assertion() -> None:
    client = session("stderr", stderr_limit=1024)
    with client:
        client.send({"jsonrpc": "2.0", "id": 11, "method": "stderr"})
        client.wait_response(11)
        client.close(expect_exit=0)
        try:
            client.assert_no_stderr_errors(patterns=(r"\berror\b",))
        except LspError as exc:
            assert "synthetic error" in str(exc), str(exc)
        else:
            raise AssertionError("error-like stderr was not reported")
        client.assert_no_stderr_errors(
            patterns=(r"\berror\b",),
            allowed_patterns=(r"^synthetic error: test failure$",),
        )

    truncated = session("stderr", stderr_limit=5)
    with truncated:
        truncated.send({"jsonrpc": "2.0", "id": 12, "method": "stderr"})
        truncated.wait_response(12)
        truncated.close(expect_exit=0)
        try:
            truncated.assert_no_stderr_errors()
        except LspError as exc:
            assert "truncated" in str(exc), str(exc)
        else:
            raise AssertionError("truncated stderr was treated as a clean capture")


def main() -> None:
    tests = (
        test_decoder_fragmented_and_pipelined,
        test_subprocess_fragmentation_pipelining_and_typed_ids,
        test_duplicate_response_is_rejected,
        test_malformed_and_truncated_stdout_are_rejected,
        test_crash_is_reported_and_reaped,
        test_timeout_kills_and_reaps,
        test_response_deadline_is_absolute_across_notifications,
        test_header_and_body_bounds,
        test_stream_bound_is_enforced,
        test_configurable_stderr_error_assertion,
    )
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"lsp_client self-test OK ({len(tests)} cases)")


if __name__ == "__main__":
    main()
