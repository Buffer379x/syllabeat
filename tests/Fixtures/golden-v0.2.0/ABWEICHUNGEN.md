# Bewusste Abweichungen der 0.3.0-Exporte von diesen Golden-Dateien

| Datei | Abweichung | Grund |
|---|---|---|
| `timeline.edl` | Quell-Out = Quell-In + Dauer **in Quellframes**; Timecodes werden in der Timeline-Rate geschrieben | Fehler F1 in 0.2.0 (`exporters.py:312`): Quell-In + Timeline-Frames ergab bei abweichender Quellrate falsche Längen. Beleg: `g1-basis-25p`, Ereignis 003 (`stadt_nacht.mp4`, 50p): Quelle 0,5 s statt 1 s, Event 005 enthält den in 25p ungültigen Framewert `:38`. |
| `timeline.edl`, `timeline.xml`, `timeline.fcpxml` | Quell-Timecode = Start-Timecode der Datei statt immer 00:00:00:00 | Fehler F2. Die Fixtures enthalten keinen Start-Timecode, die Ausgabe bleibt für sie gleich. |

Alle übrigen Werte, vor allem `compiled.json` (Frame-Tabelle), müssen exakt übereinstimmen.

Prüfung der FCPXML-Dateien gegen die DTD aus Final Cut Pro 12.4 (`FCPXMLv1_8.dtd`; vorher an einen Pfad ohne Leerzeichen kopieren, sonst scheitert `xmllint` an der Entity-Auflösung): alle vier gültig (28.10.2026).
