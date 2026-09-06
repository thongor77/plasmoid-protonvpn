#!/usr/bin/env python3
"""Tests for split-tunnel desktop-entry filtering.

From upstream (iamfitsum/omarchy-proton-vpn, tests/test_apps.py) — only
the sys.path line below differs, since apps.py lives at
package/contents/scripts/ here instead of the repo root.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "package" / "contents" / "scripts"))

from apps import expand_paths, parse_entry, program_of  # noqa: E402


class ProgramOfTests(unittest.TestCase):
    def test_plain_binary(self) -> None:
        self.assertEqual(program_of("/usr/bin/firefox %u"), "/usr/bin/firefox")

    def test_strips_env(self) -> None:
        self.assertEqual(
            program_of("env FOO=1 /usr/bin/qbittorrent"),
            "/usr/bin/qbittorrent",
        )

    def test_drops_flatpak(self) -> None:
        self.assertIsNone(program_of("flatpak run org.mozilla.firefox"))

    def test_drops_shell(self) -> None:
        self.assertIsNone(program_of("bash -c 'something'"))

    def test_drops_omarchy_launcher(self) -> None:
        self.assertIsNone(program_of("omarchy-launch-webapp https://example.com"))


class ParseEntryTests(unittest.TestCase):
    def test_reads_name_and_exec(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.desktop"
            path.write_text(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=Firefox\n"
                "Exec=/usr/bin/firefox %u\n",
                encoding="utf-8",
            )
            self.assertEqual(
                parse_entry(str(path)),
                ("Firefox", "/usr/bin/firefox %u"),
            )

    def test_skips_hidden(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.desktop"
            path.write_text(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=Hidden\n"
                "Hidden=true\n"
                "Exec=/usr/bin/true\n",
                encoding="utf-8",
            )
            self.assertIsNone(parse_entry(str(path)))

    def test_skips_non_application(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "link.desktop"
            path.write_text(
                "[Desktop Entry]\nType=Link\nName=Site\nURL=https://x\n",
                encoding="utf-8",
            )
            self.assertIsNone(parse_entry(str(path)))


class ExpandPathsTests(unittest.TestCase):
    def test_adds_realpath_partner_for_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "real-bin"
            link = Path(tmp) / "app"
            target.write_text("#!/bin/sh\n", encoding="utf-8")
            target.chmod(0o755)
            link.symlink_to(target)
            out = expand_paths([str(link)])
            self.assertEqual(out[0], str(link))
            self.assertEqual(out[1], str(target.resolve()))

    def test_skips_when_path_is_already_real(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "bin"
            target.write_text("#!/bin/sh\n", encoding="utf-8")
            target.chmod(0o755)
            self.assertEqual(expand_paths([str(target)]), [str(target)])


if __name__ == "__main__":
    unittest.main()
