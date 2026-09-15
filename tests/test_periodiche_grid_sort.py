#!/usr/bin/env python3
"""Ordinamento griglia registrazioni periodiche."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from periodiche import sort_rules_for_grid  # noqa: E402


def _rule(
    rid: str,
    *,
    cat: str,
    acc: str,
    last: str | None,
    cadence: str = "monthly",
    start: str = "2026-01-15",
    active: bool = True,
) -> dict:
    return {
        "id": rid,
        "active": active,
        "cadence": cadence,
        "start_anchor_iso": start,
        "last_materialized_iso": last,
        "template": {"category_name": cat, "account_primary_name": acc},
    }


class PeriodicheGridSortTests(unittest.TestCase):
    def setUp(self) -> None:
        self.rules = [
            _rule("b", cat="-Spese auto", acc="Cassa", last="2026-03-15"),
            _rule("a", cat="+Stipendio", acc="Banca", last="2026-01-15"),
            _rule("c", cat="-Affitto", acc="Banca", last="2026-02-15"),
            _rule("d", cat="-Spese auto", acc="Carta", last="2026-02-15", active=False),
        ]

    def test_default_sorts_by_next_due_inactive_last(self) -> None:
        # last 15/01 monthly → next 15/02; last 15/02 → 15/03; last 15/03 → 15/04
        ids = [r["id"] for r in sort_rules_for_grid(self.rules, by="next")]
        self.assertEqual(ids, ["a", "c", "b", "d"])

    def test_next_reverse_keeps_inactive_last(self) -> None:
        ids = [r["id"] for r in sort_rules_for_grid(self.rules, by="next", reverse=True)]
        self.assertEqual(ids, ["b", "c", "a", "d"])

    def test_sort_by_category_strips_sign(self) -> None:
        ids = [r["id"] for r in sort_rules_for_grid(self.rules, by="cat")]
        self.assertEqual(ids, ["c", "b", "d", "a"])

    def test_sort_by_account(self) -> None:
        ids = [r["id"] for r in sort_rules_for_grid(self.rules, by="acc1")]
        self.assertEqual(ids, ["a", "c", "d", "b"])


if __name__ == "__main__":
    unittest.main()
