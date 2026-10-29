# SyllaBeat

Native macOS-App für Apple Silicon, die aus einem Song und einem Ordner voller Videoclips einen Musikvideo-Rohschnitt baut: Schnitte frame-genau auf Beats, Takten und gesungenen Silben, Bilder passend zu Text und Stimmung, Export nach Final Cut Pro, DaVinci Resolve und Premiere. Oberfläche auf Deutsch, alle Analysen lokal.

**Version 0.3.0** · macOS 15+ · Apple Silicon · Swift/SwiftUI

## Installation

1. Unter [Releases](https://github.com/Buffer379x/syllabeat/releases) die Datei `SyllaBeat-<version>.dmg` laden (rund 10 MB).
2. DMG öffnen und **SyllaBeat** in den Programme-Ordner ziehen.
3. Die App ist ad-hoc signiert, nicht notarisiert. Beim ersten Start meldet macOS, dass sie nicht geprüft werden kann: dann unter *Systemeinstellungen → Datenschutz & Sicherheit* „Dennoch öffnen“ wählen.

Modelle (Gesangserkennung, Bildsuche, Bildbeschreibung) lädt die App bei Bedarf selbst; mit Apple Intelligence ist für Regie und Beschreibungen kein Download nötig. Die Anleitung liegt in [`BEDIENUNG.html`](BEDIENUNG.html) und in der App unter **Hilfe → SyllaBeat-Hilfe**.

## Funktionen

- **Ein Projektfenster:** Bibliothek, Vorschau, Inspektor und Timeline mit Abschnitten, Text bis zur Silbe, Wellenform mit Beats und Takten und Bildspur. Undo/Redo für alles, Autosave, Versionen.
- **Autopilot:** Song und Clips hineinziehen, der erste Schnitt entsteht ohne weiteren Klick (60 Clips und ein 4-Minuten-Song in etwa 25 s).
- **Medien:** AVFoundation mit exakten Bildraten, Rotation, Kamera-Timecode und VFR-Prüfung; Szenenerkennung, Apple-Vision-Merkmale, Bildsuche per SigLIP 2 (auch auf Deutsch); Arbeitskopien über eine nachladbare ffmpeg-Komponente.
- **Song:** Beat- und Taktanalyse, Abschnitte aus Audio-Struktur oder Songtext, Gesangserkennung mit WhisperKit und Wortzeit-Korrektur, Ausrichtung des eigenen Songtexts; Raster-Werkzeuge mit Undo.
- **Schnitt-Engine:** Stil-Presets und Regler, Refrain-Modi, Fixieren, Neu würfeln, Teilneuberechnung, drei Varianten, „Warum dieser Clip?“ mit Alternativen. Invarianten per Property-Test über 10.000 Projekte.
- **Vorschau:** synchroner Player aus derselben Frame-Tabelle wie die Exporte, Textzeile als Overlay, Füllen/Einpassen.
- **KI (optional):** Apple Intelligence, lokale MLX-Modelle (Qwen3-VL), Ollama, OpenAI-kompatible Server, Anthropic oder von Hand. Storyboard aus Regieanweisung und Songtext; Bildbeschreibungen als fortsetzbare Hintergrundaufgabe. Vor jedem ersten Senden an einen Cloud-Anbieter zeigt die App, was übertragen wird; Videos verlassen den Mac nie.
- **Export:** FCPXML 1.8 mit Markern und Schlagwörtern, FCP-7-XML, CMX-3600-EDL (mit korrekten Quellzeiten bei abweichender Bildrate und Kamera-Timecode), OpenTimelineIO, Schnittliste und Clip-Katalog, SRT/LRC.

## Entwickeln

Voraussetzungen: macOS auf Apple Silicon, Xcode 27 mit Metal-Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```sh
open SyllaBeat.xcodeproj                 # App, Inferenzdienst und UI-Tests
scripts/check.sh                         # Formatierung, Paket-Tests, Selbsttest, App-Build und UI-Tests
scripts/build-release.sh                 # Release-Archiv, Ad-hoc-Signatur, Selbsttest, dist/SyllaBeat-<version>.dmg
swift run --package-path Packages/SyllaBeatKit sbtool   # Kommandozeile: Selbsttest, Import, Analyse, Schnitt, Export, Messungen
```

Aufbau:

| Ort | Inhalt |
|---|---|
| `App/` | SwiftUI-App: Dokumentfenster, Controller für Medien, Song, Schnitt und KI, Einstellungen, Export-Dialog |
| `InferenceService/` | XPC-Dienst für Modelle (SigLIP 2, WhisperKit, MLX); beendet sich nach Leerlauf |
| `Packages/SyllaBeatKit/` | `SyllaBeatCore` (Modell, Schnitt-Engine, Exporte), `Media`, `Audio`, `UI` (Timeline), `AI` (Anbieter, Regie), `Models`, `MLX`, `sbtool` |
| `UITests/` | UI-Tests der App |
| `tests/Fixtures/` | Golden-Exporte aus 0.2.0, Testclips |
| `Config/` | `Version.xcconfig` (einzige Versionsquelle), Build-Einstellungen |

Die Python-Version 0.2.0 bleibt über den Tag `v0.2.0` erreichbar.

## Release

Ein Tag `v<Version>` startet den Workflow [„Release (macOS DMG)“](.github/workflows/release.yml): Version gegen `Config/Version.xcconfig` prüfen, `scripts/check.sh`, Release-Archiv, Ad-hoc-Signatur, Selbsttest der gebauten App, `SyllaBeat-<Version>.dmg` mit SHA-256 und GitHub Release mit den Notizen aus `CHANGELOG.md`.
