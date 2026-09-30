#!/usr/bin/env python3
"""Girata di chiusura carta: spunta di verifica solo sul conto carta."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from main_app import (  # noqa: E402
    apply_credit_card_settlement_verification_star,
    newreg_matches_credit_card_settlement_draft,
    verification_flag_star_equivalent_count,
)


def _giro(
    acc1: str,
    acc2: str,
    *,
    flags1: str = "",
    flags2: str = "",
    cat: str = "1",
) -> dict:
    return {
        "category_code": cat,
        "account_primary_code": acc1,
        "account_primary_flags": flags1,
        "account_primary_with_flags": f"{acc1}{flags1}" if acc1 else "",
        "account_secondary_code": acc2,
        "account_secondary_flags": flags2,
        "account_secondary_with_flags": f"{acc2}{flags2}" if acc2 else "",
        "is_cancelled": False,
        "date_iso": "2026-10-01",
    }


def _exp(acc: str, flags: str = "") -> dict:
    return {
        "category_code": "2",
        "account_primary_code": acc,
        "account_primary_flags": flags,
        "account_primary_with_flags": f"{acc}{flags}" if acc else "",
        "account_secondary_code": "",
        "account_secondary_flags": "",
        "account_secondary_with_flags": "",
        "is_cancelled": False,
        "date_iso": "2026-09-20",
    }


class TestCreditCardSettlementStar(unittest.TestCase):
    def test_match_bank_to_card_and_swapped(self) -> None:
        rec = _giro("1", "9")
        self.assertTrue(
            newreg_matches_credit_card_settlement_draft(rec, ref_code="1", cc_code="9")
        )
        self.assertTrue(
            newreg_matches_credit_card_settlement_draft(_giro("9", "1"), ref_code="1", cc_code="9")
        )
        self.assertTrue(
            newreg_matches_credit_card_settlement_draft(_giro("01", "09"), ref_code="1", cc_code="9")
        )
        self.assertFalse(
            newreg_matches_credit_card_settlement_draft(_giro("1", "8"), ref_code="1", cc_code="9")
        )
        self.assertFalse(
            newreg_matches_credit_card_settlement_draft(_giro("1", "9", cat="2"), ref_code="1", cc_code="9")
        )

    def test_stars_only_on_card_secondary_and_advances_double(self) -> None:
        last_stmt = _exp("9", "**")
        settle = _giro("1", "9")
        ordered = [(10, last_stmt), (11, settle)]
        self.assertTrue(
            apply_credit_card_settlement_verification_star(
                ordered, card_code="9", settle_rec=settle
            )
        )
        self.assertEqual(verification_flag_star_equivalent_count(str(last_stmt["account_primary_flags"])), 1)
        self.assertEqual(verification_flag_star_equivalent_count(str(settle["account_secondary_flags"])), 2)
        self.assertEqual(settle["account_secondary_with_flags"], "9**")
        self.assertEqual(str(settle["account_primary_flags"] or ""), "")
        self.assertEqual(settle["account_primary_with_flags"], "1")

    def test_hole_keeps_single_star_on_card_and_previous_double(self) -> None:
        last_stmt = _exp("9", "**")
        hole = _exp("9", "")
        settle = _giro("1", "9")
        ordered = [(10, last_stmt), (11, hole), (12, settle)]
        self.assertTrue(
            apply_credit_card_settlement_verification_star(
                ordered, card_code="9", settle_rec=settle
            )
        )
        self.assertEqual(verification_flag_star_equivalent_count(str(last_stmt["account_primary_flags"])), 2)
        self.assertEqual(str(hole["account_primary_flags"] or ""), "")
        self.assertEqual(verification_flag_star_equivalent_count(str(settle["account_secondary_flags"])), 1)
        self.assertEqual(str(settle["account_primary_flags"] or ""), "")

    def test_card_as_primary_does_not_mark_bank(self) -> None:
        last_stmt = _exp("9", "*")
        settle = _giro("9", "1")
        ordered = [(4, last_stmt), (5, settle)]
        apply_credit_card_settlement_verification_star(ordered, card_code="9", settle_rec=settle)
        self.assertGreaterEqual(
            verification_flag_star_equivalent_count(str(settle["account_primary_flags"])), 1
        )
        self.assertEqual(str(settle["account_secondary_flags"] or ""), "")
        self.assertEqual(settle["account_secondary_with_flags"], "1")


if __name__ == "__main__":
    unittest.main()
