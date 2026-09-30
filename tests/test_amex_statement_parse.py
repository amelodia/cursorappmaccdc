#!/usr/bin/env python3
"""Parser Amex: importo incollato al riferimento e totali di sezione da non fondere."""
from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from estratto_conto_pdf import (  # noqa: E402
    _amex_merge_wrapped_statement_lines,
    _line_is_summary_not_movement,
    _parse_movement_line,
    _parse_statement_text,
)


class TestAmexPaypalGluedAmountAndSectionTotal(unittest.TestCase):
    def test_glued_paypal_reference_keeps_euro_amount(self) -> None:
        row = _parse_movement_line(
            "23/09/26 24/09/26 PAYPAL *ROWENTA IT ROWE 0789292953127,50",
            max_note_len=500,
        )
        self.assertIsNotNone(row)
        assert row is not None
        self.assertEqual(row["amount"], Decimal("-127.50"))
        self.assertIn("ROWENTA", str(row["note"]).upper())
        self.assertIn("0789292953", str(row["note"]))
        self.assertNotIn("1642", str(row["note"]))

    def test_imposta_di_bollo_glued_amount(self) -> None:
        row = _parse_movement_line(
            "27/09/26 27/09/26 IMPOSTA DI BOLLO2,00",
            max_note_len=500,
        )
        self.assertIsNotNone(row)
        assert row is not None
        self.assertEqual(row["amount"], Decimal("-2.00"))
        self.assertIn("IMPOSTA DI BOLLO", str(row["note"]).upper())

    def test_section_total_is_not_a_movement(self) -> None:
        self.assertTrue(
            _line_is_summary_not_movement(
                "Totale nuove operazioni riferite a SIG ANDREA MELODIA 1.642,16"
            )
        )
        self.assertTrue(
            _line_is_summary_not_movement(
                "Totale interessi, altri addebiti e accrediti sopra descritti 2,00"
            )
        )
        self.assertIsNone(
            _parse_movement_line(
                "Totale nuove operazioni riferite a SIG ANDREA MELODIA 1.642,16",
                max_note_len=500,
            )
        )

    def test_wrap_merge_does_not_steal_section_total_amount(self) -> None:
        lines = [
            "23/09/26 24/09/26 PAYPAL *ROWENTA IT ROWE 0789292953127,50",
            "Totale nuove operazioni riferite a SIG ANDREA MELODIA 1.642,16",
            "<<<AMEX_HRULE>>>",
            "27/09/26 27/09/26 IMPOSTA DI BOLLO2,00",
            "Totale interessi, altri addebiti e accrediti sopra descritti 2,00",
        ]
        merged = _amex_merge_wrapped_statement_lines(lines, max_note_len=500)
        self.assertTrue(any("ROWENTA" in ln and "1.642,16" not in ln for ln in merged))
        self.assertTrue(any(ln.strip().startswith("Totale nuove operazioni") for ln in merged))

        text = "American Express\n" + "\n".join(lines)
        rows, _ = _parse_statement_text(text, max_note_len=500)
        notes = " | ".join(str(r.get("note") or "") for r in rows)
        amounts = [r["amount"] for r in rows]
        self.assertIn(Decimal("-127.50"), amounts)
        self.assertNotIn(Decimal("-1642.16"), amounts)
        self.assertIn(Decimal("-2.00"), amounts)
        self.assertIn("ROWENTA", notes.upper())
        self.assertNotIn("1642", notes)
        self.assertNotIn("nuove operazioni", notes.lower())


if __name__ == "__main__":
    unittest.main()
