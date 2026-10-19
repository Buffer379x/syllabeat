"""Regression tests for the 0.1.0 additions: beat grid, migration, recent files, vision resume."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from syllabeat import APP_NAME, LEGACY_APP_NAME, __version__, services, storage
from syllabeat.analysis import retime_beats


class VersionTests(unittest.TestCase):
    def test_version_and_name(self):
        self.assertEqual(__version__, "0.1.0")
        self.assertEqual(APP_NAME, "SyllaBeat")

    def test_spec_reads_single_version_source(self):
        spec = (Path(__file__).resolve().parents[1] / "SyllaBeat.spec").read_text(encoding="utf-8")
        self.assertIn("CFBundleShortVersionString':VERSION", spec)
        self.assertNotIn("1.0.0", spec)


class BeatGridTests(unittest.TestCase):
    beats = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]

    def test_every_second_and_fourth_beat_with_phase(self):
        self.assertEqual(retime_beats(self.beats, "every_2", 5), [0.5, 1.5, 2.5, 3.5])
        self.assertEqual(retime_beats(self.beats, "every_2", 5, phase=1), [1.0, 2.0, 3.0, 4.0])
        self.assertEqual(retime_beats(self.beats, "every_4", 5, phase=3), [2.0, 4.0])

    def test_double_inserts_midpoints(self):
        self.assertEqual(retime_beats([1.0, 2.0, 3.0], "double", 5), [1.0, 1.5, 2.0, 2.5, 3.0])

    def test_shift_stays_strictly_inside_song(self):
        self.assertEqual(retime_beats([0.02, 1.0, 4.99], "shift", 5, offset=0.05), [0.07, 1.05])
        self.assertEqual(retime_beats([0.02, 1.0], "shift", 5, offset=-0.05), [0.95])

    def test_invalid_mode_and_values(self):
        with self.assertRaises(ValueError):
            retime_beats(self.beats, "triple", 5)
        self.assertEqual(retime_beats([float("nan"), 1.0, 1.0], "shift", 5), [1.0])


class DataFolderTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.patches = [patch.object(Path, "home", return_value=Path(self.home.name)),
                        patch.dict(os.environ, {"VC_DATA_DIR": ""})]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.home.cleanup()

    def test_legacy_folder_with_models_is_renamed_once(self):
        support = Path(self.home.name) / "Library/Application Support"
        legacy = support / LEGACY_APP_NAME / "models"
        legacy.mkdir(parents=True)
        (legacy / "weights.bin").write_text("x")
        folder = storage.app_support()
        self.assertEqual(folder, support / APP_NAME)
        self.assertTrue((folder / "models/weights.bin").is_file())
        self.assertFalse((support / LEGACY_APP_NAME).exists())

    def test_new_folder_wins_over_legacy(self):
        support = Path(self.home.name) / "Library/Application Support"
        (support / APP_NAME).mkdir(parents=True)
        (support / LEGACY_APP_NAME).mkdir()
        self.assertEqual(storage.app_support(), support / APP_NAME)
        self.assertTrue((support / LEGACY_APP_NAME).exists())


class RecentProjectTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {"VC_DATA_DIR": self.directory.name})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.directory.cleanup()

    def test_recent_list_is_unique_newest_first_and_skips_missing(self):
        paths = []
        for index in range(storage.RECENT_LIMIT + 2):
            path = Path(self.directory.name) / f"p{index}.syllabeat"
            storage.save_project(storage.new_project(), path)
            paths.append(path)
            storage.remember_project(path)
        storage.remember_project(paths[3])
        recent = storage.recent_projects()
        self.assertEqual(recent[0], str(paths[3].absolute()))
        self.assertEqual(len(recent), storage.RECENT_LIMIT)
        self.assertEqual(len(set(recent)), len(recent))
        paths[3].unlink()
        self.assertNotIn(str(paths[3].absolute()), storage.recent_projects())


class KeychainTests(unittest.TestCase):
    def test_legacy_keychain_entry_is_still_found(self):
        calls = []

        def fake(arguments):
            calls.append(arguments)
            service = arguments[arguments.index("-s") + 1]
            if service == storage.KEYCHAIN_SERVICE:
                return subprocess.CompletedProcess(arguments, 44, "", "")
            return subprocess.CompletedProcess(arguments, 0, "sk-legacy\n", "")

        with patch.object(storage, "_security", side_effect=fake):
            self.assertEqual(storage.keychain_get(), "sk-legacy")
        self.assertEqual([c[c.index("-s") + 1] for c in calls], [storage.KEYCHAIN_SERVICE, storage.LEGACY_KEYCHAIN_SERVICE])


class VisionResumeTests(unittest.TestCase):
    answer = json.dumps({"description": "Ein Hund läuft über eine Wiese.", "action": "läuft", "motif": "Hund",
                         "mood": "fröhlich", "tags": ["Hund", " ", "Wiese"], "filename_suggestion": "hund_wiese"})

    def clips(self):
        return [{"id": "a", "path": "/tmp/a.mov", "duration": 4, "description": "schon da"},
                {"id": "b", "path": "/tmp/b.mov", "duration": 4},
                {"id": "c", "path": "/tmp/c.mov", "duration": 4}]

    def test_only_missing_skips_described_clips(self):
        manager = MagicMock()
        manager.generate.return_value = self.answer
        with patch("syllabeat.analysis.extract_frames", return_value=[{"time": 1, "image": "YWJj"}]):
            result = services.analyze_vision(self.clips(), manager, only_missing=True)
        self.assertEqual(manager.generate.call_count, 2)
        self.assertEqual(result[0]["description"], "schon da")
        self.assertEqual(result[1]["tags"], ["Hund", "Wiese"])

    def test_single_failure_keeps_other_results_and_reports_progress(self):
        manager = MagicMock()
        manager.generate.side_effect = [self.answer, "kein json", self.answer]
        events = []
        with patch("syllabeat.analysis.extract_frames", return_value=[{"time": 1, "image": "YWJj"}]):
            result = services.analyze_vision(self.clips(), manager, progress=lambda message, fraction=0: events.append(fraction))
        self.assertNotIn("vision_error", result[0])
        self.assertIn("kein gültiges JSON", result[1]["vision_error"])
        self.assertEqual(result[2]["description"], "Ein Hund läuft über eine Wiese.")
        self.assertEqual(max(events), 1.0)

    def test_all_failures_raise(self):
        manager = MagicMock()
        manager.generate.return_value = "kaputt"
        with patch("syllabeat.analysis.extract_frames", return_value=[{"time": 1, "image": "YWJj"}]):
            with self.assertRaises(services.ServiceError):
                services.analyze_vision(self.clips(), manager)

    def test_unreachable_server_aborts_immediately(self):
        manager = MagicMock()
        manager.generate.side_effect = services.ServiceError("Der KI-Server ist nicht erreichbar oder antwortet zu langsam: refused")
        with patch("syllabeat.analysis.extract_frames", return_value=[{"time": 1, "image": "YWJj"}]):
            with self.assertRaises(services.ServiceError):
                services.analyze_vision(self.clips(), manager)
        self.assertEqual(manager.generate.call_count, 1)


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg wird benötigt")
class ScanThumbnailTests(unittest.TestCase):
    def test_scan_stores_small_catalog_thumbnail(self):
        try:
            import cv2  # noqa: F401
        except ImportError:
            self.skipTest("OpenCV fehlt")
        from syllabeat.analysis import scan_clips
        with tempfile.TemporaryDirectory() as folder:
            subprocess.run([shutil.which("ffmpeg"), "-v", "error", "-f", "lavfi", "-i", "testsrc=s=1280x720:r=25:d=2",
                            "-an", "-c:v", "mpeg4", str(Path(folder) / "clip.mov")], check=True, timeout=60)
            with patch.dict(os.environ, {"VC_FFMPEG": shutil.which("ffmpeg"), "VC_FFPROBE": shutil.which("ffprobe")}):
                clips = scan_clips(folder)
                again = scan_clips(folder, clips)
        sample = clips[0]["samples"][0]
        self.assertGreater(len(sample["image"]), 100)
        self.assertLessEqual(sample["time"], 2)
        self.assertEqual(again[0]["samples"], clips[0]["samples"])
        self.assertEqual(again[0]["id"], clips[0]["id"])


if __name__ == "__main__":
    unittest.main()
