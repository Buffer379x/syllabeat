# Video Creator

Eigenständige macOS-Desktop-App für Apple Silicon. GUI auf Deutsch, lokale Beat-/Gesangsanalyse, Ollama Vision, automatische oder manuelle KI-Regie und Timeline-Export.

## Starten

`dist/Video Creator.app` per Doppelklick öffnen oder die App aus dem DMG in den Programme-Ordner ziehen. Python, Homebrew und externe Bibliotheken sind für die Benutzung nicht erforderlich. KI-Modelle werden bei Bedarf in der App geladen.

Die ausführliche Anleitung liegt in `BEDIENUNG.html` und ist auch über **Hilfe → Bedienungsanleitung** erreichbar. Mindestversion: macOS 15, Apple Silicon.

## Enthalten

- OpenCV und ffprobe für Metadaten, Vorschaubilder und variable Frameraten.
- librosa für Beats; MLX Whisper für lokale Wortzeitstempel und Lyrics-Zuordnung.
- Ollama-Laufzeit mit in der GUI verwalteten Modellen; lokale Vision mit `qwen2.5vl:7b`.
- OpenAI Responses API mit Structured Outputs und optionalem Schlüsselbund-Key.
- Prompt-Zwischenablage und JSON-Import für ChatGPT Web.
- Strenger Schnittkern mit Beat-IDs, Quellgrenzen, Refrainvorlagen und rationalen Bildraten.
- xmeml v4, FCPXML 1.6 und OpenTimelineIO, jeweils mit vollständiger Musikspur.
- Atomare Projektsicherung, Umbenennungsvorschau, Kollisionsschutz und Undo.

Beat- und Gesangserkennung liefern Schätzwerte; Tabellen erlauben Korrekturen. Videogrenzen werden auf Timeline-Frames gerundet. XML-/OTIO-Dateien verknüpfen externe Medien. Für eine öffentliche Weitergabe kann das App-Bundle zusätzlich mit einer eigenen Apple Developer ID signiert und notarisiert werden; der lokale Build ist ad-hoc signiert.

## Quellcode und Entwicklung

Die folgenden Schritte sind ausschließlich für einen eigenen Neu-Build, nicht zum Starten der fertigen App erforderlich:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.lock
.venv/bin/python scripts/fetch_binaries.py
.venv/bin/python scripts/build.py
```

`requirements.lock` enthält die tatsächlich verwendeten Paketversionen; `assets/binaries.json` dokumentiert Binärquellen und SHA-256-Prüfsummen. `scripts/fetch_binaries.py` lädt standardmäßig genau diese Versionen und prüft die Prüfsummen; mit `--latest` werden die neuesten Releases geladen und in `binaries.json` eingetragen. Der Build benötigt macOS auf Apple Silicon mit Python 3.12 und Netzwerk zum Download der Build-Abhängigkeiten. Es werden ausschließlich vorgebaute Wheels verwendet.

```sh
.venv/bin/python -m unittest discover -s tests -v
VC_DATA_DIR="$PWD/.build/diagnostics" VC_TEST_METAL=1 .venv/bin/python main.py --self-test .build/diagnostics.json
```

Lokale HTTP-/Metal-Tests benötigen die normalen Netzwerk- und GPU-Rechte eines macOS-Prozesses. Die Tests benötigen keine bezahlten API-Aufrufe. Die gezielte echte Whisper-Prüfung ist über `VC_TEST_WHISPER=1` zuschaltbar; dabei wird das Tiny-Modell automatisch geladen.

Struktur: `gui.py` Oberfläche, `worker.py` isolierte Aufgaben, `analysis.py` Medien/Audio, `planning.py` Regeln, `director.py` KI-Orchestrierung, `exporters.py` Timeline-Formate, `services.py` API-/Ollama-Verwaltung, `storage.py` Projekte/Schlüsselbund/Umbenennung.
