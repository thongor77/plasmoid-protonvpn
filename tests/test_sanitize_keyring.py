#!/usr/bin/env python3
"""Tests for folding Proton multiline secrets into GKeyFile INI.

From upstream (iamfitsum/omarchy-proton-vpn, tests/test_sanitize_keyring.py)
— only the sys.path line below differs, since sanitize_keyring.py lives
at package/contents/scripts/ here instead of the repo root.
"""

from __future__ import annotations

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "package" / "contents" / "scripts"))

from sanitize_keyring import (  # noqa: E402
    persist_session,
    sanitize_keyring_file,
    sanitize_keyring_text,
)


CORRUPT = """[keyring]
display-name=Default keyring
lock-on-idle=false
lock-after=false

[4]
item-type=0
display-name=Password for 'proton-sso-account' on 'Proton'
secret={"ClientKey": "-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEASnHFoFbMzZGJ4ZHExZ8F1CkN1ccaE4WbNxMj6jzoU+U=
-----END PUBLIC KEY-----"}
mtime=1

[4:attribute0]
name=service
type=0
value=Proton
"""


class SanitizeKeyringTests(unittest.TestCase):
    def test_folds_pem_newlines_and_keeps_base64_padding(self) -> None:
        out = sanitize_keyring_text(CORRUPT)
        self.assertNotIn("\nMCow", out)
        self.assertIn(
            'secret={"ClientKey": "-----BEGIN PUBLIC KEY-----\\n'
            "MCowBQYDK2VwAyEASnHFoFbMzZGJ4ZHExZ8F1CkN1ccaE4WbNxMj6jzoU+U=\\n"
            '-----END PUBLIC KEY-----"}',
            out,
        )
        self.assertIn("name=service", out)
        self.assertIn("value=Proton", out)
        self.assertNotIn("Proton\\n", out)
        self.assertIn("\n\n[4:attribute0]\n", out)

    def test_does_not_fold_blank_line_into_attribute_values(self) -> None:
        text = (
            "[1:attribute0]\n"
            "name=service\n"
            "type=0\n"
            "value=Proton\n"
            "\n"
            "[1:attribute1]\n"
            "name=username\n"
            "type=0\n"
            "value=proton-sso-accounts\n"
        )
        out = sanitize_keyring_text(text)
        self.assertEqual(out, text)

    def test_idempotent_when_already_single_line(self) -> None:
        once = sanitize_keyring_text(CORRUPT)
        self.assertEqual(once, sanitize_keyring_text(once))

    def test_file_rewrite_changes_corrupt_ini(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Default_keyring.keyring"
            path.write_text(CORRUPT, encoding="utf-8")
            self.assertTrue(sanitize_keyring_file(path))
            self.assertFalse(sanitize_keyring_file(path))
            body = path.read_text(encoding="utf-8")
            self.assertIn("\\nMCow", body)
            self.assertNotIn("\nMCow", body)

    def test_persist_noop_without_ini(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            keyring_dir = Path(tmp) / "keyrings"
            keyring_dir.mkdir()
            os.environ["PROTONVPN_KEYRING_DIR"] = str(keyring_dir)
            try:
                self.assertFalse(persist_session())
            finally:
                del os.environ["PROTONVPN_KEYRING_DIR"]
            self.assertFalse((keyring_dir / "default").exists())
            self.assertFalse((keyring_dir / "Default_keyring.keyring").exists())

    def test_persist_folds_ini_and_pins_alias(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            keyring_dir = Path(tmp) / "keyrings"
            keyring_dir.mkdir()
            ini = keyring_dir / "Default_keyring.keyring"
            ini.write_text(CORRUPT, encoding="utf-8")
            (keyring_dir / "default").write_text("Default\n", encoding="utf-8")
            os.environ["PROTONVPN_KEYRING_DIR"] = str(keyring_dir)
            try:
                self.assertTrue(persist_session())
                self.assertFalse(persist_session())
            finally:
                del os.environ["PROTONVPN_KEYRING_DIR"]
            body = ini.read_text(encoding="utf-8")
            self.assertIn("\\nMCow", body)
            self.assertNotIn("\nMCow", body)
            self.assertEqual((keyring_dir / "default").read_text(encoding="utf-8"), "Default_keyring\n")
            self.assertEqual(stat.S_IMODE(ini.stat().st_mode), 0o600)

    def test_persist_skips_encrypted_keyring(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            keyring_dir = Path(tmp) / "keyrings"
            keyring_dir.mkdir()
            ini = keyring_dir / "Default_keyring.keyring"
            ini.write_text("GKR\x00encrypted", encoding="latin-1")
            os.environ["PROTONVPN_KEYRING_DIR"] = str(keyring_dir)
            try:
                self.assertFalse(persist_session())
            finally:
                del os.environ["PROTONVPN_KEYRING_DIR"]
            self.assertEqual(ini.read_text(encoding="latin-1"), "GKR\x00encrypted")
            self.assertFalse((keyring_dir / "default").exists())


if __name__ == "__main__":
    unittest.main()
