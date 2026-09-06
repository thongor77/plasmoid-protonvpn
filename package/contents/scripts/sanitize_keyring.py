#!/usr/bin/env python3
"""Fold multiline gnome-keyring INI values so GKeyFile can parse them.

Proton stores JSON+PEM in the unencrypted keyring. Literal newlines in
those secrets make gnome-keyring reject the whole file, after which Chrome
creates a new encrypted 'Default' keyring and prompts for a password.

`--persist` sanitizes Omarchy's passwordless INI (if it exists) and pins
the `default` alias to it. It does not create keyrings, restart the
daemon, or quarantine Chrome stores.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

KNOWN_KEYS = (
    "display-name",
    "item-type",
    "ctime",
    "mtime",
    "lock-on-idle",
    "lock-after",
    "secret",
    "key",
    "value",
    "name",
    "type",
)


def is_key_line(line: str) -> bool:
    """Return True if line starts a gnome-keyring INI field."""
    return any(line.startswith(f"{key}=") for key in KNOWN_KEYS)


def sanitize_keyring_text(text: str) -> str:
    """Return INI text with multiline values folded using GKeyFile \\n."""
    lines = text.splitlines()
    out: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if not is_key_line(line):
            out.append(line)
            index += 1
            continue
        key, _, value = line.partition("=")
        index += 1
        parts = [value]
        while (
            index < len(lines)
            and lines[index] != ""
            and not is_key_line(lines[index])
            and not lines[index].startswith("[")
        ):
            parts.append(lines[index])
            index += 1
        if len(parts) == 1:
            out.append(f"{key}={value}")
        else:
            out.append(f"{key}={'\\n'.join(parts)}")
    result = "\n".join(out)
    if text.endswith("\n"):
        result += "\n"
    return result


def sanitize_keyring_file(path: Path) -> bool:
    """Rewrite an INI keyring in place. Returns True if the file changed."""
    if not path.is_file():
        return False
    original = path.read_text(encoding="utf-8")
    if not original.lstrip().startswith("["):
        return False
    sanitized = sanitize_keyring_text(original)
    if sanitized == original:
        return False
    path.write_text(sanitized, encoding="utf-8")
    path.chmod(0o600)
    return True


def keyring_dir() -> Path:
    """Return the gnome-keyring directory, honoring PROTONVPN_KEYRING_DIR."""
    override = os.environ.get("PROTONVPN_KEYRING_DIR")
    if override:
        return Path(override)
    return Path.home() / ".local/share/keyrings"


def persist_session() -> bool:
    """Sanitize Default_keyring.keyring and pin the default alias to it.

    No-ops if the passwordless INI is missing. Does not create keyrings,
    restart gnome-keyring, or move Chrome stores. Returns True if the INI
    or alias file changed.
    """
    directory = keyring_dir()
    ini = directory / "Default_keyring.keyring"
    alias = directory / "default"
    if not ini.is_file():
        return False
    try:
        head = ini.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return False
    if not head.lstrip().startswith("["):
        return False
    changed = sanitize_keyring_file(ini)
    wanted = "Default_keyring\n"
    current = alias.read_text(encoding="utf-8") if alias.is_file() else ""
    if current != wanted:
        alias.write_text(wanted, encoding="utf-8")
        alias.chmod(0o644)
        return True
    return changed


def main(argv: list[str] | None = None) -> int:
    """CLI entry: sanitize one keyring file, or `--persist` the session store."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, nargs="?")
    parser.add_argument(
        "--persist",
        action="store_true",
        help="sanitize Default_keyring.keyring and pin the default alias",
    )
    args = parser.parse_args(argv)
    if args.persist:
        if args.path is not None:
            parser.error("--persist does not take a path")
        persist_session()
        return 0
    if args.path is None:
        parser.error("path or --persist is required")
    sanitize_keyring_file(args.path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
