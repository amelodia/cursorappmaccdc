#!/usr/bin/env python3
"""Etichette e segni del riepilogo verifica (senza inversione carta)."""
from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from main_app import (  # noqa: E402
    VER_SUMMARY_DIFF_ROW_LABEL,
    _ver_summary_is_diff_row,
    _ver_summary_row_definitions,
    verification_report_opening_title,
)


class TestVerificationSummaryLabels(unittest.TestCase):
    def test_opening_title_bank_vs_card(self) -> None:
        self.assertEqual(
            verification_report_opening_title("AMEX", is_credit_card=True),
            "Verifica conto AMEX (conto carta)",
        )
        self.assertEqual(
            verification_report_opening_title("BCC.ROMA", is_credit_card=False),
            "Verifica conto BCC.ROMA (conto bancario)",
        )

    def test_row_labels_and_real_signs(self) -> None:
        sum_uv = Decimal("3449.59")
        stmt = Decimal("-1644.16")
        projected = stmt + sum_uv
        saldo = Decimal("-1730.64")
        diff = saldo - projected
        rows = _ver_summary_row_definitions(
            count_unverified=6,
            sum_unverified=sum_uv,
            stmt_balance=stmt,
            projected_estratto=projected,
            saldo_assoluto=saldo,
            diff=diff,
        )
        labels = [d for d, _ in rows]
        vals = [v for _, v in rows]
        self.assertEqual(labels[0], "Valore di 6 registrazioni non verificate")
        self.assertEqual(labels[1], "Saldo dell'estratto conto")
        self.assertEqual(labels[2], "Proiezione del saldo")
        self.assertEqual(labels[3], "Saldo Conti di casa")
        self.assertEqual(labels[4], VER_SUMMARY_DIFF_ROW_LABEL)
        self.assertEqual(vals[2], Decimal("1805.43"))
        self.assertEqual(vals[1], Decimal("-1644.16"))
        self.assertTrue(_ver_summary_is_diff_row(labels[4]))
        self.assertFalse(_ver_summary_is_diff_row("Differenza"))

    def test_zero_balance_coincident_card(self) -> None:
        stmt = Decimal("-1644.16")
        rows = _ver_summary_row_definitions(
            count_unverified=0,
            sum_unverified=Decimal("0.00"),
            stmt_balance=stmt,
            projected_estratto=stmt,
            saldo_assoluto=stmt,
            diff=Decimal("0.00"),
        )
        self.assertEqual(rows[0][0], "Valore di 0 registrazioni non verificate")
        self.assertEqual(rows[1][1], stmt)
        self.assertEqual(rows[2][1], stmt)
        self.assertEqual(rows[3][1], stmt)
        self.assertEqual(rows[4][1], Decimal("0.00"))


if __name__ == "__main__":
    unittest.main()
