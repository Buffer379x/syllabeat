"""Offline contract tests for the API clients and transactional file operations."""
from __future__ import annotations

import json
import errno
import os
import tempfile
import threading
import time
import traceback
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from unittest.mock import MagicMock

from videocreator import services, storage


class MockOllama(BaseHTTPRequestHandler):
    models = []
    requests = []
    mode = "normal"

    def log_message(self, *args):
        pass

    def _json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/tags":
            self._json({"models": [{"name": model} for model in self.models]})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).requests.append((self.path, payload))
        if self.path == "/responses":
            if self.mode == "unauthorized":
                self._json({"error": {"message": "Invalid secret key"}}, 401)
            elif self.mode == "refusal":
                self._json({"output": [{"content": [{"type": "refusal", "refusal": "Testable refusal"}]}]})
            else:
                self._json({"status": "completed", "output": [{"type": "reasoning"}, {"type": "message", "content": [{"type": "output_text", "text": '{"cuts":[]}'}]}]})
            return
        if self.mode == "error":
            self._json({"error": "model does not fit in RAM"}, 500)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        try:
            if self.path == "/api/pull":
                type(self).models.append(payload["model"])
                self.wfile.write(b'{"status":"pulling manifest"}\n')
                self.wfile.write(b'{"status":"downloading","completed":10,"total":100}\n')
                self.wfile.write(b'{"status":"success"}\n')
            elif self.path == "/api/generate":
                if self.mode == "slow":
                    self.wfile.write(b'{"response":"hello","done":false}\n')
                    self.wfile.flush()
                    time.sleep(1.5)
                else:
                    self.wfile.write(b'{"response":"{\\\"cuts\\\":","done":false}\n')
                    self.wfile.write(b'{"response":"[]}","done":true}\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


class ServicesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), MockOllama)
        cls.server.daemon_threads = True
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        MockOllama.models = []
        MockOllama.requests = []
        MockOllama.mode = "normal"
        self.manager = services.OllamaManager(self.url)

    def tearDown(self):
        self.manager.close()

    def test_auto_download_and_structured_stream(self):
        messages = []
        schema = {"type": "object", "properties": {"cuts": {"type": "array"}}}
        answer = self.manager.generate("Plan", "test:7b", schema=schema, images=["YWJj"], progress=messages.append)
        self.assertEqual(json.loads(answer), {"cuts": []})
        self.assertEqual(self.manager.list_models(), ["test:7b"])
        self.assertEqual([path for path, _ in MockOllama.requests], ["/api/pull", "/api/generate"])
        self.assertEqual(MockOllama.requests[-1][1]["format"], schema)
        self.assertEqual(MockOllama.requests[-1][1]["images"], ["YWJj"])
        self.assertTrue(any("10%" in message for message in messages))

    def test_existing_model_and_external_server_survive_close(self):
        MockOllama.models = ["local:latest"]
        self.manager.generate("Plan", "local")
        self.manager.close()
        self.assertEqual(self.manager.list_models(), ["local:latest"])
        self.assertEqual(len(MockOllama.requests), 1)

    def test_server_error_is_actionable(self):
        MockOllama.models = ["test:7b"]
        MockOllama.mode = "error"
        with self.assertRaisesRegex(services.ServiceError, "RAM"):
            self.manager.generate("Plan", "test:7b")

    def test_cancellation_interrupts_stream_promptly(self):
        MockOllama.models = ["test:7b"]
        MockOllama.mode = "slow"
        cancel = threading.Event()
        timer = threading.Timer(0.2, cancel.set)
        timer.start()
        started = time.monotonic()
        with self.assertRaises(services.CancelledError):
            self.manager.generate("Plan", "test:7b", cancel=cancel)
        timer.join()
        self.assertLess(time.monotonic() - started, 1.0)

    def test_reject_remote_ollama_url(self):
        with self.assertRaises(ValueError):
            services.OllamaManager("http://example.com:11434")
        with self.assertRaises(ValueError):
            services.OllamaManager("http://localhost:11434/api")

    def test_context_scales_and_rejects_oversized_analysis(self):
        self.assertEqual(services._context_options("Short prompt")["num_ctx"], 8192)
        self.assertEqual(services._context_options("x" * 30000)["num_ctx"], 32768)
        self.assertGreater(services._context_options("x" * 30000)["num_predict"], 4096)
        with self.assertRaisesRegex(services.ServiceError, "zu groß"):
            services._context_options("x" * 100000)

    def test_openai_responses_payload_and_errors(self):
        real_request = services._request

        def local_request(url, *args, **kwargs):
            self.assertEqual(url, "https://api.openai.com/v1/responses")
            self.assertEqual(kwargs["headers"]["Authorization"], "Bearer test-secret")
            return real_request(self.url + "/responses", *args, **kwargs)

        schema = {"type": "object", "properties": {}, "additionalProperties": False}
        with patch.object(services, "_request", side_effect=local_request):
            self.assertEqual(services.openai_generate("Plan", "model", "test-secret", schema), '{"cuts":[]}')
            body = MockOllama.requests[-1][1]
            self.assertEqual(body["text"]["format"]["type"], "json_schema")
            self.assertTrue(body["text"]["format"]["strict"])
            self.assertFalse(body["store"])
            MockOllama.mode = "unauthorized"
            with self.assertRaisesRegex(services.ServiceError, "401"):
                services.openai_generate("Plan", "model", "test-secret", schema)
            MockOllama.mode = "refusal"
            with self.assertRaisesRegex(services.ServiceError, "abgelehnt"):
                services.openai_generate("Plan", "model", "test-secret", schema)

    def test_vision_catalog_uses_frame_contract_without_renaming(self):
        manager = MagicMock()
        manager.generate.return_value = json.dumps({
            "description": "Ein Paar geht am Strand im Abendlicht.",
            "action": "Zwei Personen gehen", "motif": "Paar am Strand", "mood": "Warm und ruhig",
            "tags": ["Strand", "Paar", "Abend"], "filename_suggestion": "paar_am_strand",
        })
        clips = [{"id": "unchanged-id", "path": "/tmp/Original.mov", "duration": 10}]
        with patch("videocreator.analysis.extract_frames", return_value=[{"time": 2, "image": "YWJj"}]):
            result = services.analyze_vision(clips, manager)
        self.assertEqual(result[0]["id"], "unchanged-id")
        self.assertEqual(result[0]["path"], clips[0]["path"])
        self.assertEqual(result[0]["suggested_filename"], "paar_am_strand")
        self.assertEqual(manager.generate.call_args.kwargs["images"], ["YWJj"])
        self.assertEqual(result[0]["vision_frames"], [{"time": 2.0}])
        self.assertNotIn("description", clips[0])


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.environment = patch.dict(os.environ, {"VC_DATA_DIR": str(self.root / "support")})
        self.environment.start()
        self.clips = []
        for index in range(2):
            path = self.root / f"Original {index}.mov"
            path.write_bytes(f"video-{index}".encode())
            self.clips.append({"id": f"clip-{index}", "path": str(path), "name": path.name,
                               "duration": 2.0, "fps_num": 25, "fps_den": 1, "width": 640, "height": 360,
                               "description": "Küste / Abend?"})

    def tearDown(self):
        self.environment.stop()
        self.temporary.cleanup()

    def test_project_atomic_round_trip(self):
        project = storage.new_project()
        project["clips"] = self.clips
        project["lyrics"] = "Über den Wolken"
        path = self.root / "Projekt.vc.json"
        storage.save_project(project, path)
        self.assertEqual(storage.load_project(path), project)
        invalid = dict(project, duration=float("nan"))
        with self.assertRaises(ValueError):
            storage.save_project(invalid, path)
        self.assertEqual(storage.load_project(path), project)

    def test_project_rejects_malformed_nested_shapes(self):
        project = storage.new_project()
        project["clips"] = self.clips
        project["audio"] = {"duration": 2.0, "beats": [0.5, 1.0], "lines": [{"id": "line-1", "start": 0.1, "end": 1.0, "text": "Über den Wolken"}],
                            "sections": [{"id": "intro", "label": "Intro", "start": 0, "end": 2.0, "repeat_of": None}]}
        path = self.root / "bad.vcproject"
        cases = [
            ("clips", [{}]), ("clips", [None]), ("audio", {"duration": 2, "lines": [{}]}),
            ("audio", {"duration": "two"}), ("audio", {"duration": 2, "beats": [True]}),
            ("audio", {"duration": 2, "sections": [{}]}), ("timeline", {"fps_num": 25, "fps_den": 0, "width": 1920, "height": 1080}),
            ("timeline", {"fps_num": True, "fps_den": 1, "width": 1920, "height": 1080}),
            ("plan", {"version": 1, "shots": [{}]}), ("plan_draft", {}), ("name", ["Not text"]),
        ]
        import copy
        for field, value in cases:
            bad = copy.deepcopy(project)
            bad[field] = value
            path.write_text(json.dumps(bad))
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                storage.load_project(path)
        for field, value in [("fps_den", 0), ("duration", float("nan")), ("duration", 10 ** 1000), ("description", {}), ("tags", "beach"), ("samples", [{"time": 0.5, "image": "invalid padding"}])]:
            bad = copy.deepcopy(project)
            bad["clips"][0][field] = value
            path.write_text(json.dumps(bad))
            with self.subTest(clip_field=field), self.assertRaises(ValueError):
                storage.load_project(path)

    def test_valid_project_preserves_optional_drafts(self):
        project = storage.new_project()
        project["clips"] = self.clips
        project["plan_draft"] = "An unfinished JSON reply {"
        project["custom_metadata"] = {"future_field": "kept"}
        path = self.root / "draft.vcproject"
        storage.save_project(project, path)
        self.assertEqual(storage.load_project(path), project)

    def test_project_rejects_duplicate_clip_ids_and_json_keys(self):
        project = storage.new_project()
        project["clips"] = [self.clips[0], self.clips[0]]
        path = self.root / "duplicates.vcproject"
        path.write_text(json.dumps(project))
        with self.assertRaisesRegex(ValueError, "eindeutige"):
            storage.load_project(path)
        path.write_text('{"version":1,"version":1}')
        with self.assertRaisesRegex(ValueError, "mehrfach"):
            storage.load_project(path)
        path.write_text('{"version":1,"future_metadata":{"number":1e999}}')
        with self.assertRaisesRegex(ValueError, "nicht endlichen"):
            storage.load_project(path)

    def test_rename_and_undo_keep_stable_ids_and_media(self):
        preview = storage.rename_preview(self.clips)
        self.assertEqual(Path(preview[0]["new_path"]).name, "kueste_abend_001.mov")
        updated = storage.rename_clips(self.clips, preview)
        self.assertEqual([c["id"] for c in updated], [c["id"] for c in self.clips])
        self.assertFalse(Path(self.clips[0]["path"]).exists())
        self.assertEqual(Path(updated[0]["path"]).read_bytes(), b"video-0")
        restored = storage.undo_rename(updated)
        self.assertEqual([c["path"] for c in restored], [c["path"] for c in self.clips])
        self.assertEqual(Path(restored[1]["path"]).read_bytes(), b"video-1")
        with self.assertRaisesRegex(ValueError, "keine passende"):
            storage.undo_rename(restored)

    def test_existing_target_never_overwritten(self):
        preview = storage.rename_preview(self.clips)
        Path(preview[0]["new_path"]).write_bytes(b"keep me")
        with self.assertRaises(FileExistsError):
            storage.rename_clips(self.clips, preview)
        self.assertEqual(Path(preview[0]["new_path"]).read_bytes(), b"keep me")
        self.assertTrue(all(Path(c["path"]).exists() for c in self.clips))

    def test_mid_transaction_failure_restores_every_original(self):
        preview = storage.rename_preview(self.clips)
        link = os.link
        failed = [False]

        def fail_second(source, target, **kwargs):
            if str(target) == preview[1]["new_path"] and not failed[0]:
                failed[0] = True
                raise OSError("Simulated disk failure")
            return link(source, target, **kwargs)

        with patch.object(storage.os, "link", side_effect=fail_second):
            with self.assertRaisesRegex(OSError, "disk failure"):
                storage.rename_clips(self.clips, preview)
        for index, clip in enumerate(self.clips):
            self.assertEqual(Path(clip["path"]).read_bytes(), f"video-{index}".encode())
        self.assertTrue(all(not Path(mapping["new_path"]).exists() for mapping in preview))
        self.assertFalse(list(self.root.glob(".videocreator-rename-*")))

    def test_swap_names_is_transactional(self):
        mappings = [
            {"id": self.clips[0]["id"], "old_path": self.clips[0]["path"], "new_path": self.clips[1]["path"]},
            {"id": self.clips[1]["id"], "old_path": self.clips[1]["path"], "new_path": self.clips[0]["path"]},
        ]
        renamed = storage.rename_clips(self.clips, mappings)
        self.assertEqual(Path(renamed[0]["path"]).read_bytes(), b"video-0")
        self.assertEqual(Path(renamed[1]["path"]).read_bytes(), b"video-1")
        restored = storage.undo_rename(renamed)
        self.assertEqual(Path(restored[0]["path"]).read_bytes(), b"video-0")

    def test_keychain_timeout_does_not_expose_key(self):
        import subprocess
        secret = "private-test-key"
        error = subprocess.TimeoutExpired(["security", "-w", secret], 30)
        with patch.object(storage.subprocess, "run", side_effect=error):
            try:
                storage.keychain_set(secret)
            except RuntimeError:
                self.assertNotIn(secret, traceback.format_exc())
            else:
                self.fail("A Keychain timeout must be reported")

    @unittest.skipUnless(os.uname().sysname == "Darwin", "macOS exclusive-rename syscall")
    def test_filesystem_without_hardlink_support(self):
        preview = storage.rename_preview(self.clips)
        with patch.object(storage.os, "link", side_effect=OSError(errno.ENOTSUP, "No hard links")):
            renamed = storage.rename_clips(self.clips, preview)
            restored = storage.undo_rename(renamed)
        self.assertEqual(Path(restored[0]["path"]).read_bytes(), b"video-0")

    def _pending_rename(self):
        changes = storage.rename_preview(self.clips)
        for index, change in enumerate(changes):
            old = Path(change["old_path"])
            change["staging_path"] = str(old.with_name(f".videocreator-rename-crash-{index}.mov"))
            change["signature"] = storage._file_signature(old)
        storage._atomic_json({"transactions": [{"id": "interrupted", "state": "pending", "changes": changes}]}, storage._history_path())
        return changes

    def test_pending_rename_recovers_staged_and_completed_files(self):
        changes = self._pending_rename()
        for change in changes:
            Path(change["old_path"]).rename(change["staging_path"])
        Path(changes[0]["staging_path"]).rename(changes[0]["new_path"])
        restored = storage.recover_pending_rename(self.clips)
        for index, clip in enumerate(restored):
            self.assertEqual(Path(clip["path"]).read_bytes(), f"video-{index}".encode())
        self.assertFalse(list(self.root.glob(".videocreator-rename-*")))
        self.assertEqual(storage._load_history()["transactions"][0]["state"], "recovered")
        self.assertEqual(storage.recover_pending_rename(restored), restored)

    def test_pending_rename_handles_partial_staging_and_external_collision(self):
        changes = self._pending_rename()
        first = changes[0]
        Path(first["old_path"]).rename(first["staging_path"])
        Path(first["old_path"]).write_bytes(b"external file remains")
        with self.assertRaisesRegex(FileExistsError, "andere Datei"):
            storage.recover_pending_rename(self.clips)
        self.assertEqual(Path(first["old_path"]).read_bytes(), b"external file remains")
        self.assertTrue(Path(first["staging_path"]).exists())
        Path(first["old_path"]).unlink()
        restored = storage.recover_pending_rename(self.clips)
        self.assertEqual(Path(restored[0]["path"]).read_bytes(), b"video-0")

    def test_failed_rename_is_not_recovered_after_later_success(self):
        preview = storage.rename_preview(self.clips)
        target = Path(preview[0]["new_path"])
        target.write_bytes(b"existing")
        with self.assertRaises(FileExistsError):
            storage.rename_clips(self.clips, preview)
        target.unlink()
        renamed = storage.rename_clips(self.clips, preview)
        self.assertEqual(storage.recover_pending_rename(renamed), renamed)


if __name__ == "__main__":
    unittest.main()
