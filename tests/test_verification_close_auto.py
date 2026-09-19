#!/usr/bin/env python3
"""Chiusura verifica senza conferma: data girata carta e importo negativo da estratto."""
from __future__ import annotations

import sys
import unittest
from datetime import date
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from main_app import (  # noqa: E402
    credit_card_close_settlement_amount,
    first_day_of_month_after,
    verification_close_can_skip_confirm,
)


class TestVerificationCloseAuto(unittest.TestCase):
    def test_first_day_of_month_after_mid_month(self) -> None:
        self.assertEqual(first_day_of_month_after(date(2026, 9, 19)), date(2026, 10, 1))

    def test_first_day_of_month_after_december(self) -> None:
        self.assertEqual(first_day_of_month_after(date(2026, 12, 31)), date(2027, 1, 1))

    def test_skip_confirm_only_when_clean_and_matched(self) -> None:
        self.assertTrue(
            verification_close_can_skip_confirm(
                pending_unverified=0, pdf_queue_remaining=False, match_ok=True
            )
        )
        self.assertFalse(
            verification_close_can_skip_confirm(
                pending_unverified=1, pdf_queue_remaining=False, match_ok=True
            )
        )
        self.assertFalse(
            verification_close_can_skip_confirm(
                pending_unverified=0, pdf_queue_remaining=True, match_ok=True
            )
        )
        self.assertFalse(
            verification_close_can_skip_confirm(
                pending_unverified=0, pdf_queue_remaining=False, match_ok=False
            )
        )

    def test_settlement_amount_always_negative(self) -> None:
        self.assertEqual(credit_card_close_settlement_amount(Decimal("-1234.56")), Decimal("-1234.56"))
        self.assertEqual(credit_card_close_settlement_amount(Decimal("99.10")), Decimal("-99.10"))
        self.assertIsNone(credit_card_close_settlement_amount(Decimal("0.00")))
        self.assertIsNone(credit_card_close_settlement_amount(None))


if __name__ == "__main__":
    unittest.main()
