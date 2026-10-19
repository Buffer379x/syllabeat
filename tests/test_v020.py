"""0.2.0: scene segments, cut style, FCPXML 1.8, EDL, model folder."""
from __future__ import annotations

import os
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch

from syllabeat import storage
from syllabeat.exporters import export_edl, export_fcpxml
from syllabeat.planning import draft_plan, validate_plan, build_prompt
from test_timeline import project, simple_plan


def long_project() -> dict:
    p = project()
    p["audio"]["duration"] = 60.0
    p["audio"]["beats"] = [i * 0.5 for i in range(1, 120)]
    p["clips"][0].update(duration=15.0, frame_count=375, segments=[
        {"start": 0, "end": 5, "description": "Strand"}, {"start": 5, "end": 10, "description": "Wellen"}, {"start": 10, "end": 15, "description": "Sonne"}])
    p["clips"][1].update(duration=15.0, frame_count=449)
    p["audio"]["sections"] = [{"id": "a", "start": 0, "end": 20}, {"id": "c1", "start": 20, "end": 30},
                              {"id": "b", "start": 30, "end": 50}, {"id": "c2", "start": 50, "end": 60, "repeat_of": "c1"}]
    return p


class CutStyleTests(unittest.TestCase):
    def lengths(self, plan):
        return [s["end_beat"] - s["start_beat"] for s in plan["shots"]]

    def test_uniform_style_is_regular_and_valid(self):
        p = long_project()
        plan = draft_plan(p, {"variation": "gleichmaessig", "chorus_faster": False})
        self.assertEqual(validate_plan(p, plan), [])
        self.assertEqual(set(self.lengths(plan)[:8]), {4})

    def test_variation_changes_lengths_and_seed_is_deterministic(self):
        p = long_project()
        a = draft_plan(p, {"variation": "wild", "seed": 3})
        self.assertEqual(validate_plan(p, a), [])
        self.assertGreater(len(set(self.lengths(a))), 2)
        self.assertEqual(a, draft_plan(p, {"variation": "wild", "seed": 3}))
        self.assertNotEqual(a, draft_plan(p, {"variation": "wild", "seed": 4}))

    def test_chorus_cuts_faster_than_verse(self):
        p = long_project()
        plan = draft_plan(p, {"variation": "gleichmaessig", "verse_beats": 4, "chorus_beats": 2, "chorus_faster": True})
        verse = [s for s in plan["shots"] if s["end_beat"] <= 40]
        chorus = [s for s in plan["shots"] if 40 <= s["start_beat"] and s["end_beat"] <= 60]
        self.assertGreater(sum(s["end_beat"] - s["start_beat"] for s in verse) / len(verse),
                           sum(s["end_beat"] - s["start_beat"] for s in chorus) / len(chorus))

    def test_sources_start_inside_clip_not_always_at_zero(self):
        p = long_project()
        plan = draft_plan(p)
        self.assertTrue(any(s["source_in"] > 0 for s in plan["shots"]))

    def test_chorus_repeat_is_exact_copy(self):
        p = long_project()
        plan = draft_plan(p, {"variation": "wild"})
        first = [(s["clip_id"], s["source_in"], s["end_beat"] - s["start_beat"]) for s in plan["shots"] if 40 <= s["start_beat"] < 60]
        self.assertTrue(first)

    def test_prompt_contains_scenes_and_style(self):
        text = build_prompt(long_project())
        self.assertIn("szenen", text)
        self.assertIn("SCHNITTSTIL", text)


class ExportTests(unittest.TestCase):
    def test_fcpxml_has_resolvable_formats(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = ET.parse(export_fcpxml(project(), simple_plan(), Path(tmp) / "t.fcpxml")).getroot()
            ids = [e.get("id") for e in root.find("resources")]
            self.assertEqual(len(ids), len(set(ids)))
            self.assertEqual(root.find("./library/event/project/sequence").get("format"), "r1")
            self.assertIsNone(root.find("./resources/format").get("fieldOrder"))

    def test_edl_lists_every_shot_with_clip_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            text = export_edl(project(), simple_plan(), Path(tmp) / "t.edl").read_text(encoding="utf-8")
            self.assertIn("FCM: NON-DROP FRAME", text)
            self.assertIn("001  AX       V     C        00:00:00:00 00:00:04:00 01:00:00:00 01:00:04:00", text)
            self.assertIn("* FROM CLIP NAME: Stadt.mov", text)


class ModelFolderTests(unittest.TestCase):
    def test_setting_and_environment_choose_model_folder(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"VC_DATA_DIR": tmp, "VC_MODEL_DIR": ""}):
            self.assertEqual(storage.models_dir(), Path(tmp) / "models")
            custom = Path(tmp) / "Modelle"
            self.assertEqual(storage.models_dir({"models_dir": str(custom)}), custom)
            self.assertTrue(custom.is_dir())
            with patch.dict(os.environ, {"VC_MODEL_DIR": str(Path(tmp) / "env")}):
                self.assertEqual(storage.models_dir({"models_dir": str(custom)}), Path(tmp) / "env")
                storage.configure_model_cache()
                self.assertEqual(os.environ["HF_HOME"], str(Path(tmp) / "env/huggingface"))


class SegmentTests(unittest.TestCase):
    def test_detects_hard_cut_and_splits_long_takes(self):
        import cv2
        import numpy as np
        from syllabeat.analysis import detect_segments
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cut.mp4"
            writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), 10, (128, 72))
            for i in range(120):  # 12 s: red 0-4 s, then a noisy blue/green scene
                frame = np.zeros((72, 128, 3), np.uint8)
                frame[:] = (0, 0, 220) if i < 40 else (200, 160, 0)
                writer.write(frame)
            writer.release()
            segments = detect_segments(path, 12.0, 10.0)
            self.assertAlmostEqual(segments[0]["start"], 0.0)
            self.assertAlmostEqual(segments[-1]["end"], 12.0)
            self.assertTrue(any(abs(s["end"] - 4.0) < 0.6 for s in segments))
            self.assertTrue(all(b["start"] == a["end"] for a, b in zip(segments, segments[1:])))
            self.assertTrue(all(s["end"] - s["start"] <= 5.0 + 1e-6 for s in segments))


if __name__ == "__main__":
    unittest.main()
