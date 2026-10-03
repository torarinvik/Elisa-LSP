#!/usr/bin/env python3
"""Run one small native test fixture with a bounded lifetime."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    proc = subprocess.Popen(
        [args.executable],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=(os.name == "posix"),
    )
    try:
        stdout, stderr = proc.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            os.killpg(proc.pid, signal.SIGKILL)
        else:
            proc.kill()
        stdout, stderr = proc.communicate()
        print(
            f"native fixture timed out after {args.timeout:g} seconds: {args.executable}",
            file=sys.stderr,
        )
        if stdout:
            sys.stdout.buffer.write(stdout)
        if stderr:
            sys.stderr.buffer.write(stderr)
        return 1

    if stdout:
        sys.stdout.buffer.write(stdout)
    if stderr:
        sys.stderr.buffer.write(stderr)
    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
