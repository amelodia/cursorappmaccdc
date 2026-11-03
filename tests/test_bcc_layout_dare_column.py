#!/usr/bin/env python3
"""BCC: la colonna layout MOV.DARE / MOV.AVERE fissa il segno se c'è un solo importo."""
from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from estratto_conto_pdf import (  # noqa: E402
    _bcc_build_movement_from_tail,
    _parse_statement_text,
)

# Spaziatura reale dell'estratto BCC (layout pypdf): Dare termina ~col 35, Avere ~col 49.
_HEADER = "  DATA      VALUTA     MOV.DARE      MOV.AVERE      DESCRIZIONE OPERAZIONI"
_DARE_25 = (
    "02/10/26  30/09/26            25,86                 "
    "Interessi e competenze Liq.comp. 0002/003/015270"
)
_AVERE_DIV = (
    "29/10/26  28/10/26                            6,28  "
    "Dividendi della banca LIQ. DIVIDENDI"
)
_AVERE_PEN = "01/10/26  01/10/26                         136,04   Pensione INPS"
_DARE_SDD = (
    "01/10/26  01/10/26            44,89                 "
    "SDD Core - Richiesta Incasso SEPA"
)
_DARE_NEUTRAL = (
    "11/08/26  11/08/26        2.000,00                  Emissione assegni circolari"
)
_SALDO = "30/10/26  ********                       5.045,15   SALDO FINALE"


def _amt(tail: str) -> Decimal:
    mv, _rest = _bcc_build_movement_from_tail("02/10/26", "30/09/26", tail, max_note_len=500)
    assert mv is not None
    return mv["amount"]  # type: ignore[return-value]


class TestBccLayoutDareColumn(unittest.TestCase):
    def test_layout_puts_competenze_in_dare_and_keeps_avere(self) -> None:
        text = "\n".join(
            [
                "BCC ROMA",
                _HEADER,
                _AVERE_PEN,
                _DARE_SDD,
                _DARE_25,
                _DARE_NEUTRAL,
                _AVERE_DIV,
                _SALDO,
            ]
        )
        rows, closing = _parse_statement_text(text, max_note_len=500)
        by_note = {str(row["note"]): row["amount"] for row in rows}
        self.assertEqual(by_note["Pensione INPS"], Decimal("136.04"))
        self.assertEqual(by_note["SDD Core - Richiesta Incasso SEPA"], Decimal("-44.89"))
        self.assertEqual(
            by_note["Interessi e competenze Liq.comp. 0002/003/015270"],
            Decimal("-25.86"),
        )
        self.assertEqual(by_note["Emissione assegni circolari"], Decimal("-2000.00"))
        self.assertEqual(by_note["Dividendi della banca LIQ. DIVIDENDI"], Decimal("6.28"))
        self.assertEqual(closing, Decimal("5045.15"))

    def test_competenze_without_layout_still_dare(self) -> None:
        self.assertEqual(
            _amt("25,86 Interessi e competenze Liq.comp. 0002/003/015270"),
            Decimal("-25.86"),
        )

    def test_dividendi_liq_stays_avere_without_layout(self) -> None:
        self.assertEqual(
            _amt("6,28 Dividendi della banca LIQ. DIVIDENDI"),
            Decimal("6.28"),
        )

    def test_explicit_avere_label_overrides_competenze_keyword(self) -> None:
        self.assertEqual(
            _amt("MOV.AVERE 25,86 Interessi e competenze Liq.comp."),
            Decimal("25.86"),
        )


if __name__ == "__main__":
    unittest.main()
