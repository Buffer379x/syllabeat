# Changelog

## 0.1.0 – 2026-10-19

Erste veröffentlichte Version unter dem Namen **SyllaBeat** (vorher interner Entwicklungsstand „Video Creator 1.0.0“).

### Abgeschlossen (Stand bei Abbruch der Codex-Sitzung)
- DMG-Erstellung repariert: Der letzte Build brach bei `hdiutil create` mit „Ordner nicht leer“ ab, weil ein alter Staging-Ordner wiederverwendet wurde. Staging wird jetzt immer neu erzeugt (`ditto`), hdiutil wird wiederholt und das Image verifiziert. Ergebnis: `dist/SyllaBeat-<version>.dmg`.
- Reproduzierbarer Release-Build per GitHub Actions (Tests, App-Build, Selbsttest der gebauten App, DMG + SHA-256, GitHub Release).
- Binär-Download mit `--fallback-latest`, falls eine gepinnte Download-URL verschwindet.

### Neu
- Drag & Drop für Videoordner, Videodateien, Songs und Projektdateien.
- Format-Vorlagen für die Timeline (Full HD, 4K, 720p, Hochformat 9:16, Quadrat, Kino 2,39:1).
- Vorschaubilder im Clip-Katalog direkt beim Einlesen; Such-/Filterfeld; Fortschrittszähler „x/y beschrieben“.
- Vision-Analyse fehlertolerant (ein defekter Clip bricht nicht mehr alles ab), mit echtem Fortschrittsbalken und Fortsetzen-Modus „Nur Clips ohne Beschreibung“.
- Schnittraster für Beats: jeden 2. Beat, nur Taktanfänge, Beats verdoppeln, gemeinsamer ms-Versatz.
- Tempo (BPM) in der Songanalyse.
- Song ab ausgewählter Einstellung abspielen (Doppelklick in der Schnittliste).
- „Zuletzt geöffnet“, Tastenkürzel ⌘1–⌘5 für die Arbeitsschritte, „Über SyllaBeat“, „Datenordner im Finder zeigen“.
- Haken in der Seitenleiste für erledigte Schritte; Fenstertitel mit Projektname und Änderungsmarkierung.
- Erneutes Einlesen unveränderter Medien verwirft den geprüften Schnittplan nicht mehr.

### Geändert
- Projektdateien heißen `.syllabeat`; `.vcproject` wird weiterhin geöffnet.
- Datenordner `~/Library/Application Support/SyllaBeat`; der alte Ordner „Video Creator“ (inkl. Modelle) wird einmalig übernommen, ebenso der API-Key im Schlüsselbund.
- Version an einer Stelle (`syllabeat/__init__.py`), Info.plist übernimmt sie automatisch.
