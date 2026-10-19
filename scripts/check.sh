#!/bin/sh
# Dieselben Prüfungen wie der GitHub-Test-Workflow (Lint + Unit-Tests).
# Aufruf aus dem Repository-Ordner: scripts/check.sh
set -e
PY="${PYTHON:-../.venv/bin/python}"
[ -x "$PY" ] || PY=python3
"$PY" -m ruff check --select F,E9 syllabeat main.py scripts tests
QT_QPA_PLATFORM=offscreen PYTHONPATH=. "$PY" -m unittest discover -s tests
