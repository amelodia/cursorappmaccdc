#!/usr/bin/env python3
"""Troncamento testo celle PDF verifica: la nota non deve superare la larghezza colonna."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from main_app import clip_text_to_measured_width  # noqa: E402


class TestClipTextToMeasuredWidth(unittest.TestCase):
    def test_short_text_unchanged(self) -> None:
        self.assertEqual(clip_text_to_measured_width("abc", 10, len), "abc")

    def test_long_text_gets_ellipsis_and_fits(self) -> None:
        long = "Comm. richiesta incasso SEPA B2C " * 4
        out = clip_text_to_measured_width(long, 20, len)
        self.assertLessEqual(len(out), 20)
        self.assertTrue(out.endswith(".."))
        self.assertGreater(len(out), 2)

    def test_empty(self) -> None:
        self.assertEqual(clip_text_to_measured_width("", 10, len), "")


class TestPdfClipNoteColumn(unittest.TestCase):
    def test_fpdf_note_fits_pending_column(self) -> None:
        try:
            from fpdf import FPDF
        except ImportError:
            self.skipTest("fpdf2 non disponibile")
        from main_app import _pdf_clip_text_to_width

        pdf = FPDF(orientation="P", unit="mm", format="A4")
        pdf.add_page()
        pdf.set_font("Helvetica", "", 7)
        note = (
            "SDD Core - Richiesta Incasso SEPA 01M15WWYGGCSH1DAGQ1ZPMYMTT "
            "AMERICAN EXPRESS ITALIA SRL"
        )
        col_w = 90.0
        clipped = _pdf_clip_text_to_width(pdf, note, col_w)
        self.assertLessEqual(pdf.get_string_width(clipped), col_w - 0.5)
        self.assertTrue(clipped.endswith(".."))

    def test_fpdf_note_fits_unverified_column(self) -> None:
        try:
            from fpdf import FPDF
        except ImportError:
            self.skipTest("fpdf2 non disponibile")
        from main_app import _pdf_clip_text_to_width

        pdf = FPDF(orientation="P", unit="mm", format="A4")
        pdf.add_page()
        pdf.set_font("Helvetica", "", 6.5)
        note = "Comm. richiesta incasso SEPA B2C extra testo lungo che non deve coprire Entro il"
        col_w = 65.0
        clipped = _pdf_clip_text_to_width(pdf, note, col_w)
        self.assertLessEqual(pdf.get_string_width(clipped), col_w - 0.5)


if __name__ == "__main__":
    unittest.main()
