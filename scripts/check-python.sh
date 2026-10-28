#!/bin/sh
# Prüfungen der Python-Version 0.2 (Lint + Unit-Tests), bis der Python-Code mit 0.3 entfällt.
# Aufruf aus dem Repository-Ordner: scripts/check-python.sh
set -e
PY="${PYTHON:-../.venv/bin/python}"
[ -x "$PY" ] || PY=python3
"$PY" -m ruff check --select F,E9 syllabeat main.py scripts tests
QT_QPA_PLATFORM=offscreen PYTHONPATH=. "$PY" -m unittest discover -s tests
