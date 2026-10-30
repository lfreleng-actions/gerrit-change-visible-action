# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Tests for scripts/run_with_timeout.py."""

from __future__ import annotations

import subprocess
import sys
import time
import unittest
from pathlib import Path

RUNNER = str(Path(__file__).resolve().parent.parent / "scripts" / "run_with_timeout.py")


def run_runner(*args: str) -> tuple[int, str, str, float]:
    """Run the runner; return its status, output and elapsed seconds."""
    started = time.monotonic()
    done = subprocess.run(
        [sys.executable, RUNNER, *args],
        capture_output=True,
        text=True,
        check=False,
    )
    return done.returncode, done.stdout, done.stderr, time.monotonic() - started


class RunWithTimeout(unittest.TestCase):
    """The deadline holds on every platform, and nothing else changes."""

    def test_passes_through_output_and_success(self) -> None:
        code, out, _, _ = run_runner("5", "--", "echo", "hello")
        self.assertEqual((code, out), (0, "hello\n"))

    def test_passes_through_the_exit_status(self) -> None:
        code, _, _, _ = run_runner(
            "5", "--", sys.executable, "-c", "raise SystemExit(7)"
        )
        self.assertEqual(code, 7)

    def test_a_stalled_command_is_stopped_at_the_deadline(self) -> None:
        code, _, err, elapsed = run_runner(
            "1", "--", sys.executable, "-c", "import time; time.sleep(30)"
        )
        self.assertEqual(code, 124)
        self.assertEqual(err, "error: the command timed out after 1s\n")
        self.assertLess(elapsed, 10)

    def test_a_command_that_cannot_start_reports_127(self) -> None:
        code, _, err, _ = run_runner("5", "--", "/nonexistent/command")
        self.assertEqual((code, err), (127, "error: the command could not be run\n"))

    def test_a_signalled_command_reports_128_plus_the_signal(self) -> None:
        script = "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"
        code, _, _, _ = run_runner("5", "--", sys.executable, "-c", script)
        self.assertEqual(code, 128 + 15)

    def test_bad_usage(self) -> None:
        cases = [
            (),
            ("5",),
            ("5", "echo", "x"),
            ("abc", "--", "echo", "x"),
            ("0", "--", "echo", "x"),
            ("-1", "--", "echo", "x"),
        ]
        for args in cases:
            with self.subTest(args=args):
                code, _, _, _ = run_runner(*args)
                self.assertEqual(code, 2)


if __name__ == "__main__":
    _ = unittest.main()
