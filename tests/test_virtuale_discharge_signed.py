#!/usr/bin/env python3
"""Scarico VIRTUALE: spesa (residuo > 0) vs rimborso (residuo < 0)."""
from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from main_app import virtuale_apply_discharge, virtuale_opening_residual  # noqa: E402


class VirtualeDischargeSignedTests(unittest.TestCase):
    def test_expense_giro_uses_absolute_residual(self) -> None:
        self.assertEqual(
            virtuale_opening_residual(Decimal("-120.00"), virtuale_is_source=False),
            Decimal("120.00"),
        )
        self.assertEqual(
            virtuale_opening_residual(Decimal("50.00"), virtuale_is_source=False),
            Decimal("50.00"),
        )

    def test_refund_giro_keeps_signed_residual(self) -> None:
        self.assertEqual(
            virtuale_opening_residual(Decimal("-80.50"), virtuale_is_source=True),
            Decimal("-80.50"),
        )
        self.assertEqual(
            virtuale_opening_residual(Decimal("10.00"), virtuale_is_source=True),
            Decimal("10.00"),
        )

    def test_expense_discharge_ignores_item_sign(self) -> None:
        r = Decimal("100.00")
        self.assertEqual(virtuale_apply_discharge(r, Decimal("-40.00")), Decimal("60.00"))
        self.assertEqual(virtuale_apply_discharge(r, Decimal("40.00")), Decimal("60.00"))
        self.assertEqual(virtuale_apply_discharge(Decimal("30.00"), Decimal("-50.00")), Decimal("0.00"))

    def test_refund_positive_item_reduces_negative_residual(self) -> None:
        r = Decimal("-100.00")
        self.assertEqual(virtuale_apply_discharge(r, Decimal("40.00")), Decimal("-60.00"))
        self.assertEqual(virtuale_apply_discharge(Decimal("-60.00"), Decimal("60.00")), Decimal("0.00"))

    def test_refund_negative_item_increases_negative_residual(self) -> None:
        r = Decimal("-100.00")
        self.assertEqual(virtuale_apply_discharge(r, Decimal("-15.00")), Decimal("-115.00"))

    def test_refund_does_not_cross_above_zero(self) -> None:
        self.assertEqual(
            virtuale_apply_discharge(Decimal("-20.00"), Decimal("50.00")),
            Decimal("0.00"),
        )


if __name__ == "__main__":
    unittest.main()
