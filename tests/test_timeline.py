"""Core contract tests; synthetic projects require no media or model downloads."""

from __future__ import annotations

import copy
import importlib.util
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from syllabeat.exporters import export_fcpxml, export_otio, export_xmeml, media_url
from syllabeat.planning import (
    PlanError, apply_repeats, beat_boundaries, build_prompt, compile_timeline,
    draft_plan, parse_plan, plan_schema, validate_plan,
)


def project() -> dict:
    return {
        "version": 1, "name": "Licht & Nächte", "audio_path": "/tmp/Meine Musik/Song #1.wav", "lyrics": "Sonne am Meer",
        "timeline": {"fps_num": 25, "fps_den": 1, "width": 1920, "height": 1080},
        "audio": {"duration": 8.0, "sample_rate": 48000, "channels": 2,
                  "beats": [float(i) for i in range(1, 8)],
                  "lines": [{"id": "line1", "start": 0.0, "end": 4.0, "text": "Die Sonne scheint am Meer"}], "sections": []},
        "clips": [
            {"id": "sun", "path": "/tmp/Clips/Sonne & Meer ü #1.mov", "name": "Sonne & Meer ü #1.mov", "duration": 6.0,
             "fps_num": 25, "fps_den": 1, "width": 1920, "height": 1080, "frame_count": 150,
             "description": "Sonne scheint auf das Meer", "tags": ["Sonne", "Meer"]},
            {"id": "city", "path": "/tmp/Clips/Stadt.mov", "name": "Stadt.mov", "duration": 6.0,
             "fps_num": 30000, "fps_den": 1001, "width": 3840, "height": 2160, "frame_count": 179,
             "description": "Menschen in einer dunklen Stadt", "tags": ["Stadt"]},
        ], "plan": None,
    }


def simple_plan() -> dict:
    return {"version": 1, "shots": [
        {"clip_id": "sun", "start_beat": 0, "end_beat": 4, "source_in": 0.0},
        {"clip_id": "city", "start_beat": 4, "end_beat": 8, "source_in": 1.0},
    ]}


class PlanningTests(unittest.TestCase):
    def test_boundary_ids_include_song_edges_deduplicate_and_sort(self):
        p = project()
        p["audio"]["beats"] = [4, 0, -1, 8, 9, 1, 1.0000001, 2, float("nan"), True]
        self.assertEqual(beat_boundaries(p), [0.0, 1.0, 2.0, 4.0, 8.0])

    def test_parse_fence_preserves_unicode_and_rejects_duplicate_keys(self):
        self.assertEqual(parse_plan("```json\n" + json.dumps(simple_plan()) + "\n```"), simple_plan())
        with self.assertRaisesRegex(PlanError, "mehrfach"):
            parse_plan('{"version":1,"version":2,"shots":[]}')
        with self.assertRaisesRegex(PlanError, "ungültigen Zahlenwert"):
            parse_plan('{"source_in":NaN}')

    def test_parse_shows_json_location(self):
        with self.assertRaisesRegex(PlanError, "Zeile 2"):
            parse_plan('{\n"shots": [}')

    def test_prompt_and_schema_have_stable_ids_and_vision_descriptions(self):
        p = project()
        prompt = build_prompt(p)
        self.assertIn("Sonne scheint auf das Meer", prompt)
        self.assertIn('"beat_id": 8', prompt)
        self.assertIn('"song_duration": 8.0', prompt)
        self.assertIn('"first_beat_id": 0', prompt)
        self.assertIn('"last_beat_id": 8', prompt)
        self.assertIn("erste Beat-ID 0; letzte Beat-ID 8", prompt)
        self.assertIn("shots[-1].end_beat=8", prompt)
        schema = plan_schema(p)
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(schema["properties"]["shots"]["items"]["properties"]["clip_id"]["enum"], ["sun", "city"])

    def test_valid_plan_uses_source_rate_and_timeline_rate_separately(self):
        p = project()
        self.assertEqual(validate_plan(p, simple_plan()), [])
        timeline = compile_timeline(p, simple_plan())
        self.assertEqual(timeline["duration_frames"], 200)
        self.assertEqual([s["duration_frames"] for s in timeline["shots"]], [100, 100])
        self.assertEqual(timeline["shots"][1]["source_in_frame"], 30)
        self.assertEqual(timeline["shots"][1]["source_out_frame"], 150)
        self.assertEqual(timeline["shots"][1]["source_fps_den"], 1001)

    def test_no_cumulative_rounding_drift_at_ntsc(self):
        p = project()
        p["timeline"]["fps_num"], p["timeline"]["fps_den"] = 30000, 1001
        p["audio"]["duration"] = 100.0
        p["audio"]["beats"] = [i / 3 for i in range(1, 300)]
        plan = {"version": 1, "shots": [{"clip_id": "sun", "start_beat": i, "end_beat": i + 1, "source_in": 0.0} for i in range(300)]}
        timeline = compile_timeline(p, plan)
        self.assertEqual(timeline["duration_frames"], 2997)
        self.assertEqual(sum(s["duration_frames"] for s in timeline["shots"]), 2997)
        for left, right in zip(timeline["shots"], timeline["shots"][1:]):
            self.assertEqual(left["end"], right["start"])

    def test_rounding_can_make_an_ideal_duration_too_long(self):
        p = project()
        p["audio"]["duration"], p["audio"]["beats"] = 1.019, []
        p["clips"][0]["duration"], p["clips"][0]["frame_count"] = 0.999, 0
        plan = {"version": 1, "shots": [{"clip_id": "sun", "start_beat": 0, "end_beat": 1, "source_in": 0.0}]}
        self.assertIn("zu kurz", " ".join(validate_plan(p, plan)))

    def test_gap_overlap_unknown_clip_and_source_overrun_are_rejected(self):
        for mutation, message in [
            (lambda q: q["shots"][1].update(start_beat=5), "Lücke"),
            (lambda q: q["shots"][1].update(start_beat=3), "Überlappung"),
            (lambda q: q["shots"][0].update(clip_id="missing"), "unbekannte clip_id"),
            (lambda q: q["shots"][0].update(source_in=3.0), "zu kurz"),
            (lambda q: q["shots"][0].update(start_beat=True), "ungültige Beat-IDs"),
            (lambda q: q["shots"][0].update(source_in=float("inf")), "endliche"),
        ]:
            with self.subTest(message=message):
                plan = simple_plan()
                mutation(plan)
                errors = validate_plan(project(), plan)
                self.assertIn(message, " ".join(errors))
                with self.assertRaises(PlanError):
                    compile_timeline(project(), plan)

    def test_subframe_cut_is_reported_instead_of_creating_zero_length_clip(self):
        p = project()
        p["audio"]["beats"] = [0.001]
        plan = {"version": 1, "shots": [
            {"clip_id": "sun", "start_beat": 0, "end_beat": 1, "source_in": 0.0},
            {"clip_id": "city", "start_beat": 1, "end_beat": 2, "source_in": 0.0},
        ]}
        self.assertIn("kürzer als ein Frame", " ".join(validate_plan(p, plan)))

    def test_repeated_chorus_is_copied_by_code_without_mutating_input(self):
        p = project()
        p["audio"]["sections"] = [
            {"id": "chorus-1", "start": 0, "end": 4, "repeat_of": None},
            {"id": "chorus-2", "start": 4, "end": 8, "repeat_of": "chorus-1"},
        ]
        plan = {"version": 1, "shots": [
            {"clip_id": "sun", "start_beat": 0, "end_beat": 2, "source_in": 0.5},
            {"clip_id": "city", "start_beat": 2, "end_beat": 4, "source_in": 1.0},
            {"clip_id": "sun", "start_beat": 4, "end_beat": 8, "source_in": 0.0},
        ]}
        original = copy.deepcopy(plan)
        self.assertIn("weichen", " ".join(validate_plan(p, plan)))
        repeated = apply_repeats(p, plan)
        self.assertEqual(plan, original)
        self.assertEqual([s["clip_id"] for s in repeated["shots"]], ["sun", "city", "sun", "city"])
        self.assertEqual([s["source_in"] for s in repeated["shots"]], [0.5, 1.0, 0.5, 1.0])
        self.assertEqual(validate_plan(p, repeated), [])

    def test_refrain_crossing_a_shot_boundary_preserves_source_position(self):
        p = project()
        p["audio"]["sections"] = [
            {"id": "a", "start": 1, "end": 3},
            {"id": "b", "start": 5, "end": 7, "repeat_of": "a"},
        ]
        repeated = apply_repeats(p, simple_plan())
        chorus = next(s for s in repeated["shots"] if s["start_beat"] == 5)
        self.assertEqual(chorus["clip_id"], "sun")
        self.assertEqual(chorus["source_in"], 1.0)
        self.assertEqual(validate_plan(p, repeated), [])

    def test_incompatible_chorus_lengths_and_cycles_are_explicit(self):
        p = project()
        p["audio"]["sections"] = [{"id": "a", "start": 0, "end": 3}, {"id": "b", "start": 4, "end": 8, "repeat_of": "a"}]
        with self.assertRaisesRegex(PlanError, "unvereinbar"):
            apply_repeats(p, simple_plan())
        p["audio"]["sections"] = [{"id": "a", "start": 0, "end": 4, "repeat_of": "b"}, {"id": "b", "start": 4, "end": 8, "repeat_of": "a"}]
        with self.assertRaisesRegex(PlanError, "zyklische"):
            apply_repeats(p, simple_plan())

    def test_refrain_cannot_extend_source_outside_media(self):
        p = project()
        p["audio"]["duration"] = 8.5
        p["audio"]["beats"] = [1, 2, 3, 4, 5.125, 6.25, 7.375]
        p["clips"][0]["duration"], p["clips"][0]["frame_count"] = 4.0, 100
        p["audio"]["sections"] = [{"id": "a", "start": 0, "end": 4}, {"id": "b", "start": 4, "end": 8.5, "repeat_of": "a"}]
        with self.assertRaisesRegex(PlanError, "Refrainfolge"):
            apply_repeats(p, simple_plan())

    def test_offline_draft_uses_themed_clip_and_respects_short_sources(self):
        p = project()
        p["clips"][0]["duration"], p["clips"][0]["frame_count"] = 2.0, 50
        style = {"variation": "gleichmaessig", "verse_beats": 8}
        plan = draft_plan(p, style)
        self.assertEqual(plan["shots"][0]["clip_id"], "sun")
        self.assertEqual(plan["shots"][0]["end_beat"], 2)
        self.assertEqual(validate_plan(p, plan), [])
        self.assertEqual(plan, draft_plan(p, style))

    def test_impossible_single_beat_interval_never_loops_or_freezes(self):
        p = project()
        p["audio"]["beats"] = []
        with self.assertRaisesRegex(PlanError, "Kein Clip reicht"):
            draft_plan(p)

    def test_draft_reserves_source_duration_for_slower_chorus_repetition(self):
        p = project()
        p["audio"]["duration"] = 8.5
        p["audio"]["beats"] = [1, 2, 3, 4, 5.125, 6.25, 7.375]
        p["clips"][0]["duration"], p["clips"][0]["frame_count"] = 4.0, 100
        p["audio"]["sections"] = [{"id": "a", "start": 0, "end": 4}, {"id": "b", "start": 4, "end": 8.5, "repeat_of": "a"}]
        plan = draft_plan(p)
        self.assertEqual(validate_plan(p, plan), [])
        source = [s["clip_id"] for s in plan["shots"] if s["end_beat"] <= 4]
        repeat = [s["clip_id"] for s in plan["shots"] if s["start_beat"] >= 4]
        self.assertEqual(source, repeat)
        self.assertTrue(all(s["end_beat"] <= 4 or s["start_beat"] >= 4 for s in plan["shots"]))

    def test_draft_repeats_a_reference_chain_with_identical_source_starts(self):
        p = project()
        p["audio"]["duration"] = 12
        p["audio"]["beats"] = list(range(1, 12))
        p["audio"]["sections"] = [
            {"id": "a", "start": 0, "end": 4},
            {"id": "b", "start": 4, "end": 8, "repeat_of": "a"},
            {"id": "c", "start": 8, "end": 12, "repeat_of": "b"},
        ]
        plan = draft_plan(p)
        self.assertEqual(validate_plan(p, plan), [])
        signatures = [[(s["clip_id"], s["source_in"], s["end_beat"] - s["start_beat"]) for s in plan["shots"] if i <= s["start_beat"] < i + 4] for i in (0, 4, 8)]
        self.assertEqual(signatures[0], signatures[1])
        self.assertEqual(signatures[1], signatures[2])


class ExportTests(unittest.TestCase):
    def test_file_urls_escape_every_path_component(self):
        uri = media_url("/tmp/Clips/Sonne & Meer ü #1%.mov")
        self.assertEqual(uri, Path("/tmp").resolve().as_uri() + "/Clips/Sonne%20%26%20Meer%20%C3%BC%20%231%25.mov")

    def test_xmeml_has_v4_source_metadata_and_only_song_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = export_xmeml(project(), simple_plan(), Path(tmp) / "timeline.xml")
            root = ET.parse(result).getroot()
            self.assertEqual((root.tag, root.get("version")), ("xmeml", "4"))
            self.assertEqual(root.findtext("./sequence/duration"), "200")
            video = root.findall("./sequence/media/video/track/clipitem")
            self.assertEqual([(c.findtext("start"), c.findtext("end")) for c in video], [("0", "100"), ("100", "200")])
            self.assertEqual(video[1].findtext("./file/media/video/samplecharacteristics/width"), "3840")
            self.assertEqual(video[1].findtext("./rate/timebase"), "30")
            self.assertEqual(video[1].findtext("./rate/ntsc"), "TRUE")
            self.assertIsNone(video[0].find("./file/media/audio"))
            self.assertIn("%C3%BC", video[0].findtext("./file/pathurl"))
            audio = root.findall("./sequence/media/audio/track/clipitem")
            self.assertEqual(len(audio), 2)
            self.assertEqual([c.findtext("./sourcetrack/trackindex") for c in audio], ["1", "2"])
            self.assertEqual(len(audio[0].findall("link")), 2)
            self.assertEqual(audio[0].findtext("./file/media/audio/channelcount"), "2")
            self.assertEqual(audio[0].findtext("end"), "200")

    def test_xmeml_reuses_files_and_keeps_each_shot_identity(self):
        plan = simple_plan()
        plan["shots"][1]["clip_id"] = "sun"
        with tempfile.TemporaryDirectory() as tmp:
            root = ET.parse(export_xmeml(project(), plan, Path(tmp) / "timeline.xml")).getroot()
            items = root.findall("./sequence/media/video/track/clipitem")
            self.assertNotEqual(items[0].get("id"), items[1].get("id"))
            self.assertEqual(items[0].find("file").get("id"), items[1].find("file").get("id"))
            self.assertIsNone(items[1].find("./file/pathurl"))

    def test_invalid_export_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "timeline.xml"
            path.write_text("previous valid export", encoding="utf-8")
            plan = simple_plan()
            plan["shots"][0]["source_in"] = 1000
            with self.assertRaises(PlanError):
                export_xmeml(project(), plan, path)
            self.assertEqual(path.read_text(encoding="utf-8"), "previous valid export")

    def test_legacy_rate_rejects_nonrepresentable_fps_without_corrupting_file(self):
        p = project()
        p["timeline"]["fps_num"], p["timeline"]["fps_den"] = 2997, 100
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(PlanError, "nicht verlustfrei"):
                export_xmeml(p, simple_plan(), Path(tmp) / "timeline.xml")

    def test_fcpxml_music_anchor_accounts_for_nonzero_source_start(self):
        plan = simple_plan()
        plan["shots"][0]["source_in"] = 0.5
        with tempfile.TemporaryDirectory() as tmp:
            root = ET.parse(export_fcpxml(project(), plan, Path(tmp) / "timeline.fcpxml")).getroot()
            self.assertEqual(root.tag, "fcpxml")
            shots = root.findall("./library/event/project/sequence/spine/asset-clip")
            self.assertEqual(len(shots), 2)
            self.assertEqual(shots[0].get("start"), "13/25s")
            music = shots[0].find("asset-clip")
            self.assertEqual(music.get("offset"), shots[0].get("start"))
            self.assertEqual(music.get("lane"), "-1")
            self.assertEqual(music.get("duration"), "8s")
            self.assertEqual(root.get("version"), "1.8")
            sequence = root.find("./library/event/project/sequence")
            formats = {f.get("id") for f in root.findall("./resources/format")}
            self.assertIn(sequence.get("format"), formats)
            self.assertEqual(root.find("./resources/format").get("name"), "FFVideoFormat1080p25")
            for item in shots:
                self.assertIn(item.get("format"), formats)
                self.assertIn(item.get("ref"), {a.get("id") for a in root.findall("./resources/asset")})
            ids = {r.get("id") for r in root.find("resources")}
            self.assertTrue(all(s.get("ref") in ids for s in root.iter("asset-clip")))

    @unittest.skipUnless(importlib.util.find_spec("opentimelineio"), "OpenTimelineIO is optional in developer test environments")
    def test_otio_roundtrip_has_video_above_complete_song_and_no_drift(self):
        import opentimelineio as otio
        with tempfile.TemporaryDirectory() as tmp:
            result = export_otio(project(), simple_plan(), Path(tmp) / "timeline.otio")
            timeline = otio.adapters.read_from_file(str(result))
            self.assertEqual([t.kind for t in timeline.tracks], ["Audio", "Video"])
            self.assertAlmostEqual(timeline.tracks[0].duration().to_seconds(), 8.0)
            self.assertAlmostEqual(timeline.tracks[1].duration().to_seconds(), 8.0)
            self.assertEqual(len(timeline.tracks[1]), 2)
            self.assertTrue(timeline.tracks[1][0].media_reference.target_url.startswith("file:///"))

    @unittest.skipUnless(importlib.util.find_spec("opentimelineio"), "OpenTimelineIO is optional in developer test environments")
    def test_otio_ntsc_roundtrip_keeps_absolute_cut_frames_and_full_audio_samples(self):
        import opentimelineio as otio
        p = project()
        p["timeline"]["fps_num"], p["timeline"]["fps_den"] = 30000, 1001
        p["audio"]["duration"], p["audio"]["beats"] = 100.0, [i / 3 for i in range(1, 300)]
        plan = {"version": 1, "shots": [{"clip_id": "sun", "start_beat": i, "end_beat": i + 1, "source_in": 0.0} for i in range(300)]}
        compiled = compile_timeline(p, plan)
        with tempfile.TemporaryDirectory() as tmp:
            result = export_otio(p, plan, Path(tmp) / "timeline.otio")
            timeline = otio.adapters.read_from_file(str(result))
            audio, video = timeline.tracks
            self.assertEqual(audio[0].source_range.duration.value, 4800000)
            self.assertAlmostEqual(video.duration().value, 2997)
            for shot, item in zip(compiled["shots"], video):
                self.assertAlmostEqual(video.range_of_child(item).start_time.value, shot["start"])
                self.assertAlmostEqual(item.duration().value, shot["duration_frames"])


if __name__ == "__main__":
    unittest.main()
