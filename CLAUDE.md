# SyllaBeat – Arbeitsregeln

Repository-Ordner: `syllabeat-git` (nur dort liegt `.git`). Remote: github.com/Buffer379x/syllabeat.

## „Baue Version X“
1. Version in `syllabeat/__init__.py` setzen; `tests/test_release_features.py` (Versionstest), `README.md`, `BEDIENUNG.html` und `CHANGELOG.md` anpassen.
2. `scripts/check.sh` ausführen (Ruff + Unit-Tests). Erst bei grün weiter.
3. Committen und `main` pushen, dann Tag `vX` setzen und pushen – der Tag startet den Workflow „Release (macOS DMG)“, der die DMG baut und das GitHub-Release anlegt.
4. CI beobachten (`gh run watch`, falls `gh` angemeldet ist); bei Fehlern beheben, neuen Commit pushen und den Tag auf den neuen Commit setzen.
5. Prüfen: Release enthält `SyllaBeat-X.dmg` + `.sha256`, Notizen ohne Claude-Verweise.

## Autorschaft
Commits nur unter Buffer379x <clear.bread3889@safehi.de>. Keine „Co-Authored-By“- und keine „Claude-Session“-Zeilen in Commit-Nachrichten, Tags oder Release-Texten.
