#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Read a Gerrit answer and decide whether the change is visible.

The action's shell script fetches the answer; this module only reads it.
It fails closed: anything other than a recognisable "found" or "not
found" answer raises ParseError, which the caller turns into a failed
step. Reporting "not visible" for an answer nobody understood would let
a broken check pass as a reason to skip verification.

Usage: parse_response.py {ssh|rest} CHANGE_NUMBER FILE
       parse_response.py version FILE

The first form prints ``visible=true|false`` and ``status=<STATUS>``.
The second checks the answer to ``GET /config/server/version``, which a
REST caller uses to tell a missing change from a wrong base URL, and
prints ``version=<VERSION>``. Both exit 2 with a fixed-text message on
stderr when the answer is unusable.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import cast

_STATUS = re.compile(r"^[A-Z_]{1,32}$")
_XSSI_PREFIX = ")]}'"
_VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$")
_USAGE = (
    "usage: parse_response.py {ssh|rest} CHANGE_NUMBER FILE"
    " | parse_response.py version FILE"
)

Record = dict[str, object]


class ParseError(ValueError):
    """The answer is not one this action can interpret."""


@dataclass(frozen=True)
class Verdict:
    """Whether the account can read the change, and its status if so."""

    visible: bool
    status: str = ""


def _loads(text: str) -> object:
    """Decode JSON, typing the result as ``object`` so callers must check it."""
    return cast("object", json.loads(text))


def _record(value: object) -> Record | None:
    """Return the value as a JSON object, or None when it is another type."""
    if isinstance(value, dict):
        return cast("Record", value)
    return None


def _status(value: object) -> str:
    """Return a status Gerrit reported, refusing anything unexpected."""
    if not isinstance(value, str) or not _STATUS.fullmatch(value):
        raise ParseError("the change has no recognisable status")
    return value


def parse_ssh(text: str, change_number: int) -> Verdict:
    """Interpret the JSON lines of ``gerrit query --format=JSON``.

    Gerrit prints one JSON object per matching change, then a final
    ``stats`` object carrying ``rowCount``.
    """
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        raise ParseError("the response is empty")
    try:
        decoded = [_loads(line) for line in lines]
    except json.JSONDecodeError as exc:
        raise ParseError("the response is not JSON lines") from exc

    records = [_record(item) for item in decoded]
    if any(r is not None and r.get("type") == "error" for r in records):
        raise ParseError("Gerrit reported an error")

    stats = records[-1]
    if stats is None or stats.get("type") != "stats":
        raise ParseError("the response has no stats line")
    count = stats.get("rowCount")
    if not isinstance(count, int) or isinstance(count, bool) or count < 0:
        raise ParseError("the stats line has no valid rowCount")

    rows = records[:-1]
    if len(rows) != count:
        raise ParseError("rowCount does not match the rows returned")
    if count == 0:
        return Verdict(visible=False)

    for row in rows:
        if row is not None and row.get("number") == change_number:
            return Verdict(visible=True, status=_status(row.get("status")))
    raise ParseError("the response does not describe the requested change")


def parse_rest(text: str, change_number: int) -> Verdict:
    """Interpret the body of ``GET /changes/<n>``.

    Gerrit prefixes its JSON with ``)]}'`` on a line of its own.
    """
    try:
        record = _record(_loads(text.removeprefix(_XSSI_PREFIX)))
    except json.JSONDecodeError as exc:
        raise ParseError("the response is not JSON") from exc
    if record is None or record.get("_number") != change_number:
        raise ParseError("the response does not describe the requested change")
    return Verdict(visible=True, status=_status(record.get("status")))


def parse_version(text: str) -> str:
    """Interpret the body of ``GET /config/server/version``.

    A server answering for any path with HTTP 200, as a proxy or a login
    page can, is not a Gerrit server. Gerrit answers with a JSON string
    after the XSSI prefix, so require exactly that.
    """
    try:
        value = _loads(text.removeprefix(_XSSI_PREFIX))
    except json.JSONDecodeError as exc:
        raise ParseError("the version response is not JSON") from exc
    if not isinstance(value, str) or not _VERSION.fullmatch(value):
        raise ParseError("the version response is not a version string")
    return value


def _run_version(path: str) -> int:
    """Check a version response; return the process exit status."""
    try:
        version = parse_version(Path(path).read_text(encoding="utf-8"))
    except (ParseError, OSError, UnicodeDecodeError) as exc:
        reason = str(exc) if isinstance(exc, ParseError) else "unreadable input"
        print(f"error: {reason}", file=sys.stderr)
        return 2
    print(f"version={version}")
    return 0


def main(argv: list[str]) -> int:
    """Run the parser; return the process exit status."""
    if len(argv) == 3 and argv[1] == "version":
        return _run_version(argv[2])
    if len(argv) != 4 or argv[1] not in {"ssh", "rest"}:
        print(_USAGE, file=sys.stderr)
        return 2
    try:
        change_number = int(argv[2])
        text = Path(argv[3]).read_text(encoding="utf-8")
        parse = parse_ssh if argv[1] == "ssh" else parse_rest
        verdict = parse(text, change_number)
    except (ParseError, ValueError, OSError) as exc:
        reason = str(exc) if isinstance(exc, ParseError) else "unreadable input"
        print(f"error: {reason}", file=sys.stderr)
        return 2
    print(f"visible={'true' if verdict.visible else 'false'}")
    print(f"status={verdict.status}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
