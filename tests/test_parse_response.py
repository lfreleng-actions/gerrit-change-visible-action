# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Tests for scripts/parse_response.py."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts import parse_response as pr

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"

STATS_0 = '{"type":"stats","rowCount":0,"moreChanges":false}'
STATS_1 = '{"type":"stats","rowCount":1,"moreChanges":false}'


def row(number: int = 5, status: str = "NEW") -> str:
    """Return one ``gerrit query`` result line."""
    return f'{{"project":"sandbox","number":{number},"status":"{status}"}}'


class ParseSsh(unittest.TestCase):
    """Interpreting ``gerrit query --format=JSON`` output."""

    def test_found(self) -> None:
        verdict = pr.parse_ssh(f"{row()}\n{STATS_1}\n", 5)
        self.assertEqual(verdict, pr.Verdict(visible=True, status="NEW"))

    def test_closed_statuses_are_visible(self) -> None:
        for status in ("MERGED", "ABANDONED"):
            with self.subTest(status=status):
                verdict = pr.parse_ssh(f"{row(5, status)}\n{STATS_1}", 5)
                self.assertEqual(verdict, pr.Verdict(visible=True, status=status))

    def test_not_found(self) -> None:
        self.assertEqual(pr.parse_ssh(STATS_0, 5), pr.Verdict(visible=False))

    def test_rejections(self) -> None:
        cases = {
            "empty": "",
            "blank": "\n\n",
            "not json": "nope",
            "no stats": row(),
            "count mismatch": f"{STATS_1}",
            "zero count with a row": f"{row()}\n{STATS_0}",
            "negative count": '{"type":"stats","rowCount":-1}',
            "boolean count": '{"type":"stats","rowCount":true}',
            "other change": f"{row(6)}\n{STATS_1}",
            "gerrit error": '{"type":"error","message":"boom"}\n' + STATS_0,
            "bad status": f"{row(5, 'new')}\n{STATS_1}",
            "stats not last": f"{STATS_1}\n{row()}",
        }
        for name, text in cases.items():
            with self.subTest(case=name), self.assertRaises(pr.ParseError):
                _ = pr.parse_ssh(text, 5)


class ParseRest(unittest.TestCase):
    """Interpreting ``GET /changes/<n>`` bodies."""

    def test_found_with_xssi_prefix(self) -> None:
        body = ")]}'\n" + '{"_number":5,"status":"MERGED"}'
        verdict = pr.parse_rest(body, 5)
        self.assertEqual(verdict, pr.Verdict(visible=True, status="MERGED"))

    def test_found_without_prefix(self) -> None:
        verdict = pr.parse_rest('{"_number":5,"status":"NEW"}', 5)
        self.assertTrue(verdict.visible)

    def test_rejections(self) -> None:
        cases = {
            "html": "<html></html>",
            "empty": "",
            "list": ")]}'\n[]",
            "other change": '{"_number":6,"status":"NEW"}',
            "no number": '{"status":"NEW"}',
            "no status": '{"_number":5}',
            "bad status": '{"_number":5,"status":"n3w"}',
        }
        for name, text in cases.items():
            with self.subTest(case=name), self.assertRaises(pr.ParseError):
                _ = pr.parse_rest(text, 5)


class Cli(unittest.TestCase):
    """The command line the shell script drives."""

    def run_cli(self, mode: str, number: str, text: str) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "response"
            _ = path.write_text(text, encoding="utf-8")
            done = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS / "parse_response.py"),
                    mode,
                    number,
                    str(path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        return done.returncode, done.stdout, done.stderr

    def test_visible(self) -> None:
        code, out, _ = self.run_cli("ssh", "5", f"{row()}\n{STATS_1}")
        self.assertEqual((code, out), (0, "visible=true\nstatus=NEW\n"))

    def test_not_visible(self) -> None:
        code, out, _ = self.run_cli("ssh", "5", STATS_0)
        self.assertEqual((code, out), (0, "visible=false\nstatus=\n"))

    def test_unusable_answer_exits_two_with_a_fixed_message(self) -> None:
        code, out, err = self.run_cli("rest", "5", "<html>")
        self.assertEqual((code, out), (2, ""))
        self.assertEqual(err, "error: the response is not JSON\n")

    def test_bad_usage(self) -> None:
        code, _, _ = self.run_cli("carrier-pigeon", "5", "")
        self.assertEqual(code, 2)

    def test_non_numeric_change_exits_two(self) -> None:
        code, _, err = self.run_cli("ssh", "five", STATS_0)
        self.assertEqual((code, err), (2, "error: unreadable input\n"))


if __name__ == "__main__":
    _ = unittest.main()
