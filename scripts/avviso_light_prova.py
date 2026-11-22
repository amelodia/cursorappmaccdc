#!/usr/bin/env python3
"""Ascolto ridotto della prova: segna solo che l'iPhone ha registrazioni non ancora salvate.

Non scrive il database. Esce da solo quando la finestra di prova si riapre.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import light_lan_sync


def main() -> None:
    if len(sys.argv) != 2:
        print("Uso: avviso_light_prova.py CARTELLA_DATI_PROVA", file=sys.stderr)
        sys.exit(2)
    light_lan_sync.serve_notice_until_gui(Path(sys.argv[1]))


if __name__ == "__main__":
    main()
