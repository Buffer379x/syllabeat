"""Provider-free integration tests for partitioning, correction and manual plans."""

import json
import unittest

from syllabeat.director import build_prompt_parts, generate_project_plan, merge_plan_parts
from syllabeat.planning import PlanError, validate_plan


def fixture(intervals=8):
    return {
        "version": 1, "name": "Director-Test", "audio_path": "/tmp/song.wav", "lyrics": "Sonne am Meer",
        "timeline": {"fps_num": 25, "fps_den": 1, "width": 1920, "height": 1080},
        "audio": {"duration": float(intervals), "sample_rate": 48000,
                  "beats": list(range(1, intervals)),
                  "lines": [{"id": "line1", "start": 0, "end": float(intervals), "text": "Sonne am Meer"}], "sections": []},
        "clips": [
            {"id": "sun", "name": "Sonne.mov", "path": "/tmp/Sonne.mov", "description": "Sonne am Meer", "tags": ["Sonne"],
             "duration": 1000.0, "fps_num": 25, "fps_den": 1, "width": 1920, "height": 1080, "frame_count": 25000},
            {"id": "city", "name": "Stadt.mov", "path": "/tmp/Stadt.mov", "description": "Nächtliche Stadt", "tags": ["Stadt"],
             "duration": 1000.0, "fps_num": 25, "fps_den": 1, "width": 1920, "height": 1080, "frame_count": 25000},
        ],
    }


def response(schema, clip=None):
    props = schema["properties"]["shots"]["items"]["properties"]
    return json.dumps({"version": 1, "shots": [{"clip_id": clip or props["clip_id"]["enum"][0],
                      "start_beat": props["start_beat"]["minimum"], "end_beat": props["end_beat"]["maximum"], "source_in": 0.0}]})


class AutomaticDirectorTests(unittest.TestCase):
    def test_small_project_uses_one_callback_and_core_validation(self):
        p, calls, progress = fixture(), [], []
        def generate(prompt, schema):
            calls.append((prompt, schema))
            return response(schema)
        result = json.loads(generate_project_plan(p, generate, progress=lambda m, f: progress.append((m, f))))
        self.assertEqual(len(calls), 1)
        self.assertEqual(validate_plan(p, result), [])
        self.assertEqual(progress[-1][1], 1.0)

    def test_invalid_json_and_unknown_clip_receive_two_targeted_repairs(self):
        calls = []
        def generate(prompt, schema):
            calls.append(prompt)
            if len(calls) == 1:
                return "This is not JSON"
            if len(calls) == 2:
                return response(schema, "does-not-exist")
            return response(schema)
        result = json.loads(generate_project_plan(fixture(), generate))
        self.assertEqual(len(calls), 3)
        self.assertIn("KORREKTUR ERFORDERLICH", calls[1])
        self.assertIn("Ungültiges JSON", calls[1])
        self.assertIn("unbekannte clip_id", calls[2])
        self.assertEqual(result["shots"][0]["clip_id"], "sun")

    def test_bad_source_range_is_repaired_instead_of_exported(self):
        calls = []
        def generate(prompt, schema):
            calls.append(prompt)
            plan = json.loads(response(schema))
            if len(calls) == 1:
                plan["shots"][0]["source_in"] = 999.0
            return json.dumps(plan)
        result = json.loads(generate_project_plan(fixture(), generate))
        self.assertEqual(len(calls), 2)
        self.assertIn("zu kurz", calls[1])
        self.assertEqual(result["shots"][0]["source_in"], 0.0)

    def test_corrections_are_bounded_to_two_attempts(self):
        calls = []
        def generate(prompt, schema):
            calls.append(prompt)
            return "{}"
        with self.assertRaisesRegex(PlanError, "zwei Korrekturversuchen"):
            generate_project_plan(fixture(), generate)
        self.assertEqual(len(calls), 3)

    def test_duration_is_not_confused_with_last_beat_id_and_repair_ends_with_instructions(self):
        p, calls = fixture(5), []
        p["audio"]["duration"], p["audio"]["beats"] = 2.5, [0.5, 1.0, 1.5, 2.0]
        p["clips"][0]["duration"], p["clips"][0]["frame_count"] = 3.0, 75
        def generate(prompt, schema):
            calls.append(prompt)
            plan = json.loads(response(schema))
            if len(calls) == 1:
                plan["shots"][0]["end_beat"] = 3
            return json.dumps(plan)
        result = json.loads(generate_project_plan(p, generate))
        self.assertEqual(result["shots"][-1]["end_beat"], 5)
        self.assertIn("Songdauer 2.5 Sekunden; erste Beat-ID 0; letzte Beat-ID 5", calls[0])
        self.assertIn('"last_beat_id": 5', calls[0])
        self.assertGreater(calls[1].rfind("KORREKTUR ERFORDERLICH"), calls[1].rfind("VORHERIGE FEHLERHAFTE ANTWORT"))
        self.assertTrue(calls[1].endswith("Antworte jetzt ausschließlich mit dem vollständig korrigierten JSON-Schnittplan."))

    def test_long_song_is_partitioned_with_global_ids_and_no_gaps(self):
        p, calls = fixture(200), []
        def generate(prompt, schema):
            calls.append((prompt, schema))
            return response(schema)
        result = json.loads(generate_project_plan(p, generate))
        self.assertEqual([(s["start_beat"], s["end_beat"]) for s in result["shots"]], [(0, 64), (64, 128), (128, 192), (192, 200)])
        self.assertEqual(len(calls), 4)
        self.assertIn("GLOBALE Beat-IDs 64 bis 128", calls[1][0])
        self.assertTrue(all(len(prompt) <= 65000 for prompt, _ in calls))
        self.assertEqual(validate_plan(p, result), [])

    def test_reset_local_ids_in_a_later_part_are_repaired(self):
        calls, attempts = [], {}
        def generate(prompt, schema):
            props = schema["properties"]["shots"]["items"]["properties"]
            start = props["start_beat"]["minimum"]
            attempts[start] = attempts.get(start, 0) + 1
            calls.append(prompt)
            plan = json.loads(response(schema))
            if start == 64 and attempts[start] == 1:
                plan["shots"][0]["start_beat"] = 0
            return json.dumps(plan)
        p = fixture(200)
        result = json.loads(generate_project_plan(p, generate))
        self.assertEqual(len(calls), 5)
        self.assertIn("außerhalb der globalen Teilgrenzen 64–128", calls[2])
        self.assertEqual(validate_plan(p, result), [])

    def test_repeat_sequence_is_enforced_after_parts_are_merged(self):
        p = fixture(200)
        p["audio"]["sections"] = [{"id": "a", "start": 0, "end": 64}, {"id": "b", "start": 128, "end": 192, "repeat_of": "a"}]
        def generate(prompt, schema):
            start = schema["properties"]["shots"]["items"]["properties"]["start_beat"]["minimum"]
            return response(schema, "sun" if start == 0 else "city")
        result = json.loads(generate_project_plan(p, generate))
        self.assertEqual([s["clip_id"] for s in result["shots"]], ["sun", "city", "sun", "city"])
        self.assertEqual(validate_plan(p, result), [])

    def test_source_template_is_repaired_when_a_slower_repeat_needs_longer_media(self):
        p, calls = fixture(200), []
        boundaries = [float(i) if i <= 128 else 128.0 + (i - 128) * 1.1 for i in range(201)]
        p["audio"]["duration"], p["audio"]["beats"] = boundaries[-1], boundaries[1:-1]
        p["clips"][0]["duration"], p["clips"][0]["frame_count"] = 64.0, 1600
        p["audio"]["sections"] = [{"id": "a", "start": 0, "end": 64}, {"id": "b", "start": boundaries[128], "end": boundaries[192], "repeat_of": "a"}]
        def generate(prompt, schema):
            calls.append(prompt)
            start = schema["properties"]["shots"]["items"]["properties"]["start_beat"]["minimum"]
            return response(schema, "sun" if start == 0 and "KORREKTUR ERFORDERLICH" not in prompt else "city")
        result = json.loads(generate_project_plan(p, generate))
        self.assertEqual(len(calls), 5)
        self.assertIn("Refrainfolge", calls[-1])
        self.assertEqual(result["shots"][0]["clip_id"], "city")
        self.assertEqual(validate_plan(p, result), [])

    def test_huge_catalog_is_ranked_and_bounded_per_part(self):
        p, calls = fixture(), []
        original = p["clips"][0]
        p["clips"] = [{**original, "id": f"clip-{i}", "name": f"Clip {i}.mov", "description": ("Sonne am Meer " if i == 500 else "Stadt Nacht ") * 300} for i in range(600)]
        def generate(prompt, schema):
            calls.append((prompt, schema))
            return response(schema)
        result = json.loads(generate_project_plan(p, generate))
        self.assertEqual(len(calls), 1)
        ids = calls[0][1]["properties"]["shots"]["items"]["properties"]["clip_id"]["enum"]
        self.assertLess(len(ids), len(p["clips"]))
        self.assertEqual(ids[0], "clip-500")
        self.assertLessEqual(len(calls[0][0]), 48000)
        self.assertEqual(validate_plan(p, result), [])

    def test_unicode_and_repair_prompts_fit_the_local_context_byte_budget(self):
        from syllabeat.services import _context_options
        p, calls = fixture(), []
        p["clips"] = [{**p["clips"][0], "id": f"clip-{i}", "description": "夕焼けの海と空" * 300} for i in range(30)]
        def generate(prompt, schema):
            _context_options(prompt)
            calls.append(prompt)
            return "{}" if len(calls) == 1 else response(schema)
        result = json.loads(generate_project_plan(p, generate))
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(len(prompt.encode("utf-8")) <= 56000 for prompt in calls))
        self.assertEqual(validate_plan(p, result), [])

    def test_catalog_error_is_clear_before_any_provider_call(self):
        p = fixture()
        p["clips"] = [{"id": str(i)} for i in range(20001)]
        with self.assertRaisesRegex(PlanError, "20.000"):
            generate_project_plan(p, lambda *_: self.fail("provider must not be called"))

    def test_cancellation_prevents_requests_and_stops_between_parts(self):
        with self.assertRaises(InterruptedError):
            generate_project_plan(fixture(), lambda *_: self.fail("must not call"), cancel=lambda: True)
        state, calls = {"cancel": False}, []
        def generate(prompt, schema):
            calls.append(prompt)
            state["cancel"] = True
            return response(schema)
        with self.assertRaises(InterruptedError):
            generate_project_plan(fixture(200), generate, cancel=lambda: state["cancel"])
        self.assertEqual(len(calls), 1)


class ManualDirectorTests(unittest.TestCase):
    def test_manual_prompts_use_global_ranges_and_bounded_catalogs(self):
        parts = build_prompt_parts(fixture(150))
        self.assertEqual(len(parts), 3)
        self.assertIn("GLOBALE Beat-IDs 64 bis 128", parts[1])
        self.assertIn("GLOBALE Beat-IDs 128 bis 150", parts[2])
        self.assertIn('"song_duration":150.0', parts[1])
        self.assertIn('"first_beat_id":64', parts[1])
        self.assertIn('"last_beat_id":128', parts[1])
        with self.assertRaises(PlanError):
            build_prompt_parts(fixture(), max_intervals=0)

    def test_merge_supports_fences_concatenated_objects_and_arrays(self):
        first = {"version": 1, "shots": [{"clip_id": "sun", "start_beat": 0, "end_beat": 4, "source_in": 0.0}]}
        second = {"version": 1, "shots": [{"clip_id": "city", "start_beat": 4, "end_beat": 8, "source_in": 0.0}]}
        for raw in [json.dumps(first) + "\n" + json.dumps(second), json.dumps([first, second]),
                    "Teil 2:\n```json\n" + json.dumps(second) + "\n```\nTeil 1:\n```json\n" + json.dumps(first) + "\n```"]:
            with self.subTest(raw=raw[:30]):
                result = merge_plan_parts(raw)
                self.assertEqual(result["shots"], first["shots"] + second["shots"])

    def test_overlapping_missing_or_reordered_shots_are_rejected(self):
        first = {"version": 1, "shots": [{"clip_id": "sun", "start_beat": 0, "end_beat": 4, "source_in": 0.0}]}
        for start in (3, 5):
            other = {"version": 1, "shots": [{"clip_id": "city", "start_beat": start, "end_beat": 8, "source_in": 0.0}]}
            with self.assertRaisesRegex(PlanError, "Lücke oder Überlappung"):
                merge_plan_parts([first, other])
        bad = {"version": 1, "shots": [first["shots"][0], {"clip_id": "sun", "start_beat": 2, "end_beat": 8, "source_in": 0}]}
        with self.assertRaisesRegex(PlanError, "nicht chronologisch"):
            merge_plan_parts(bad)

    def test_duplicates_and_nonfinite_values_in_arrays_are_rejected(self):
        with self.assertRaisesRegex(PlanError, "mehrfach"):
            merge_plan_parts('[{"version":1,"version":2,"shots":[]}]')
        with self.assertRaisesRegex(PlanError, "ungültigen Zahlenwert"):
            merge_plan_parts('[{"version":1,"shots":[],"bad":NaN}]')


if __name__ == "__main__":
    unittest.main()
