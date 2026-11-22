#!/bin/zsh
# Avvia Conti di casa sulla cartella di prova, senza cambiare la cartella operativa.
# Non usare questo script per il lavoro di tutti i giorni.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROVA="$HOME/Library/Application Support/ContiDiCasaProva/dati"
if [[ ! -f "$PROVA/PROVA_ISOLATA.txt" ]]; then
  echo "Cartella di prova assente o non marcata: $PROVA" >&2
  exit 1
fi
export CONTI_DATA_WORKSPACE="$PROVA"
cd "$ROOT"
exec python3 main_app.py
