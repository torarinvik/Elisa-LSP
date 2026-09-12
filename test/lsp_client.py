#!/usr/bin/env python3
"""Shared framed subprocess LSP client for Elisa-LSP protocol tests (B02).

One real server subprocess per test, byte-exact Content-Length framing,
independent JSON decoding, typed-ID response matching, notification ordering,
malformed-frame injection, fragmentation, pipelining, and strict teardown.

Usage from a test:
    from lsp_client import LspSession
    with LspSession(srv_path) as s:
        s.send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
        msg = s.recv(timeout=5.0)  # decoded dict + raw body
"""
import json
import os
import queue
import subprocess
import threading


class LspError(AssertionError):
    pass


def frame(obj) -> bytes:
    if isinstance(obj, (bytes, bytearray)):
        body = bytes(obj)
    else:
        body = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


def frame_bytes(body: bytes) -> bytes:
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body


def parse_stream(buf: bytearray):
    """Extract all complete messages from buf; leave partial bytes in place."""
    out = []
    pos = 0
    while True:
        sep = buf.find(b"\r\n\r\n", pos)
        if sep < 0:
            break
        header = bytes(buf[pos:sep]).decode("ascii", errors="strict")
        length = None
        for line in header.split("\r\n"):
            if ":" in line:
                name, val = line.split(":", 1)
                if name.strip().lower() == "content-length":
                    length = int(val.strip())
        if length is None:
            raise LspError(f"missing Content-Length in header: {header!r}")
        start = sep + 4
        if len(buf) < start + length:
            break
        body = bytes(buf[start:start + length])
        try:
            msg = json.loads(body.decode("utf-8"))
        except Exception as e:
            raise LspError(f"response body is not valid UTF-8 JSON: {e}")
        out.append((msg, body))
        pos = start + length
    del buf[:pos]
    return out


class LspSession:
    def __init__(self, srv_path, startup_timeout=5.0):
        if not (os.path.isfile(srv_path) and os.access(srv_path, os.X_OK)):
            raise LspError(f"server binary missing/not executable: {srv_path} (build first: bash build.sh)")
        self.srv_path = srv_path
        self.startup_timeout = startup_timeout
        self.responses = {}   # typed-id key -> message
        self.notifications = []
        self.raw_bodies = []
        self._buf = bytearray()
        self._stderr_chunks = []

    def __enter__(self):
        self.proc = subprocess.Popen(
            [self.srv_path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self._q: queue.Queue = queue.Queue()
        self._stop = False
        self._reader = threading.Thread(target=self._drain, daemon=True)
        self._reader.start()
        return self

    def _drain(self):
        try:
            while not self._stop:
                chunk = self.proc.stdout.read(4096)
                if not chunk:
                    break
                self._q.put(("out", chunk))
        finally:
            self._q.put(("eof", b""))
        try:
            err = self.proc.stderr.read()
            if err:
                self._stderr_chunks.append(err)
        except Exception:
            pass

    def send(self, obj_or_bytes):
        if isinstance(obj_or_bytes, (bytes, bytearray)):
            data = bytes(obj_or_bytes)
        else:
            data = frame(obj_or_bytes)
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def send_fragmented(self, data: bytes, splits):
        """Write data in fragments at byte offsets in `splits` to test split points."""
        pts = [0] + sorted(splits) + [len(data)]
        for a, b in zip(pts, pts[1:]):
            self.proc.stdin.write(data[a:b])
            self.proc.stdin.flush()

    def _pump(self, timeout):
        try:
            kind, chunk = self._q.get(timeout=timeout)
        except queue.Empty:
            raise LspError("timed out waiting for server output")
        if kind == "out":
            self._buf += chunk
            for msg, body in parse_stream(self._buf):
                self.raw_bodies.append(body)
                if "id" in msg and ("result" in msg or "error" in msg):
                    key = (type(msg["id"]).__name__, msg["id"])
                    if key in self.responses:
                        raise LspError(f"duplicate response for id {msg['id']!r}")
                    self.responses[key] = msg
                elif "method" in msg and "id" not in msg:
                    self.notifications.append(msg)
                else:
                    raise LspError(f"unexpected message shape: {msg!r}")
            return True
        return False

    def wait_response(self, req_id, timeout=5.0):
        import time
        key = (type(req_id).__name__, req_id)
        deadline = time.time() + timeout
        while key not in self.responses:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise LspError(f"no response for id {req_id!r}")
            self._pump(remaining)
        return self.responses[key]

    def recv_any(self, timeout=5.0):
        before_r = len(self.responses)
        before_n = len(self.notifications)
        self._pump(timeout)
        if len(self.responses) > before_r or len(self.notifications) > before_n:
            return True
        raise LspError("no message received")

    def close(self, expect_exit=0):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            rc = self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            rc = self.proc.wait(timeout=5)
            raise LspError(f"server did not exit (killed); stderr: {self.stderr_text()[:2000]!r}")
        self._stop = True
        if rc != expect_exit:
            raise LspError(f"server exit code {rc} != {expect_exit}; stderr: {self.stderr_text()[:2000]!r}")
        if self._buf.strip():
            raise LspError(f"unexpected trailing stdout bytes: {bytes(self._buf)[:200]!r}")
        return rc

    def stderr_text(self):
        try:
            err = self.proc.stderr.read()
            if err:
                self._stderr_chunks.append(err)
        except Exception:
            pass
        return b"".join(self._stderr_chunks).decode(errors="replace")

    def __exit__(self, *exc):
        try:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=3)
        finally:
            self._stop = True
        return False
