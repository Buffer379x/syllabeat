# Changelog

## 0.4.0 – 2026-10-30

Geschichten erzählen: Aus Clips einer Geschichte entsteht ein Schnitt, der ihrer Reihenfolge und dem Songtext folgt, ohne Tag-Nacht-Sprünge und ohne KI-Fehler im Bild – und das fertige Video für YouTube.

### Neu
- **Kapitel und Drehbuch:** Clips in Kapitel einteilen (Mehrfachauswahl, „Alle Takes auswählen“), im Drehbuch (⇧⌘D) je Songabschnitt Haupt- und Beimischungskapitel festlegen. Die Geschichte läuft innerhalb eines Abschnitts nur vorwärts, Refrains sind Montage. „Vorschlagen“ ordnet Kapitel ohne KI aus Songtext und Bildähnlichkeit zu. Spur „Kapitel“ in der Timeline, Bibliothek nach Kapitel gruppiert, Kapitel-Vorschläge für neue Clips.
- **Kontinuität:** Die Tageszeit läuft vorwärts (Tag → Abend → Nacht), außer ein Abschnitt ist festgelegt; erkannt aus Nutzerangaben, Dateinamen, Kapitel-Vorgaben und Bildbeschreibungen (die Beschreibung liefert jetzt die Tageszeit mit).
- **Sperrbereiche für KI-Fehler:** Clip-Ansicht zum Sichten (Doppelklick, `I`/`O`/`X`, `↑`/`↓`), `X` in der Bildspur sperrt den gezeigten Ausschnitt und schneidet neu. Gesperrtes kommt nie in Schnitt, Vorschau oder Export.
- **Motive aus Dateinamen:** Takes, Generator, Wasserzeichen und Figurennamen werden erkannt. Takes desselben Motivs folgen nicht direkt aufeinander, Wasserzeichen werden gemieden, passende Motive über eine Zeile gehalten, keine „A · B · A“-Sandwiches. Neuer Refrain-Modus „Gleiche Motive, andere Takes“.
- **Text ↔ Bild:** nur klare Treffer zählen, Pronomen erben das Motiv der Vorzeile, Figurennamen aus Dateinamen.
- **Ungereimtheiten:** Status-Chip mit Liste, Sprung zur Stelle, Abhilfe und Markern in der Bildspur.
- **Was fehlt?:** Zeilen ohne klares Bild, knappe Kapitel und Motive nur mit Wasserzeichen – mit Dateinamen und Prompt für den KI-Generator.
- **Video für YouTube:** Export-Ziel „Video (YouTube)“ rendert MP4 (H.264/HEVC) aus derselben Frame-Tabelle wie Vorschau und Exporte, dazu YouTube-Kapitel, SRT und Vorschaubild.
- **Timeline-Format** (Größe, Bildrate, Bildanpassung) im Inspektor wählbar, mit Vorschlag aus dem Material.
- **Clip-Wissen projektübergreifend:** Sperrbereiche, Bewertung, „Nie verwenden“ und eigene Tageszeiten gelten je Datei auch in anderen Projekten (abschaltbar).
- `sbtool`: `geschichte`, `drehbuch`, `drehliste`, `render`.

### Behoben
- **Songtext:** Kollabierte Wortzeiten von Whisper (ganze Strophen auf eine Sekunde gelegt) werden erkannt und neu verteilt und markiert; Klammerzeilen wie „(End)“ gelten nicht als Gesang.

### Geändert
- **Projektformat v3:** 0.4 öffnet Projekte aus 0.3; 0.3.0 lehnt Projekte aus 0.4 ab, statt beim Sichern Kapitel und Sperrbereiche zu verlieren.

## 0.3.0 – 2026-10-29

Neu geschrieben als native macOS-App in Swift und SwiftUI. Das DMG ist rund 10 MB groß statt 1,2 GB, Projekte aus 0.2 öffnen sich direkt.

### Neu
- **Ein Projektfenster** mit Bibliothek, Vorschau, Inspektor und Timeline (Abschnitte, Text bis zur Silbe, Wellenform mit Beats und Takten, Bildspur). Undo/Redo für alles, Autosave und Versionen.
- **Autopilot:** Song und Clips hineinziehen, der erste Schnitt entsteht ohne weiteren Klick. Willkommen beim ersten Start mit dem passenden Modellpaket für diesen Mac.
- **Vorschau-Player:** der Schnitt synchron zum Song, aus derselben Frame-Tabelle wie die Exporte, mit Textzeile; Füllen oder Einpassen.
- **Schnitt-Engine:** Stil-Presets und Regler, Refrain-Modi (identisch, gleiche Clips, frei), Fixieren, Neu würfeln, Auswahl neu schneiden, drei Varianten, „Warum dieser Clip?“ mit acht Alternativen. Abschnittsgrenzen sind Pflichtschnitte.
- **Bildspur bedienen:** Kanten ziehen (rastet an Beats, Wörtern oder Frames), `B` schneidet, `⌫` verschmilzt, Clips aus der Bibliothek auf eine Einstellung ziehen, `J`/`K`/`L`, `←`/`→`, `⌥←`/`⌥→`.
- **Song:** eigene Beat- und Taktanalyse, Abschnitte aus Audio und Songtext, Gesangserkennung mit WhisperKit und Korrektur der Wortzeiten auf Gesangseinsätze, Ausrichtung des eigenen Songtexts mit Silben. Rasterkorrekturen mit Undo; der Schnitt wandert mit und wird bei Bedarf repariert.
- **Bildsuche** mit SigLIP 2 (auch deutsche Anfragen) und **Szenen** je Clip mit Apple-Vision-Merkmalen.
- **KI-Regie als Storyboard** aus Regieanweisung und Songtext: Stimmung, Bildidee, Suchbegriffe und Schnitttempo je Abschnitt. Anbieter: Apple Intelligence, lokale MLX-Modelle (Qwen3-VL), Ollama, OpenAI-kompatible Server, Anthropic oder von Hand.
- **Bildbeschreibungen** als fortsetzbare Hintergrundaufgabe; danach „Schnitt verbessern?“.
- **Datenschutz:** Zustimmung vor dem ersten Senden an einen Cloud-Anbieter mit Angabe, was übertragen wird; Widerruf in den Einstellungen; Schlüssel im Schlüsselbund. Videos verlassen den Mac nie.
- **Modellverwaltung** mit Empfehlung nach Arbeitsspeicher, Warnung vor zu großen Modellen, fortsetzbaren und geprüften Downloads, wählbarem Speicherort und Hinweis auf nicht mehr benötigte Modelle aus 0.2.
- **Export-Dialog nach Zielprogramm** (Final Cut Pro, DaVinci Resolve, Premiere, Archiv) mit Markern für Abschnitte, Textzeilen und Takte, Schlagwörtern und Notizen; „In Final Cut Pro öffnen“; Untertitel (SRT) und Songtext mit Zeiten (LRC).
- Hilfe in der App (`⌘?`), Selbsttest `--self-test`, Kommandozeile `sbtool`.

### Behoben
- **EDL:** Bei Clips mit anderer Bildrate als die Timeline (z. B. 50p in 25p) stimmte die Quelllänge nicht (F1). Die Quell-Timecodes nutzen jetzt den Kamera-Timecode der Datei statt immer 00:00:00:00 (F2).
- **DaVinci Resolve:** Aus der FCP-7-XML übernimmt Resolve den Song nicht; das Zielprogramm „DaVinci Resolve“ exportiert deshalb FCPXML mit Song, dazu EDL und Marker-EDL.
- Hinweis zum ersten Start korrigiert: Seit macOS 15 öffnet man nicht notarisierte Apps über *Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen*.

### Entfernt
- Python-Laufzeit, Ollama und die mitgelieferten Hilfsprogramme. Die Version 0.2.0 bleibt über den Tag `v0.2.0` erreichbar.

## 0.2.0 – 2026-10-19

### Behoben
- **Final Cut Pro:** Der Import von `timeline.fcpxml` scheiterte mit „Ein unerwarteter Wert wurde festgestellt (format=\"timeline-format\")“. Die Datei folgt jetzt dem Aufbau, den Final Cut Pro selbst schreibt (FCPXML 1.8, Standardnamen für Formate, einfache IDs, keine überflüssigen Attribute).
- **Icon:** Das Programm-Icon wechselte direkt nach dem Start, weil die App ein zweites, gezeichnetes Icon setzte. Es gilt nur noch das Icon des App-Pakets.

### Neu
- **DaVinci Resolve:** Export als FCP-7-XML (`timeline.xml`) und als CMX-3600-EDL (`timeline.edl`, nur Video) zusätzlich zu FCPXML. Der Export zeigt, welches Format für welches Programm gedacht ist.
- **Szenenerkennung:** Beim Einlesen wird jeder Clip in Szenen zerlegt (Schnitte per Farbhistogramm, lange Einstellungen in Teile ≤ 5 s). Die Vision-Analyse beschreibt jede Szene; die Szenen stehen im Katalog und im Prompt.
- **Schnittstil** (Seite „KI-Regie“): Variation der Cliplängen (gleichmäßig / abwechslungsreich / wild), Beats pro Schnitt für Strophe und Refrain, „Refrain schneller schneiden“, „Neu würfeln“.
- Der Basisplan nutzt Ausschnitte aus allen Szenen eines Clips statt immer ab Sekunde 0; Wiederholungen eines Refrains bleiben exakte Kopien. Die KI-Prompts enthalten Szenen und Schnittstil.
- **Modell-Ordner:** Speicherort für Whisper- und Ollama-Modelle ist einstellbar (Modelle & Einstellungen) und wird im Download-Dialog angezeigt. Whisper-Modelle liegen jetzt im selben Ordner (`…/models/huggingface`) statt im Standard-Cache von Hugging Face und werden dadurch einmal neu geladen.

### Geändert
- Überarbeitete Oberfläche: Logo in der Seitenleiste, Karten für Gruppen, ruhigere Bedienelemente.
- Projektdateien erhalten den Abschnitt `cut_style`; ältere Projekte werden unverändert geöffnet. Clips ohne Szenen werden beim nächsten „Ordner neu einlesen“ ergänzt.

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
