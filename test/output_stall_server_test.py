#!/usr/bin/env python3
"""Ensure a real server exits when a large response stalls on unread stdout."""

from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import time


def frame(value: object) -> bytes:
    body = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


class Reader:
    def __init__(self, pipe) -> None:
        self.fd = pipe.fileno()
        self.buffer = bytearray()

    def _read_until(self, size: int, delimiter: bytes | None, deadline: float) -> None:
        while (delimiter is not None and self.buffer.find(delimiter) < 0) or (
            delimiter is None and len(self.buffer) < size
        ):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                raise AssertionError("timed out waiting for initialize response")
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise AssertionError("server closed stdout before initialize response")
            self.buffer.extend(chunk)

    def read_message(self, timeout: float = 5.0) -> dict:
        deadline = time.monotonic() + timeout
        self._read_until(0, b"\r\n\r\n", deadline)
        header_end = self.buffer.index(b"\r\n\r\n")
        header = bytes(self.buffer[:header_end])
        del self.buffer[: header_end + 4]
        lengths = [
            int(line.partition(b":")[2].strip())
            for line in header.split(b"\r\n")
            if line.lower().startswith(b"content-length:")
        ]
        assert len(lengths) == 1, header
        self._read_until(lengths[0], None, deadline)
        body = bytes(self.buffer[: lengths[0]])
        del self.buffer[: lengths[0]]
        decoded = json.loads(body)
        assert isinstance(decoded, dict), decoded
        return decoded


def write_all(pipe, value: bytes) -> None:
    view = memoryview(value)
    while view:
        written = pipe.write(view)
        if written is None or written <= 0:
            raise AssertionError("could not write test request to server")
        view = view[written:]
    pipe.flush()


def incomplete_trailing_frame(data: bytes) -> bool:
    offset = 0
    incomplete = False
    while offset < len(data):
        header_end = data.find(b"\r\n\r\n", offset)
        if header_end < 0:
            return offset < len(data)
        header = data[offset:header_end]
        lengths = [
            int(line.partition(b":")[2].strip())
            for line in header.split(b"\r\n")
            if line.lower().startswith(b"content-length:")
        ]
        assert len(lengths) == 1, header
        body_start = header_end + 4
        frame_end = body_start + lengths[0]
        if frame_end > len(data):
            incomplete = True
            offset = len(data)
        else:
            json.loads(data[body_start:frame_end])
            offset = frame_end
    return incomplete


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    server = os.path.join(root, "build", "elisa-lsp")
    env = os.environ.copy()
    env["ELISA_LSP_WRITE_TIMEOUT_MS"] = "150"
    proc = subprocess.Popen(
        [server], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        bufsize=0, env=env,
    )
    assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None
    reader = Reader(proc.stdout)
    try:
        write_all(proc.stdin, frame({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"capabilities": {}},
        }))
        initialize = reader.read_message()
        assert initialize.get("id") == 1 and "result" in initialize, initialize

        source = "".join(
            f"def function_{index:04d}() -> i64:\n    return 1\n"
            for index in range(800)
        )
        messages = b"".join([
            frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
            frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
                "textDocument": {
                    "uri": "file:///output-stall.elisa", "languageId": "Elisa",
                    "version": 1, "text": source,
                }
            }}),
            frame({"jsonrpc": "2.0", "id": 2, "method": "textDocument/documentSymbol",
                  "params": {"textDocument": {"uri": "file:///output-stall.elisa"}}}),
        ])
        write_all(proc.stdin, messages)
        started = time.monotonic()
        status = proc.wait(timeout=20)
        elapsed = time.monotonic() - started
        stdout = bytearray(reader.buffer)
        while True:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            stdout.extend(chunk)
        stderr = proc.stderr.read()
        assert status == 1, f"stalled response should exit with transport status 1, got {status}; stderr={stderr!r}"
        assert elapsed < 20, f"stalled server exceeded the test deadline ({elapsed:.2f}s)"
        assert incomplete_trailing_frame(bytes(stdout)), (
            "the response should stop at a partial final frame after the pipe fills; "
            f"captured {len(stdout)} stdout bytes, stderr={stderr!r}"
        )
        print("server output backpressure OK: whole-frame timeout bounds a stalled client")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        if proc.stdin is not None:
            proc.stdin.close()
        if proc.stdout is not None:
            proc.stdout.close()
        if proc.stderr is not None:
            proc.stderr.close()


if __name__ == "__main__":
    main()
