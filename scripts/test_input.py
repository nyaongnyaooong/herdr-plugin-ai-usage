#!/usr/bin/env python3
"""Regression tests for dashboard arrow keys and Herdr socket RPC."""

import importlib.util
import os
import pty
import subprocess
import sys
import time


ROOT = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.join(ROOT, "ai-usage.py")


def load_module():
    spec = importlib.util.spec_from_file_location("ai_usage", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def arrow_from_pty(payload):
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        [
            sys.executable,
            "-c",
            (
                "import importlib.util,sys\n"
                f"spec=importlib.util.spec_from_file_location('ai_usage', {MODULE_PATH!r})\n"
                "mod=importlib.util.module_from_spec(spec)\n"
                "spec.loader.exec_module(mod)\n"
                "sys.stderr.write('ready\\n'); sys.stderr.flush()\n"
                "sys.stdout.write(mod.read_key())\n"
                "sys.stdout.flush()\n"
            ),
        ],
        stdin=slave,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    os.close(slave)
    ready = b""
    while b"ready\n" not in ready:
        chunk = proc.stderr.read(1)
        if not chunk:
            break
        ready += chunk
    time.sleep(0.2)
    os.write(master, payload)
    try:
        stdout, stderr = proc.communicate(timeout=2)
    finally:
        os.close(master)
    if proc.returncode != 0:
        raise AssertionError((ready + stderr).decode("utf-8", "replace") or f"exit {proc.returncode}")
    return stdout.decode("utf-8", "replace")


def test_arrow_keys():
    expected = {
        b"\x1b[A": "up",
        b"\x1b[B": "down",
        b"\x1b[C": "right",
        b"\x1b[D": "left",
        b"\x1bOA": "up",
        b"\x1b[1;2A": "up",
        b"\x1b[1;2B": "down",
        b"\x1b[1;2C": "right",
        b"\x1b[1;2D": "left",
    }
    for payload, name in expected.items():
        got = arrow_from_pty(payload)
        if got != name:
            raise SystemExit(f"arrow {payload!r}: expected {name}, got {got!r}")


def test_socket_rpc():
    module = load_module()
    payload = module.rpc("layout.export", {"tab_id": os.environ["HERDR_TAB_ID"]})
    if not payload or "result" not in payload:
        raise SystemExit(f"socket rpc failed: {payload!r}")


def main():
    test_arrow_keys()
    test_socket_rpc()
    print("ok")


if __name__ == "__main__":
    main()
