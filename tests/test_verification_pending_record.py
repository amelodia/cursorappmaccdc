#!/usr/bin/env python3
"""Registrazione costruita da un dato di verifica in sospeso."""
from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from main_app import (  # noqa: E402
    CREDIT_CARD_CHEQUE_LABEL,
    build_record_from_verification_pending,
    cheque_for_new_record,
)


def _rec(**overrides: object) -> dict:
    base = dict(
        date_iso="2026-10-02",
        amount=Decimal("-25.86"),
        note="interessi e competenze Liq.comp.",
        cheque="",
        category_code="4",
        category_display_name="Consumi ordinari",
        category_stored_name="-Consumi ordinari",
        category_note="",
        account_code="3",
        account_name="BCC.ROMA",
        source_index=12,
        registration_number=400,
    )
    base.update(overrides)
    return build_record_from_verification_pending(**base)  # type: ignore[arg-type]


class TestRecordFromVerificationPending(unittest.TestCase):
    def test_bank_outflow_uses_pending_amount_date_and_note(self) -> None:
        rec = _rec()
        self.assertEqual(rec["date_iso"], "2026-10-02")
        self.assertEqual(rec["amount_eur"], "-25.86")
        self.assertEqual(rec["display_amount"], "-25.86")
        self.assertEqual(rec["account_primary_code"], "3")
        self.assertEqual(rec["account_primary_name"], "BCC.ROMA")
        self.assertEqual(rec["account_secondary_code"], "")
        self.assertEqual(rec["category_code"], "4")
        self.assertEqual(rec["category_name"], "-Consumi ordinari")
        self.assertEqual(rec["note"], "Interessi e competenze Liq.comp.")
        self.assertEqual(rec["cheque"], "-")
        self.assertFalse(rec["is_virtuale_discharge"])
        self.assertEqual(rec["legacy_registration_key"], "APP:manual:2026:12")

    def test_credit_card_cheque_is_fixed(self) -> None:
        self.assertEqual(
            cheque_for_new_record("AMEX", "123", is_credit_card=True),
            CREDIT_CARD_CHEQUE_LABEL,
        )
        rec = _rec(account_name="AMEX", is_credit_card=True, cheque="123")
        self.assertEqual(rec["cheque"], CREDIT_CARD_CHEQUE_LABEL)

    def test_giroconto_keeps_second_account(self) -> None:
        rec = _rec(
            is_giroconto=True,
            secondary_code="1",
            secondary_name="Cassa",
            category_display_name="Girata conto/conto",
            category_stored_name="Girata conto/conto",
            category_code="1",
            amount=Decimal("200.00"),
        )
        self.assertEqual(rec["account_secondary_code"], "1")
        self.assertEqual(rec["account_secondary_name"], "Cassa")
        self.assertEqual(rec["amount_eur"], "200.00")


if __name__ == "__main__":
    unittest.main()
