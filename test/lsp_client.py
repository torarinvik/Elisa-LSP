#!/usr/bin/env python3
"""Bounded, framed subprocess client for Elisa-LSP protocol tests.

The client deliberately treats stdout as a byte stream containing only LSP
frames. It validates framing and JSON independently of the server and keeps
responses keyed by both ID type and value. A session is normally used as a
context manager; on failure it terminates and reaps the complete subprocess
group.

    with LspSession("build/elisa-lsp") as client:
        init = client.request("initialize", {"capabilities": {}})
        client.notify("initialized", {})
        ...
        client.finish()  # shutdown request, exit notification, and reap

No third-party Python packages are required.
"""

from __future__ import annotations

import json
import os
import queue
import re
import select
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import Any, Iterable


class LspError(AssertionError):
    """A protocol, process, or deadline failure in an LSP test session."""


class FrameError(LspError):
    """Malformed or incomplete stdout framing / JSON-RPC message."""


def _json_object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise FrameError(f"duplicate JSON object key {key!r}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise FrameError(f"non-JSON numeric constant {value!r}")


def _decode_message(body: bytes) -> dict[str, Any]:
    try:
        source = body.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise FrameError(f"stdout body is not valid UTF-8: {exc}") from exc
    try:
        value = json.loads(
            source,
            object_pairs_hook=_json_object_pairs,
            parse_constant=_reject_json_constant,
        )
    except FrameError:
        raise
    except (ValueError, RecursionError) as exc:
        raise FrameError(f"stdout body is not valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise FrameError("stdout JSON body must be an object")
    return value


def _id_key(value: Any, *, response: bool = False) -> tuple[str, Any]:
    # bool is a subclass of int in Python, but JSON-RPC IDs are not booleans.
    if type(value) is int:
        if not -(2**31) <= value <= 2**31 - 1:
            raise FrameError(f"integer JSON-RPC ID is outside LSP range: {value}")
        return ("int", value)
    if isinstance(value, str):
        return ("str", value)
    if response and value is None:
        return ("null", None)
    expected = "string or signed 32-bit integer"
    if response:
        expected += " (or null for a protocol error response)"
    raise FrameError(f"JSON-RPC ID must be {expected}, got {value!r}")


def frame(obj: Any) -> bytes:
    """Encode one JSON object as an LSP frame, counting UTF-8 bytes exactly."""
    if isinstance(obj, (bytes, bytearray, memoryview)):
        body = bytes(obj)
    else:
        try:
            body = json.dumps(
                obj, separators=(",", ":"), ensure_ascii=False, allow_nan=False
            ).encode("utf-8")
        except (TypeError, ValueError, UnicodeEncodeError) as exc:
            raise LspError(f"cannot encode JSON-RPC message: {exc}") from exc
    return b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body


def frame_bytes(body: bytes) -> bytes:
    """Frame an already encoded body without decoding or changing its bytes."""
    return b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body


_HEADER_TOKEN = re.compile(rb"[!#$%&'*+\-.^_`|~0-9A-Za-z]+\Z")
_CONTENT_LENGTH = re.compile(rb"[0-9]+\Z")


@dataclass(frozen=True)
class LspFrame:
    message: dict[str, Any]
    body: bytes


class FrameDecoder:
    """Incremental strict decoder with hard limits for headers and bodies."""

    def __init__(self, *, max_header_bytes: int = 8192, max_body_bytes: int = 16 << 20):
        if max_header_bytes < 1 or max_body_bytes < 1:
            raise ValueError("frame limits must be positive")
        self.max_header_bytes = max_header_bytes
        self.max_body_bytes = max_body_bytes
        self.buffer = bytearray()
        self.expected_body: int | None = None

    def _content_length(self, header: bytes) -> int:
        if len(header) > self.max_header_bytes:
            raise FrameError(f"stdout header exceeds {self.max_header_bytes} bytes")
        fields: dict[bytes, bytes] = {}
        lines = header.split(b"\r\n")
        if not lines or any(not line for line in lines):
            raise FrameError("stdout header contains an empty line")
        for line in lines:
            name, colon, value = line.partition(b":")
            if not colon or not _HEADER_TOKEN.fullmatch(name):
                raise FrameError(f"malformed stdout header line: {line!r}")
            folded = name.lower()
            if folded in fields:
                raise FrameError(f"duplicate stdout header field {name.decode('ascii')!r}")
            value = value.strip(b" \t")
            if any(byte < 0x20 and byte != 0x09 or byte == 0x7F for byte in value):
                raise FrameError(f"control byte in stdout header field {name!r}")
            fields[folded] = value
        length = fields.get(b"content-length")
        if length is None:
            raise FrameError("stdout header has no Content-Length")
        if not _CONTENT_LENGTH.fullmatch(length):
            raise FrameError(f"invalid stdout Content-Length: {length!r}")
        try:
            body_length = int(length)
        except ValueError as exc:
            raise FrameError("stdout Content-Length is too large to parse") from exc
        if body_length > self.max_body_bytes:
            raise FrameError(
                f"stdout body length {body_length} exceeds {self.max_body_bytes} bytes"
            )
        return body_length

    def feed(self, data: bytes) -> list[LspFrame]:
        if data:
            self.buffer.extend(data)
        complete: list[LspFrame] = []
        marker = b"\r\n\r\n"
        while True:
            if self.expected_body is None:
                header_end = self.buffer.find(marker)
                if header_end < 0:
                    if len(self.buffer) > self.max_header_bytes:
                        raise FrameError(
                            f"stdout header exceeds {self.max_header_bytes} bytes"
                        )
                    break
                header = bytes(self.buffer[:header_end])
                self.expected_body = self._content_length(header)
                del self.buffer[: header_end + len(marker)]
            assert self.expected_body is not None
            if len(self.buffer) < self.expected_body:
                break
            body_length = self.expected_body
            body = bytes(self.buffer[:body_length])
            del self.buffer[:body_length]
            self.expected_body = None
            message = _decode_message(body)
            complete.append(LspFrame(message, body))
        return complete

    def finish(self) -> None:
        """Report any partial header or body left when stdout reaches EOF."""
        if self.expected_body is not None:
            raise FrameError(
                f"truncated stdout body: expected {self.expected_body} bytes, "
                f"received {len(self.buffer)}"
            )
        if self.buffer:
            raise FrameError(f"truncated stdout header: {bytes(self.buffer[:160])!r}")


def parse_stream(buf: bytearray) -> list[tuple[dict[str, Any], bytes]]:
    """Compatibility helper: parse all complete frames and retain a partial tail."""
    decoder = FrameDecoder()
    frames = decoder.feed(bytes(buf))
    if decoder.expected_body is None:
        buf[:] = decoder.buffer
    else:
        # The legacy helper has no decoder object to retain between calls.
        # Rebuild a minimal valid header around its partial body tail.
        buf[:] = (
            b"Content-Length: "
            + str(decoder.expected_body).encode("ascii")
            + b"\r\n\r\n"
            + decoder.buffer
        )
    return [(item.message, item.body) for item in frames]


class LspSession:
    """Interactive, deadline-bounded client for one real or fake LSP process.

    `srv_path` may be an executable path. Tests of this module may instead
    supply `command=[...]` to run a deterministic fake peer.
    """

    def __init__(
        self,
        srv_path: str | os.PathLike[str] | None = None,
        *,
        command: Iterable[str] | None = None,
        startup_timeout: float = 5.0,
        request_timeout: float | None = None,
        teardown_timeout: float = 3.0,
        max_header_bytes: int = 8192,
        max_body_bytes: int = 16 << 20,
        max_stream_bytes: int = 64 << 20,
        max_messages: int = 100_000,
        stderr_limit: int = 64 << 10,
    ):
        if command is None:
            if srv_path is None:
                raise ValueError("provide srv_path or command")
            path = os.fspath(srv_path)
            if not (os.path.isfile(path) and os.access(path, os.X_OK)):
                raise LspError(
                    f"server binary missing/not executable: {path} "
                    "(build first: bash build.sh)"
                )
            command = [path]
        if startup_timeout <= 0 or teardown_timeout <= 0:
            raise ValueError("timeouts must be positive")
        self.command = list(command)
        if not self.command:
            raise ValueError("command must not be empty")
        self.startup_timeout = startup_timeout
        self.request_timeout = startup_timeout if request_timeout is None else request_timeout
        self.teardown_timeout = teardown_timeout
        self.stderr_limit = stderr_limit
        if self.request_timeout <= 0 or stderr_limit < 0:
            raise ValueError("request timeout must be positive and stderr limit nonnegative")
        if max_stream_bytes < 1 or max_messages < 1:
            raise ValueError("stream byte and message limits must be positive")
        self.max_stream_bytes = max_stream_bytes
        self.max_messages = max_messages
        self.decoder = FrameDecoder(
            max_header_bytes=max_header_bytes, max_body_bytes=max_body_bytes
        )
        self.responses: dict[tuple[str, Any], dict[str, Any]] = {}
        self.notifications: list[dict[str, Any]] = []
        self.server_requests: list[dict[str, Any]] = []
        self.all_messages: list[dict[str, Any]] = []
        self.raw_bodies: list[bytes] = []
        self._response_by_id: dict[tuple[str, Any], dict[str, Any]] = {}
        self._claimed_notifications: set[int] = set()
        self._next_id = 1
        self._queue: queue.Queue[tuple[str, bytes | BaseException]] = queue.Queue(maxsize=32)
        self._stop_readers = threading.Event()
        self._stderr_lock = threading.Lock()
        self._stderr_tail = bytearray()
        self._stderr_truncated = False
        self._stdout_eof = False
        self._stdin_closed = False
        self._closed = False
        self._stream_bytes = 0
        self.proc: subprocess.Popen[bytes] | None = None
        self._stdout_thread: threading.Thread | None = None
        self._stderr_thread: threading.Thread | None = None

    def __enter__(self) -> "LspSession":
        try:
            self.proc = subprocess.Popen(
                self.command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0,
                start_new_session=(os.name == "posix"),
            )
        except OSError as exc:
            raise LspError(f"could not start LSP subprocess {self.command!r}: {exc}") from exc
        assert self.proc.stdin is not None
        os.set_blocking(self.proc.stdin.fileno(), False)
        self._stdout_thread = threading.Thread(
            target=self._drain_stdout, name="lsp-stdout", daemon=True
        )
        self._stderr_thread = threading.Thread(
            target=self._drain_stderr, name="lsp-stderr", daemon=True
        )
        self._stdout_thread.start()
        self._stderr_thread.start()
        # Popen is synchronous. This early check catches instant launch failures;
        # subsequent request and output waits use their own absolute deadlines.
        time.sleep(min(0.01, self.startup_timeout / 10))
        if self.proc.poll() is not None:
            stderr = self.stderr_text()
            self.abort()
            raise LspError(
                f"LSP subprocess exited during startup with status "
                f"{self.proc.returncode}; stderr: {stderr[:2000]!r}"
            )
        return self

    def _put_stdout_event(self, event: tuple[str, bytes | BaseException]) -> None:
        while not self._stop_readers.is_set():
            try:
                self._queue.put(event, timeout=0.1)
                return
            except queue.Full:
                continue

    def _drain_stdout(self) -> None:
        assert self.proc is not None and self.proc.stdout is not None
        fd = self.proc.stdout.fileno()
        try:
            while not self._stop_readers.is_set():
                chunk = os.read(fd, 4096)
                if not chunk:
                    self._put_stdout_event(("eof", b""))
                    return
                self._put_stdout_event(("stdout", chunk))
        except OSError as exc:
            if not self._stop_readers.is_set():
                self._put_stdout_event(("reader-error", exc))

    def _drain_stderr(self) -> None:
        assert self.proc is not None and self.proc.stderr is not None
        fd = self.proc.stderr.fileno()
        try:
            while not self._stop_readers.is_set():
                chunk = os.read(fd, 4096)
                if not chunk:
                    return
                with self._stderr_lock:
                    self._stderr_tail.extend(chunk)
                    if len(self._stderr_tail) > self.stderr_limit:
                        excess = len(self._stderr_tail) - self.stderr_limit
                        del self._stderr_tail[:excess]
                        self._stderr_truncated = True
        except OSError:
            pass

    def stderr_text(self) -> str:
        with self._stderr_lock:
            tail = bytes(self._stderr_tail)
            truncated = self._stderr_truncated
        prefix = "[earlier stderr truncated] " if truncated else ""
        return prefix + tail.decode("utf-8", errors="replace")

    def assert_no_stderr_errors(
        self,
        *,
        patterns: Iterable[str] = (
            r"\b(?:error|fatal|panic|exception|traceback|segmentation fault)\b",
        ),
        allowed_patterns: Iterable[str] = (),
    ) -> None:
        """Fail if captured stderr contains an unexpected error-like line.

        Patterns are case-insensitive regular expressions matched against each
        line. Allowed patterns suppress only lines they match. A truncated
        stderr tail cannot prove that no earlier error was emitted, so it also
        fails the assertion.
        """
        with self._stderr_lock:
            raw = bytes(self._stderr_tail)
            truncated = self._stderr_truncated
        if truncated:
            raise LspError("cannot assert stderr is clean: captured stderr was truncated")
        text = raw.decode("utf-8", errors="replace")
        error_patterns = tuple(patterns)
        allowances = tuple(allowed_patterns)
        unexpected = [
            line
            for line in text.splitlines()
            if any(re.search(pattern, line, re.IGNORECASE) for pattern in error_patterns)
            and not any(re.search(pattern, line, re.IGNORECASE) for pattern in allowances)
        ]
        if unexpected:
            raise LspError("unexpected error-like stderr output: " + " | ".join(unexpected[:8]))

    def _ensure_running(self) -> subprocess.Popen[bytes]:
        if self.proc is None:
            raise LspError("session has not been entered")
        if self._closed:
            raise LspError("session is already closed")
        status = self.proc.poll()
        if status is not None:
            raise LspError(
                f"LSP subprocess exited with status {status}; stderr: "
                f"{self.stderr_text()[:2000]!r}"
            )
        return self.proc

    def _write_all(self, data: bytes, deadline: float) -> None:
        proc = self._ensure_running()
        assert proc.stdin is not None
        fd = proc.stdin.fileno()
        offset = 0
        while offset < len(data):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self._timeout_abort("timed out writing to server stdin")
            try:
                _, writable, _ = select.select([], [fd], [], remaining)
            except InterruptedError:
                continue
            if not writable:
                self._timeout_abort("timed out writing to server stdin")
            try:
                written = os.write(fd, data[offset:])
            except InterruptedError:
                continue
            except (BrokenPipeError, OSError) as exc:
                self.abort()
                raise LspError(f"server closed its input: {exc}; stderr: {self.stderr_text()[:2000]!r}") from exc
            if written <= 0:
                self.abort()
                raise LspError("server stdin accepted no bytes")
            offset += written

    def send(self, obj_or_bytes: Any, *, timeout: float | None = None) -> None:
        """Send one JSON object, or raw already-framed bytes."""
        data = bytes(obj_or_bytes) if isinstance(obj_or_bytes, (bytes, bytearray, memoryview)) else frame(obj_or_bytes)
        duration = self.request_timeout if timeout is None else timeout
        if duration <= 0:
            raise ValueError("timeout must be positive")
        self._write_all(data, time.monotonic() + duration)

    def send_fragmented(
        self,
        data: bytes,
        splits: Iterable[int],
        *,
        timeout: float | None = None,
    ) -> None:
        """Write one raw byte stream at the specified offsets under one deadline."""
        points = sorted(set(int(p) for p in splits))
        if any(p < 0 or p > len(data) for p in points):
            raise ValueError("fragment offsets must be within the byte stream")
        duration = self.request_timeout if timeout is None else timeout
        deadline = time.monotonic() + duration
        edges = [0, *[p for p in points if p not in (0, len(data))], len(data)]
        for start, end in zip(edges, edges[1:]):
            self._write_all(data[start:end], deadline)

    def send_many(self, messages: Iterable[Any], *, timeout: float | None = None) -> None:
        """Pipeline several object messages in a single write operation."""
        payload = b"".join(frame(message) for message in messages)
        duration = self.request_timeout if timeout is None else timeout
        self._write_all(payload, time.monotonic() + duration)

    def notify(self, method: str, params: Any | None = None, *, timeout: float | None = None) -> None:
        message: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message, timeout=timeout)

    def request(
        self,
        method: str,
        params: Any | None = None,
        *,
        req_id: int | str | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        if req_id is None:
            req_id = self._next_id
            self._next_id += 1
        _id_key(req_id)
        message: dict[str, Any] = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params is not None:
            message["params"] = params
        duration = self.request_timeout if timeout is None else timeout
        if duration <= 0:
            raise ValueError("timeout must be positive")
        deadline = time.monotonic() + duration
        return self._request_until(message, req_id, deadline)

    def _request_until(
        self, message: dict[str, Any], req_id: int | str, deadline: float
    ) -> dict[str, Any]:
        self._write_all(frame(message), deadline)
        return self.wait_response(req_id, _deadline=deadline)

    def initialize(self, params: Any | None = None, *, timeout: float | None = None) -> dict[str, Any]:
        duration = self.startup_timeout if timeout is None else timeout
        if duration <= 0:
            raise ValueError("timeout must be positive")
        deadline = time.monotonic() + duration
        req_id = self._next_id
        self._next_id += 1
        response = self._request_until(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "method": "initialize",
                "params": {"capabilities":{}} if params is None else params,
            },
            req_id,
            deadline,
        )
        if "result" in response:
            self._write_all(frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}), deadline)
        return response

    def shutdown(self, *, timeout: float | None = None) -> dict[str, Any]:
        return self.request("shutdown", timeout=timeout)

    def finish(self, *, timeout: float | None = None) -> int:
        """Complete shutdown/exit and validate the process's final stdout stream."""
        duration = self.request_timeout if timeout is None else timeout
        if duration <= 0:
            raise ValueError("timeout must be positive")
        deadline = time.monotonic() + duration
        req_id = self._next_id
        self._next_id += 1
        response = self._request_until(
            {"jsonrpc": "2.0", "id": req_id, "method": "shutdown"}, req_id, deadline
        )
        if "error" in response:
            raise LspError(f"shutdown returned JSON-RPC error: {response['error']!r}")
        self._write_all(frame({"jsonrpc": "2.0", "method": "exit"}), deadline)
        return self.close(expect_exit=0, _deadline=deadline)

    def _record_frame(self, frame_value: LspFrame) -> None:
        if len(self.all_messages) >= self.max_messages:
            raise FrameError(f"stdout message count exceeds {self.max_messages}")
        message = frame_value.message
        if message.get("jsonrpc") != "2.0":
            raise FrameError("stdout JSON-RPC message must contain jsonrpc: '2.0'")
        has_id = "id" in message
        has_method = "method" in message
        has_result = "result" in message
        has_error = "error" in message
        if has_method:
            if not isinstance(message["method"], str):
                raise FrameError("stdout JSON-RPC method must be a string")
            if has_result or has_error:
                raise FrameError("stdout method message cannot also contain result/error")
            if has_id:
                _id_key(message["id"], response=False)
                self.server_requests.append(message)
            else:
                self.notifications.append(message)
        else:
            if not has_id or has_result == has_error:
                raise FrameError("stdout response must have an ID and exactly one of result/error")
            key = _id_key(message["id"], response=True)
            if has_error:
                error = message["error"]
                if (
                    not isinstance(error, dict)
                    or type(error.get("code")) is not int
                    or not isinstance(error.get("message"), str)
                ):
                    raise FrameError("stdout JSON-RPC error must contain integer code and string message")
            if key in self._response_by_id:
                raise FrameError(f"duplicate stdout response for typed ID {message['id']!r}")
            self._response_by_id[key] = message
            self.responses[(type(message["id"]).__name__, message["id"])] = message
        self.all_messages.append(message)
        self.raw_bodies.append(frame_value.body)

    def _pump_once(self, deadline: float) -> None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise LspError("timed out waiting for server output")
        try:
            kind, payload = self._queue.get(timeout=remaining)
        except queue.Empty as exc:
            raise LspError("timed out waiting for server output") from exc
        if kind == "stdout":
            assert isinstance(payload, bytes)
            self._stream_bytes += len(payload)
            if self._stream_bytes > self.max_stream_bytes:
                raise FrameError(
                    f"stdout stream exceeds {self.max_stream_bytes} bytes"
                )
            for decoded in self.decoder.feed(payload):
                self._record_frame(decoded)
        elif kind == "eof":
            self._stdout_eof = True
            self.decoder.finish()
        elif kind == "reader-error":
            assert isinstance(payload, BaseException)
            raise LspError(f"failed while draining server stdout: {payload}") from payload
        else:
            raise LspError(f"unknown stdout reader event {kind!r}")

    def _timeout_abort(self, message: str) -> None:
        details = self.stderr_text()[:2000]
        self.abort()
        raise LspError(f"{message}; subprocess killed and reaped; stderr: {details!r}")

    def _wait_failed(self, error: BaseException) -> None:
        self.abort()
        if isinstance(error, LspError):
            raise error
        raise LspError(str(error)) from error

    def wait_response(
        self,
        req_id: int | str,
        timeout: float | None = None,
        *,
        _deadline: float | None = None,
    ) -> dict[str, Any]:
        key = _id_key(req_id)
        response_key = (type(req_id).__name__, req_id)
        if response_key in self.responses:
            return self.responses[response_key]
        if _deadline is None:
            duration = self.request_timeout if timeout is None else timeout
            if duration <= 0:
                raise ValueError("timeout must be positive")
            deadline = time.monotonic() + duration
        else:
            deadline = _deadline
        try:
            while response_key not in self.responses:
                if self._stdout_eof:
                    assert self.proc is not None
                    raise LspError(
                        f"server closed stdout before response for ID {req_id!r} "
                        f"(exit status {self.proc.poll()}); stderr: {self.stderr_text()[:2000]!r}"
                    )
                self._pump_once(deadline)
            return self.responses[response_key]
        except LspError as exc:
            if "timed out" in str(exc):
                self._timeout_abort(f"no response for ID {req_id!r}: {exc}")
            self._wait_failed(exc)
        raise AssertionError("unreachable")

    def wait_notification(
        self,
        method: str,
        *,
        timeout: float | None = None,
        predicate: Any | None = None,
    ) -> dict[str, Any]:
        duration = self.request_timeout if timeout is None else timeout
        if duration <= 0:
            raise ValueError("timeout must be positive")
        deadline = time.monotonic() + duration
        try:
            while True:
                for index, notification in enumerate(self.notifications):
                    if index in self._claimed_notifications:
                        continue
                    if notification.get("method") == method and (
                        predicate is None or predicate(notification)
                    ):
                        self._claimed_notifications.add(index)
                        return notification
                if self._stdout_eof:
                    raise LspError(f"server closed stdout before notification {method!r}")
                self._pump_once(deadline)
        except LspError as exc:
            if "timed out" in str(exc):
                self._timeout_abort(f"timed out waiting for notification {method!r}")
            self._wait_failed(exc)
        raise AssertionError("unreachable")

    def recv(self, timeout: float = 5.0) -> tuple[dict[str, Any], bytes]:
        """Receive the next complete stdout message and its exact JSON bytes."""
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        if not hasattr(self, "_recv_cursor"):
            self._recv_cursor = 0
        deadline = time.monotonic() + timeout
        try:
            while self._recv_cursor >= len(self.all_messages):
                if self._stdout_eof:
                    raise LspError("server closed stdout with no more messages")
                self._pump_once(deadline)
            index = self._recv_cursor
            self._recv_cursor += 1
            return self.all_messages[index], self.raw_bodies[index]
        except LspError as exc:
            if "timed out" in str(exc):
                self._timeout_abort(f"{exc}")
            self._wait_failed(exc)
        raise AssertionError("unreachable")

    def recv_any(self, timeout: float = 5.0) -> bool:
        """Compatibility helper: wait for and record at least one message."""
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        deadline = time.monotonic() + timeout
        before = len(self.all_messages)
        try:
            while len(self.all_messages) == before:
                if self._stdout_eof:
                    raise LspError("server closed stdout with no more messages")
                self._pump_once(deadline)
            return True
        except LspError as exc:
            if "timed out" in str(exc):
                self._timeout_abort(str(exc))
            self._wait_failed(exc)
        raise AssertionError("unreachable")

    def _close_stdin(self) -> None:
        if self.proc is not None and self.proc.stdin is not None and not self._stdin_closed:
            try:
                self.proc.stdin.close()
            except OSError:
                pass
            self._stdin_closed = True

    def _kill_group(self, sig: int) -> None:
        if self.proc is None:
            return
        try:
            if os.name == "posix":
                # The leader can exit while a descendant still holds a pipe.
                # Signal the session group even after proc.poll() reports exit.
                os.killpg(self.proc.pid, sig)
            elif self.proc.poll() is None and sig == signal.SIGKILL:
                self.proc.kill()
            elif self.proc.poll() is None:
                self.proc.terminate()
        except ProcessLookupError:
            pass
        except OSError:
            try:
                self.proc.kill()
            except OSError:
                pass

    def abort(self) -> None:
        """Terminate the subprocess tree and reap it. Safe to call repeatedly."""
        if self._closed:
            return
        self._close_stdin()
        if self.proc is not None and self.proc.poll() is None:
            self._kill_group(signal.SIGTERM)
            try:
                self.proc.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                pass
        if self.proc is not None:
            # Also clean up grandchildren that outlive the direct child.
            self._kill_group(signal.SIGKILL)
            try:
                self.proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self._stop_readers.set()
        if self.proc is not None:
            for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass
        for thread in (self._stdout_thread, self._stderr_thread):
            if thread is not None:
                thread.join(timeout=0.5)
        self._closed = True

    def close(
        self,
        *,
        expect_exit: int = 0,
        timeout: float | None = None,
        _deadline: float | None = None,
    ) -> int:
        """Close stdin, drain all remaining stdout, validate EOF, and reap."""
        if self._closed:
            return self.proc.returncode if self.proc is not None and self.proc.returncode is not None else 0
        proc = self.proc
        if proc is not None and proc.poll() is None:
            try:
                proc = self._ensure_running()
            except LspError:
                # `finish()` sends the final `exit` notification before
                # entering close(). The server may complete successfully in
                # the narrow interval between poll() above and the second
                # poll inside _ensure_running(); let the exit-code check below
                # classify that expected shutdown instead of reporting a
                # spurious premature-exit error.
                if proc.poll() is None:
                    raise
        if proc is None:
            self._closed = True
            return 0
        if _deadline is None:
            duration = self.teardown_timeout if timeout is None else timeout
            if duration <= 0:
                raise ValueError("timeout must be positive")
            deadline = time.monotonic() + duration
        else:
            deadline = _deadline
        self._close_stdin()
        failure: BaseException | None = None
        try:
            while proc.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._timeout_abort("server did not exit before teardown deadline")
                try:
                    # _pump_once accepts an absolute monotonic deadline, not
                    # a relative duration. Keep short polling bounded while
                    # preserving the same clock domain used by request waits.
                    self._pump_once(time.monotonic() + min(remaining, 0.05))
                except LspError as exc:
                    if "timed out" in str(exc):
                        continue
                    failure = exc
                    break
            if failure is None:
                while not self._stdout_eof:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        self._timeout_abort("timed out draining server stdout at EOF")
                    try:
                        self._pump_once(deadline)
                    except LspError as exc:
                        failure = exc
                        break
        except LspError as exc:
            failure = exc
        if failure is not None:
            self.abort()
            raise failure
        status = proc.wait(timeout=max(0.001, deadline - time.monotonic()))
        self._stop_readers.set()
        for thread in (self._stdout_thread, self._stderr_thread):
            if thread is not None:
                thread.join(timeout=0.5)
        if status != expect_exit:
            details = self.stderr_text()[:2000]
            self.abort()
            raise LspError(f"server exit code {status} != {expect_exit}; stderr: {details!r}")
        self._closed = True
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
        return status

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> bool:
        if exc_type is not None:
            self.abort()
            return False
        if self._closed:
            return False
        # Callers may either explicitly finish the LSP lifecycle or rely on EOF
        # teardown for transport-only / negative protocol tests.
        self.close(expect_exit=0)
        return False
