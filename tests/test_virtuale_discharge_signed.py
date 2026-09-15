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

from main_app import (  # noqa: E402
    virtuale_apply_discharge,
    virtuale_commit_discharge_item,
    virtuale_correct_closing_item,
    virtuale_nonzero_startup_message,
    virtuale_opening_residual,
    virtuale_replace_discharge_item,
)


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

    def test_final_refund_dump_flips_same_sign_amount(self) -> None:
        r = Decimal("-47.50")
        self.assertEqual(virtuale_correct_closing_item(r, Decimal("-47.50")), Decimal("47.50"))
        self.assertEqual(
            virtuale_apply_discharge(r, virtuale_correct_closing_item(r, Decimal("-47.50"))),
            Decimal("0.00"),
        )
        self.assertEqual(virtuale_correct_closing_item(r, Decimal("47.50")), Decimal("47.50"))

    def test_partial_refund_negative_item_is_not_flipped(self) -> None:
        r = Decimal("-47.50")
        self.assertEqual(virtuale_correct_closing_item(r, Decimal("-10.00")), Decimal("-10.00"))

    def test_expense_closing_keeps_either_sign(self) -> None:
        r = Decimal("80.00")
        self.assertEqual(virtuale_correct_closing_item(r, Decimal("-80.00")), Decimal("-80.00"))
        self.assertEqual(virtuale_correct_closing_item(r, Decimal("80.00")), Decimal("80.00"))

    def test_replace_discharge_flips_refund_item_to_zero(self) -> None:
        self.assertEqual(
            virtuale_replace_discharge_item(Decimal("-95.00"), Decimal("-47.50"), Decimal("47.50")),
            Decimal("0.00"),
        )

    def test_replace_does_not_reopen_zero_residual(self) -> None:
        self.assertEqual(
            virtuale_replace_discharge_item(Decimal("0.00"), Decimal("-47.50"), Decimal("47.50")),
            Decimal("0.00"),
        )

    def test_commit_negative_residual_flips_final_dump_and_zeros(self) -> None:
        saved, after = virtuale_commit_discharge_item(Decimal("-47.50"), Decimal("-47.50"))
        self.assertEqual(saved, Decimal("47.50"))
        self.assertEqual(after, Decimal("0.00"))
        saved_ok, after_ok = virtuale_commit_discharge_item(Decimal("-47.50"), Decimal("47.50"))
        self.assertEqual(saved_ok, Decimal("47.50"))
        self.assertEqual(after_ok, Decimal("0.00"))

    def test_commit_negative_residual_keeps_partial_negative_item(self) -> None:
        saved, after = virtuale_commit_discharge_item(Decimal("-100.00"), Decimal("-15.00"))
        self.assertEqual(saved, Decimal("-15.00"))
        self.assertEqual(after, Decimal("-115.00"))

    def test_scarica_need_for_negative_residual_is_positive(self) -> None:
        residual = Decimal("-47.50")
        need = (-residual).quantize(Decimal("0.01"))
        saved, after = virtuale_commit_discharge_item(residual, need)
        self.assertEqual(need, Decimal("47.50"))
        self.assertEqual(saved, Decimal("47.50"))
        self.assertEqual(after, Decimal("0.00"))

    def test_startup_message_covers_negative_residual(self) -> None:
        msg_neg = virtuale_nonzero_startup_message(Decimal("-12.30"))
        self.assertIn("-12,30", msg_neg)
        self.assertIn("negativo", msg_neg)
        self.assertIn("segno positivo", msg_neg)
        msg_pos = virtuale_nonzero_startup_message(Decimal("12.30"))
        self.assertIn("12,30", msg_pos)
        self.assertNotIn("segno positivo", msg_pos)


if __name__ == "__main__":
    unittest.main()
