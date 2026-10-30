#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Run a command with a deadline, on any platform.

``timeout(1)`` is not on every runner (stock macOS lacks it), and
``ssh -o ConnectTimeout`` only bounds connection setup: a server that
accepts the connection and then stalls would hold the step for ever.
This enforces the deadline the same way everywhere, and the action
already needs ``python3``.

Usage: run_with_timeout.py SECONDS -- COMMAND [ARGUMENT ...]

The command inherits stdin, stdout and stderr. The exit status is the
command's, or 124 when the deadline expired (as ``timeout(1)`` does),
or 127 when the command could not start. A command killed by a signal
reports 128 plus the signal number.
"""

from __future__ import annotations

import subprocess
import sys

_USAGE = "usage: run_with_timeout.py SECONDS -- COMMAND [ARGUMENT ...]"
TIMED_OUT = 124
NOT_RUNNABLE = 127


def run(seconds: int, command: list[str]) -> int:
    """Run the command; return its exit status, or 124 on timeout."""
    try:
        returncode = subprocess.run(command, check=False, timeout=seconds).returncode
    except subprocess.TimeoutExpired:
        print(f"error: the command timed out after {seconds}s", file=sys.stderr)
        return TIMED_OUT
    except OSError:
        print("error: the command could not be run", file=sys.stderr)
        return NOT_RUNNABLE
    return returncode if returncode >= 0 else 128 - returncode


def main(argv: list[str]) -> int:
    """Parse the command line and run the command."""
    if len(argv) < 4 or argv[2] != "--" or not argv[1].isdigit():
        print(_USAGE, file=sys.stderr)
        return 2
    seconds = int(argv[1])
    if seconds < 1:
        print(_USAGE, file=sys.stderr)
        return 2
    return run(seconds, argv[3:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
