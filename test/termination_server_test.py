#!/usr/bin/env python3
"""Verify installed POSIX termination signals exit the real LSP cleanly."""

from __future__ import annotations

import os
import signal
import sys

sys.path.insert(0, os.path.dirname(__file__))
from lsp_client import LspSession


def main() -> None:
    server = os.path.join(os.path.dirname(__file__), "..", "build", "elisa-lsp")
    checked = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    for number in checked:
        with LspSession(server, startup_timeout=3, request_timeout=5, teardown_timeout=5) as client:
            initialized = client.request("initialize", {"capabilities": {}})
            assert "result" in initialized, initialized
            client.notify("initialized", {})
            assert client.proc is not None
            os.kill(client.proc.pid, number)
            status = client.close(expect_exit=128 + number, timeout=5)
            assert status == 128 + number, (number, status)
    print("server termination OK: SIGINT, SIGTERM, and SIGHUP return 128+signal")


if __name__ == "__main__":
    main()
