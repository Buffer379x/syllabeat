"""Erzeugt Golden-Fixtures mit dem Python-Code von SyllaBeat 0.2.0.

Die Swift-Neuimplementierung (0.3.0) vergleicht ihre Kompilierung und Exporte
mit diesen Dateien. Aufruf (der Pfad zeigt auf einen Checkout des Tags v0.2.0):

    python tools/make_goldens.py /pfad/zu/v0.2.0 tests/Fixtures/golden-v0.2.0

Benötigt nur die Standardbibliothek, für timeline.otio zusätzlich opentimelineio.
"""
from __future__ import annotations

import json
import random
import sys
from pathlib import Path


def clip(identity, name, duration, rate, size, frames=None, segments=None, description="", tags=()):
    num, den = rate
    return {
        "id": identity, "path": f"/Volumes/Material/Clips/{name}", "name": name,
        "duration": duration, "fps_num": num, "fps_den": den, "fps": num / den,
        "width": size[0], "height": size[1],
        "frame_count": frames if frames is not None else int(duration * num / den),
        "segments": segments or [{"start": 0.0, "end": duration}],
        "description": description, "tags": list(tags),
    }


def song(duration, beats, sections=(), lines=()):
    return {"duration": duration, "beats": beats, "sample_rate": 48000, "channels": 2,
            "lines": list(lines), "sections": list(sections), "words": [], "warnings": []}


def section(identity, label, start, end, repeat_of=None):
    return {"id": identity, "label": label, "start": start, "end": end, "repeat_of": repeat_of}


def project(name, rate, size, clips, audio, style=None):
    from syllabeat.storage import default_cut_style
    return {
        "version": 1, "name": name, "video_dir": "/Volumes/Material/Clips",
        "audio_path": "/Volumes/Material/Song/Sommer Lied (Master).wav", "lyrics": "",
        "timeline": {"fps_num": rate[0], "fps_den": rate[1], "width": size[0], "height": size[1]},
        "clips": clips, "audio": audio, "plan": None,
        "cut_style": {**default_cut_style(), **(style or {})},
    }


def fixtures():
    # G1: 25p, 120 BPM mit Versatz, Clips mit 25p/50p/29,97p (EDL-Fehler F1), Refrain-Wiederholung.
    beats = [round(0.23 + 0.5 * i, 6) for i in range(24)]
    g1 = project("Basis 25p", (25, 1), (1920, 1080), [
        clip("clip-a", "strand_01.mov", 10.0, (25, 1), (1920, 1080), segments=[{"start": 0.0, "end": 4.0}, {"start": 4.0, "end": 10.0}],
             description="Wellen am Strand", tags=["Strand", "Meer"]),
        clip("clip-b", "stadt_nacht.mp4", 8.0, (50, 1), (3840, 2160), description="Stadt bei Nacht"),
        clip("clip-c", "wald.mov", 6.006, (30000, 1001), (1920, 1080), frames=180, description="Wald im Nebel"),
    ], song(12.4, beats, [
        section("s1", "Strophe", 0.0, 2.73), section("s2", "Refrain", 2.73, 5.73),
        section("s3", "Strophe", 5.73, 8.73), section("s4", "Refrain", 8.73, 11.73, "s2"),
        section("s5", "Outro", 11.73, 12.4),
    ]), {"variation": "gleichmaessig", "verse_beats": 4, "chorus_beats": 2})

    # G2: 23,976p, unruhiges Tempo, Sonderzeichen in Pfaden, 59,94p-Quelle.
    rng = random.Random(3)
    t, beats = 0.31, []
    while t < 19.5:
        beats.append(round(t, 6))
        t += 0.4175 + rng.uniform(-0.012, 0.012)
    g2 = project("NTSC 23,976 – Umlaute", (24000, 1001), (1920, 1080), [
        clip("ü1", "Über Brücke 01.mov", 14.0, (24000, 1001), (1920, 1080), frames=335),
        clip("p2", "50% Regen #2.mp4", 9.5, (60000, 1001), (1920, 1080), frames=569),
        clip("k3", "Küste & Möwen.mov", 20.0, (25, 1), (2048, 858)),
    ], song(20.0, beats), {"variation": "abwechslungsreich", "seed": 11})

    # G3: 59,94p Hochformat, drei Refrains (Kette), wilde Variation.
    beats = [round(0.5 * i + 0.12, 6) for i in range(1, 120)]
    g3 = project("Hochformat 59,94", (60000, 1001), (1080, 1920), [
        clip(f"v{i}", f"hoch_{i:02d}.mov", 6.0 + i, (30, 1), (1080, 1920),
             segments=[{"start": 0.0, "end": 3.0 + i / 2}, {"start": 3.0 + i / 2, "end": 6.0 + i}])
        for i in range(1, 9)
    ], song(60.0, beats, [
        section("a", "Intro", 0.0, 8.12), section("b", "Refrain", 8.12, 16.12),
        section("c", "Strophe", 16.12, 28.12), section("d", "Refrain", 28.12, 36.12, "b"),
        section("e", "Bridge", 36.12, 44.12), section("f", "Refrain", 44.12, 52.12, "d"),
        section("g", "Outro", 52.12, 60.0),
    ]), {"variation": "wild", "seed": 7})

    # G4: handgeschriebener Plan, Quellstarts ungleich 0, Refrain über Shotgrenzen.
    beats = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0]
    g4 = project("Manueller Plan", (30, 1), (1280, 720), [
        clip("m1", "eins.mov", 30.0, (30, 1), (1280, 720)),
        clip("m2", "zwei.mov", 30.0, (24, 1), (1280, 720)),
    ], song(10.0, beats, [section("x", "Refrain", 1.0, 4.0), section("y", "Refrain", 5.0, 8.0, "x")]))
    plan4 = {"version": 1, "shots": [
        {"clip_id": "m1", "start_beat": 0, "end_beat": 2, "source_in": 1.25},
        {"clip_id": "m2", "start_beat": 2, "end_beat": 4, "source_in": 3.5},
        {"clip_id": "m1", "start_beat": 4, "end_beat": 5, "source_in": 12.0},
        {"clip_id": "m2", "start_beat": 5, "end_beat": 8, "source_in": 0.0},
        {"clip_id": "m1", "start_beat": 8, "end_beat": 10, "source_in": 20.0},
    ]}
    return [("g1-basis-25p", g1, None), ("g2-ntsc-umlaute", g2, None),
            ("g3-hochformat-5994", g3, None), ("g4-manueller-plan", g4, plan4)]


def compiled_table(timeline):
    keys = ("clip_id", "start_beat", "end_beat", "source_in", "start", "end", "duration_frames",
            "source_in_frame", "source_out_frame", "source_fps_num", "source_fps_den")
    return {
        "fps_num": timeline["fps_num"], "fps_den": timeline["fps_den"],
        "width": timeline["width"], "height": timeline["height"],
        "duration_frames": timeline["duration_frames"], "boundaries": timeline["boundaries"],
        "boundaries_frames": timeline["boundaries_frames"],
        "shots": [{key: shot[key] for key in keys} for shot in timeline["shots"]],
    }


def main(source: Path, destination: Path) -> None:
    sys.path.insert(0, str(source))
    from syllabeat import __version__
    from syllabeat.exporters import export_edl, export_fcpxml, export_otio, export_xmeml
    from syllabeat.planning import apply_repeats, compile_timeline, draft_plan
    for name, data, plan in fixtures():
        folder = destination / name
        folder.mkdir(parents=True, exist_ok=True)
        plan = apply_repeats(data, plan) if plan else draft_plan(data)
        data["plan"] = plan
        dump = lambda value, file: (folder / file).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        dump(data, "project.v1.json")  # *.syllabeat ist per .gitignore ausgeschlossen
        dump(compiled_table(compile_timeline(data, plan)), "compiled.json")
        export_fcpxml(data, plan, folder / "timeline.fcpxml")
        export_xmeml(data, plan, folder / "timeline.xml")
        export_edl(data, plan, folder / "timeline.edl")
        try:
            export_otio(data, plan, folder / "timeline.otio")
        except Exception as error:  # opentimelineio fehlt
            print(f"{name}: OTIO übersprungen ({error})")
        print(f"{name}: {len(plan['shots'])} Einstellungen")
    (destination / "README.md").write_text(
        f"# Golden-Fixtures aus SyllaBeat {__version__}\n\n"
        "Erzeugt mit `tools/make_goldens.py`; `project.v1.json` ist das jeweilige 0.2.0-Projekt (Format v1). Die Swift-Implementierung muss `compiled.json` exakt\n"
        "und die Exporte semantisch reproduzieren. Bewusste Abweichungen (Fehlerkorrekturen) sind\n"
        "in `ABWEICHUNGEN.md` dokumentiert.\n", encoding="utf-8")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
