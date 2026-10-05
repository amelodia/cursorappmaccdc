#!/usr/bin/env python3
"""Verifica: disambiguazione di più movimenti con lo stesso importo tramite data estratto."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from main_app import verification_unique_booking_date_candidate  # noqa: E402


def _cand(reg_n: int, date_iso: str) -> tuple[int, dict]:
    return (reg_n, {"date_iso": date_iso, "note": f"comm {reg_n}"})


class TestVerificationUniqueBookingDate(unittest.TestCase):
    def test_picks_the_only_same_date_among_three_075(self) -> None:
        cands = [
            _cand(30, "2026-09-30"),
            _cand(29, "2026-09-29"),
            _cand(7, "2026-09-07"),
        ]
        rec = verification_unique_booking_date_candidate(cands, "07/09/2026")
        self.assertIsNotNone(rec)
        self.assertEqual(rec["date_iso"], "2026-09-07")
        rec2 = verification_unique_booking_date_candidate(cands, "29/09/2026")
        self.assertEqual(rec2["date_iso"], "2026-09-29")
        rec3 = verification_unique_booking_date_candidate(cands, "30/09/2026")
        self.assertEqual(rec3["date_iso"], "2026-09-30")

    def test_two_digit_year_booking_date(self) -> None:
        cands = [_cand(1, "2026-09-07"), _cand(2, "2026-09-29")]
        rec = verification_unique_booking_date_candidate(cands, "07/09/26")
        self.assertEqual(rec["date_iso"], "2026-09-07")

    def test_none_when_two_share_the_date(self) -> None:
        cands = [_cand(1, "2026-09-07"), _cand(2, "2026-09-07")]
        self.assertIsNone(verification_unique_booking_date_candidate(cands, "07/09/2026"))

    def test_none_when_no_date_or_no_hit(self) -> None:
        cands = [_cand(1, "2026-09-07")]
        self.assertIsNone(verification_unique_booking_date_candidate(cands, ""))
        self.assertIsNone(verification_unique_booking_date_candidate(cands, "11/09/2026"))
        self.assertIsNone(verification_unique_booking_date_candidate([], "07/09/2026"))


if __name__ == "__main__":
    unittest.main()
