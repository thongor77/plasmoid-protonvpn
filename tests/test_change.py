#!/usr/bin/env python3
"""Tests for change.py LogicalServer adapters.

From upstream (iamfitsum/omarchy-proton-vpn, tests/test_change.py) —
only the sys.path line below differs. The functions under test actually
live in servers.py (change.py just imports them), same as upstream.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "package" / "contents" / "scripts"))

from servers import location_of, logicals_as_cache, shuffle_server  # noqa: E402


def fake(**kwargs):
    defaults = {
        "name": "US-NY#1",
        "enabled": True,
        "tier": 0,
        "features": [],
        "city": "New York",
        "entry_country_name": "United States",
        "exit_country": "US",
    }
    defaults.update(kwargs)
    return SimpleNamespace(**defaults)


class LogicalsAsCacheTests(unittest.TestCase):
    def test_packs_features_and_status(self) -> None:
        cache = logicals_as_cache([
            fake(name="US-NY#1", features=[4], tier=0, enabled=True),
            fake(name="CH-US#3", features=[1], tier=2, enabled=True),
            fake(name="DE#1", features=[], tier=2, enabled=False),
        ])
        by_name = {s["Name"]: s for s in cache["LogicalServers"]}
        self.assertEqual(by_name["US-NY#1"]["Features"], 4)
        self.assertEqual(by_name["US-NY#1"]["Status"], 1)
        self.assertEqual(by_name["CH-US#3"]["Features"], 1)
        self.assertEqual(by_name["DE#1"]["Status"], 0)

    def test_shuffle_from_logicals_skips_current_and_plus(self) -> None:
        cache = logicals_as_cache([
            fake(name="US-NY#1", features=[4], tier=0),
            fake(name="CH#1", features=[], tier=0),
            fake(name="DE#1", features=[], tier=2),
            fake(name="CH-US#3", features=[1], tier=2),
        ])
        picked = {shuffle_server(cache, "US-NY#1", True)["name"] for _ in range(40)}
        self.assertEqual(picked, {"CH#1"})


class LocationTests(unittest.TestCase):
    def test_city_and_country(self) -> None:
        self.assertEqual(
            location_of(fake()),
            "New York, United States",
        )

    def test_country_only(self) -> None:
        self.assertEqual(
            location_of(fake(city="", entry_country_name="Japan", name="JP#1")),
            "Japan",
        )

    def test_secure_core_via_entry(self) -> None:
        self.assertEqual(
            location_of(fake(
                name="CH-US#3",
                city="New York",
                features=[1],
                entry_country_name="Switzerland",
            )),
            "New York, via Switzerland",
        )


if __name__ == "__main__":
    unittest.main()
