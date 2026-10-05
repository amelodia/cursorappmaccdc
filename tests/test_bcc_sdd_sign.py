#!/usr/bin/env python3
"""BCC: SDD / Comm. incasso / disposizione permanente a favore di → DARE (negativo)."""
from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from estratto_conto_pdf import _bcc_build_movement_from_tail  # noqa: E402


def _amt(tail: str) -> Decimal:
    mv, _rest = _bcc_build_movement_from_tail("02/09/26", "02/09/26", tail, max_note_len=500)
    assert mv is not None
    return mv["amount"]  # type: ignore[return-value]


class TestBccSddAndDisposSign(unittest.TestCase):
    def test_sdd_core_is_dare(self) -> None:
        self.assertEqual(
            _amt("42,89 SDD Core - Richiesta Incasso SEPA ABBONATO SKY"),
            Decimal("-42.89"),
        )
        self.assertEqual(
            _amt("3.619,75 SDD Core - Richiesta Incasso SEPA AMERICAN EXPRESS ITALIA"),
            Decimal("-3619.75"),
        )
        self.assertEqual(
            _amt("10,00 SDD Enti Terzo Settore - Richiesta Incasso SEPA Save the Children"),
            Decimal("-10.00"),
        )

    def test_comm_richiesta_incasso_is_dare(self) -> None:
        self.assertEqual(_amt("0,75 Comm. richiesta incasso SEPA B2C"), Decimal("-0.75"))

    def test_dispos_permanente_a_favore_di_is_dare(self) -> None:
        self.assertEqual(
            _amt(
                "200,00 Vs dispos permanente a favore di - da RelaxBanking *INSTANT BEN ANNA MELODIA"
            ),
            Decimal("-200.00"),
        )

    def test_bonifico_a_vs_favore_stays_avere(self) -> None:
        self.assertEqual(
            _amt("400,00 Bonifico a vs favore *COCUZZA MATTEO RIMBORSO BANCOMAT"),
            Decimal("400.00"),
        )

    def test_pensione_stays_avere(self) -> None:
        self.assertEqual(_amt("136,04 Pensione INPS CAVALLO MARIA LUCI"), Decimal("136.04"))


if __name__ == "__main__":
    unittest.main()
