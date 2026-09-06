#!/usr/bin/env python3
"""Tests for servers.py city collapse and Secure Core locate.

From upstream (iamfitsum/omarchy-proton-vpn, tests/test_servers.py) —
only the sys.path line below differs, since servers.py lives at
package/contents/scripts/ here instead of the repo root.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "package" / "contents" / "scripts"))

from servers import (  # noqa: E402
    P2P,
    SECURE_CORE,
    TOR,
    all_cities,
    labels,
    locate,
    shuffle_server,
    status_known,
    usable,
)


CACHE = {
    "LogicalServers": [
        {
            "Name": "US-NY#1",
            "ExitCountry": "US",
            "City": "New York",
            "Status": 1,
            "Features": P2P,
            "Score": 1.0,
            "Load": 20,
            "Tier": 0,
            "Location": {"Lat": 40.7, "Long": -74.0},
        },
        {
            "Name": "US-NY#2",
            "ExitCountry": "US",
            "City": "New York",
            "Status": 1,
            "Features": 0,
            "Score": 5.0,
            "Load": 80,
            "Tier": 0,
            "Location": {"Lat": 40.7, "Long": -74.0},
        },
        {
            "Name": "CH-US#3",
            "ExitCountry": "US",
            "EntryCountry": "CH",
            "City": "New York",
            "Status": 1,
            "Features": SECURE_CORE,
            "Score": 2.0,
            "Load": 10,
            "Tier": 2,
            "Location": {"Lat": 40.7, "Long": -74.0},
        },
        {
            "Name": "DE#1",
            "ExitCountry": "DE",
            "City": "Frankfurt",
            "Status": 1,
            "Features": 0,
            "Score": 4.0,
            "Load": 30,
            "Tier": 2,
            "Location": {"Lat": 50.1, "Long": 8.6},
        },
        {
            "Name": "CH#1",
            "ExitCountry": "CH",
            "City": "Zurich",
            "Status": 1,
            "Features": 0,
            "Score": 3.0,
            "Load": 15,
            "Tier": 0,
            "Location": {"Lat": 47.3, "Long": 8.5},
        },
    ]
}


class LabelTests(unittest.TestCase):
    def test_p2p_and_tor(self) -> None:
        self.assertEqual(labels(P2P | TOR), ["P2P", "Tor"])

    def test_none(self) -> None:
        self.assertEqual(labels(0), [])


class UsableTests(unittest.TestCase):
    def test_regular_server(self) -> None:
        self.assertTrue(usable(CACHE["LogicalServers"][0]))

    def test_skips_secure_core(self) -> None:
        self.assertFalse(usable(CACHE["LogicalServers"][2]))

    def test_status_unknown_keeps_servers(self) -> None:
        down = {"LogicalServers": [{"Status": 0, "Features": 0}]}
        self.assertFalse(status_known(down))


class CityTests(unittest.TestCase):
    def test_one_row_per_city_keeps_best_score(self) -> None:
        cities = all_cities(CACHE)
        ny = [c for c in cities if c["city"] == "New York"]
        self.assertEqual(len(ny), 1)
        self.assertEqual(ny[0]["name"], "US-NY#1")
        self.assertEqual(ny[0]["count"], 2)

    def test_secure_core_not_listed_as_city(self) -> None:
        cities = all_cities(CACHE)
        self.assertEqual({c["name"] for c in cities}, {"US-NY#1", "CH#1", "DE#1"})

    def test_plus_only_country_is_not_free(self) -> None:
        cities = all_cities(CACHE)
        de = [c for c in cities if c["code"] == "DE"]
        self.assertEqual(len(de), 1)
        self.assertFalse(de[0]["free"])
        self.assertEqual(de[0]["tier"], 2)
        us = [c for c in cities if c["code"] == "US"]
        self.assertTrue(us[0]["free"])


class LocateTests(unittest.TestCase):
    def test_regular_server(self) -> None:
        place = locate(CACHE, "US-NY#1")
        self.assertEqual(place["city"], "New York")
        self.assertTrue(place["p2p"])
        self.assertNotIn("entry", place)

    def test_secure_core_includes_entry_hop(self) -> None:
        place = locate(CACHE, "CH-US#3")
        self.assertIn("entry", place)
        self.assertEqual(place["entry"]["code"], "CH")
        self.assertEqual(place["entry"]["city"], "Zurich")

    def test_missing(self) -> None:
        self.assertEqual(locate(CACHE, "NOPE"), {})


class ShuffleTests(unittest.TestCase):
    def test_free_shuffle_skips_current_and_plus(self) -> None:
        picked = {shuffle_server(CACHE, "US-NY#1", True)["name"] for _ in range(40)}
        self.assertTrue(picked)
        self.assertNotIn("US-NY#1", picked)
        self.assertNotIn("DE#1", picked)
        self.assertNotIn("CH-US#3", picked)

    def test_paid_shuffle_can_pick_plus_server(self) -> None:
        names = {shuffle_server(CACHE, "CH#1", False)["name"] for _ in range(80)}
        self.assertIn("DE#1", names)


if __name__ == "__main__":
    unittest.main()
