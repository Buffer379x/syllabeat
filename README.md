# SyllaBeat

Eigenständige macOS-Desktop-App für Apple Silicon, die aus einem Song und einem Ordner voller Videoclips einen beatgenauen Musikvideo-Schnitt plant. GUI auf Deutsch, lokale Beat-/Gesangsanalyse, Ollama Vision, automatische oder manuelle KI-Regie und Timeline-Export für Final Cut Pro, Premiere, DaVinci Resolve & Co.

**Version 0.1.0** · macOS 15+ · Apple Silicon

## Installation

1. Unter [Releases](https://github.com/Buffer379x/syllabeat/releases) die Datei `SyllaBeat-<version>.dmg` laden.
2. DMG öffnen und **SyllaBeat** in den Programme-Ordner ziehen.
3. Beim ersten Start Rechtsklick → **Öffnen** (die App ist ad-hoc signiert, nicht notarisiert).

Python, Homebrew oder Terminalbefehle sind nicht nötig. KI-Modelle (Whisper, Ollama) lädt die App bei Bedarf selbst. Die ausführliche Anleitung liegt in `BEDIENUNG.html` und unter **Hilfe → Bedienungsanleitung**.

## Funktionen

- **Medien:** Videoordner und Song wählen oder per Drag & Drop ins Fenster ziehen; Format-Vorlagen (16:9, 4K, 9:16, 1:1 …) und rationale Bildraten.
- **Clip-Katalog:** ffprobe/OpenCV-Metadaten, Vorschaubilder, VFR-Erkennung, CFR-Arbeitskopien (ProRes), Filter/Suche.
- **Ollama Vision** (`qwen2.5vl:7b`): Beschreibung, Motiv, Handlung, Stimmung, Tags; fehlertolerant und fortsetzbar; Umbenennung mit Vorschau, Kollisionsschutz und Undo.
- **Songanalyse:** librosa-Beats inkl. Schnittraster (jeder 2./4. Beat, Verdoppeln, ms-Versatz); MLX Whisper mit Wortzeitstempeln; Zuordnung eigener Lyrics; Refrain-Erkennung.
- **KI-Regie:** Ollama lokal, OpenAI Responses API (Structured Outputs, Key im Schlüsselbund) oder ChatGPT Web per Prompt-Zwischenablage; automatische Korrekturschleifen; lokaler Basisplan ohne Modell.
- **Schnittkern:** Beat-IDs statt freier Zeiten, Quellgrenzen, Refrain-Vorlagen werden per Code exakt wiederholt, framegenaue Rundung ohne Drift.
- **Export:** xmeml v4 (`timeline.xml`), FCPXML 1.6, OpenTimelineIO – jeweils mit vollständiger Musikspur.
- Atomare Projektsicherung (`.syllabeat`), Autosave, „Zuletzt geöffnet“, Fortschrittsanzeige und Abbrechen für alle Hintergrundaufgaben.

Beat- und Gesangserkennung liefern Schätzwerte; alle Tabellen sind korrigierbar.

## Release bauen (GitHub Actions)

Der Workflow [`.github/workflows/release.yml`](.github/workflows/release.yml) baut auf einem Apple-Silicon-Runner die App, führt Tests und den Selbsttest der gebauten App aus, erstellt `SyllaBeat-<version>.dmg` (+ SHA-256) und veröffentlicht sie als GitHub Release.

- **Manuell:** *Actions → Release (macOS DMG) → Run workflow* (optional als Pre-release oder Entwurf).
- **Per Tag:** Version in `syllabeat/__init__.py` setzen, dann `git tag v0.1.0 && git push origin v0.1.0`.

Bei jedem Push laufen zusätzlich schnelle Tests unter Linux ([`tests.yml`](.github/workflows/tests.yml)).

## Lokal entwickeln

Benötigt macOS auf Apple Silicon mit Python 3.12:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.lock
.venv/bin/python scripts/fetch_binaries.py      # ffmpeg, ffprobe, Ollama (SHA-256-geprüft)
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python main.py                        # App aus dem Quellcode starten
.venv/bin/python scripts/build.py               # dist/SyllaBeat.app + dist/SyllaBeat-<version>.dmg
```

`requirements.lock` enthält die verwendeten Paketversionen; `assets/binaries.json` dokumentiert Binärquellen und Prüfsummen (`--latest` aktualisiert sie). Selbsttest der gebauten App:

```sh
VC_DATA_DIR="$PWD/.build/diagnostics" VC_TEST_METAL=1 dist/SyllaBeat.app/Contents/MacOS/SyllaBeat --self-test .build/diagnostics.json
```

Die echte Whisper-Prüfung ist über `VC_TEST_WHISPER=1` zuschaltbar (lädt das Tiny-Modell).

Struktur (`syllabeat/`): `gui.py` Oberfläche, `worker.py` isolierte Hintergrundprozesse, `analysis.py` Medien/Audio, `planning.py` Schnittregeln, `director.py` KI-Orchestrierung, `exporters.py` Timeline-Formate, `services.py` Ollama/OpenAI, `storage.py` Projekte/Schlüsselbund/Umbenennung.

Daten der Vorversion („Video Creator“) unter `~/Library/Application Support/` und im Schlüsselbund werden automatisch übernommen.
