"""Cancelable local Ollama and OpenAI clients; no SDK or shell installation required."""
from __future__ import annotations

import base64
import copy
import json
import math
import os
import queue
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

from .storage import app_support, models_dir


class ServiceError(RuntimeError):
    pass


class CancelledError(RuntimeError):
    pass


def _cancelled(cancel: Any) -> bool:
    if cancel is None:
        return False
    if hasattr(cancel, "is_set"):
        return bool(cancel.is_set())
    if callable(cancel):
        return bool(cancel())
    return bool(cancel)


def _check_cancel(cancel: Any) -> None:
    if _cancelled(cancel):
        raise CancelledError("Vorgang abgebrochen.")


def _progress(progress: Callable | None, message: str) -> None:
    if progress:
        progress(message)


def _http_error(error: urllib.error.HTTPError) -> ServiceError:
    try:
        body = json.loads(error.read(32768).decode("utf-8", errors="replace"))
        detail = body.get("error", body)
        if isinstance(detail, dict):
            detail = detail.get("message", "Unbekannter API-Fehler")
        detail = str(detail)[:1200]
    except (ValueError, OSError):
        detail = error.reason
    if error.code == 401:
        return ServiceError("Der API-Key wurde nicht akzeptiert (HTTP 401). Bitte den Key in den Einstellungen prüfen.")
    if error.code == 429:
        return ServiceError("API-Limit oder Guthaben erreicht (HTTP 429). Bitte Konto prüfen oder später erneut versuchen.")
    return ServiceError(f"Der KI-Server meldet HTTP {error.code}: {detail}")


def _request(url: str, payload: dict | None = None, *, headers: dict | None = None,
             stream: bool = False, on_item: Callable | None = None,
             cancel: Any = None, timeout: float = 1800, socket_timeout: float = 120) -> Any:
    """Read in a daemon transport thread so cancellation never freezes the GUI worker."""
    _check_cancel(cancel)
    result_queue: queue.Queue = queue.Queue()
    responses: list[Any] = []
    stopped = threading.Event()
    request_headers = {"Accept": "application/x-ndjson" if stream else "application/json"}
    request_headers.update(headers or {})
    data = None
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=request_headers, method="POST" if data is not None else "GET")

    def transport() -> None:
        try:
            tls_context = None
            if url.startswith("https://"):
                try:
                    import certifi
                    tls_context = ssl.create_default_context(cafile=certifi.where())
                except ImportError:
                    tls_context = ssl.create_default_context()
            with urllib.request.urlopen(request, timeout=socket_timeout, context=tls_context) as response:
                responses.append(response)
                if stopped.is_set():
                    return
                if stream:
                    for line in response:
                        if stopped.is_set():
                            return
                        if line.strip():
                            try:
                                item = json.loads(line)
                            except ValueError as exc:
                                raise ServiceError("Der KI-Server hat ungültige Streaming-Daten gesendet.") from exc
                            result_queue.put(("item", item))
                    result_queue.put(("result", None))
                else:
                    raw = response.read(64 * 1024 * 1024 + 1)
                    if len(raw) > 64 * 1024 * 1024:
                        raise ServiceError("Die Antwort des KI-Servers ist unerwartet groß.")
                    result_queue.put(("result", json.loads(raw)))
        except urllib.error.HTTPError as exc:
            result_queue.put(("error", _http_error(exc)))
        except (urllib.error.URLError, TimeoutError, socket.timeout, ConnectionError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            result_queue.put(("error", ServiceError(f"Der KI-Server ist nicht erreichbar oder antwortet zu langsam: {reason}")))
        except BaseException as exc:
            result_queue.put(("error", exc if isinstance(exc, ServiceError) else ServiceError(f"Die KI-Antwort konnte nicht verarbeitet werden: {exc}")))

    def stop_transport() -> None:
        stopped.set()
        # Closing in another daemon avoids waiting for a buffered socket read lock.
        if responses:
            def close_response() -> None:
                try:
                    response = responses[0]
                    raw_socket = getattr(getattr(getattr(response, "fp", None), "raw", None), "_sock", None)
                    if raw_socket:
                        raw_socket.shutdown(socket.SHUT_RDWR)
                    response.close()
                except (OSError, AttributeError):
                    pass
            threading.Thread(target=close_response, daemon=True).start()

    threading.Thread(target=transport, daemon=True, name="SyllaBeatHTTP").start()
    deadline = time.monotonic() + timeout
    try:
        while True:
            _check_cancel(cancel)
            if time.monotonic() >= deadline:
                raise ServiceError("Zeitlimit für die KI-Anfrage erreicht. Bitte ein kleineres Modell wählen oder erneut versuchen.")
            try:
                kind, value = result_queue.get(timeout=0.1)
            except queue.Empty:
                continue
            if kind == "error":
                raise value
            if kind == "result":
                return value
            if on_item:
                on_item(value)
    except BaseException:
        stop_transport()
        raise


def _model_present(model: str, available: list[str]) -> bool:
    canonical = model if ":" in model.rsplit("/", 1)[-1] else model + ":latest"
    return any(item == model or item == canonical for item in available)


def _context_options(prompt: str, image_count: int = 0) -> dict:
    """Budget context explicitly; Ollama's default 4k truncates full-song analyses."""
    # German text, JSON punctuation and random clip IDs tokenize differently.
    # This byte-based allowance is deliberately conservative and includes images.
    input_allowance = math.ceil(len(prompt.encode("utf-8")) / 2.5) + max(0, image_count) * 1024 + 512
    output_allowance = 8192 if input_allowance > 6000 else 4096
    required = input_allowance + output_allowance
    for capacity in (8192, 16384, 32768):
        if required <= capacity:
            return {"temperature": 0.2, "num_ctx": capacity, "num_predict": output_allowance}
    raise ServiceError(
        "Der Analyseprompt ist für eine sichere Anfrage mit 32.768 Kontext-Tokens zu groß. "
        "Bitte die Regie abschnittsweise über den ChatGPT-Prompt erstellen oder die Clip-Beschreibungen kürzen. "
        "Die Anfrage wurde angehalten, damit keine Beats oder Anweisungen abgeschnitten werden."
    )


class OllamaManager:
    def __init__(self, base_url: str = "http://localhost:11434"):
        parsed = urllib.parse.urlparse(base_url.rstrip("/"))
        if parsed.scheme != "http" or parsed.hostname not in ("localhost", "127.0.0.1", "::1") or parsed.username or parsed.password or parsed.path not in ("", "/"):
            raise ValueError("Ollama muss über eine lokale HTTP-Adresse erreichbar sein, z. B. http://localhost:11434.")
        self.base_url = base_url.rstrip("/")
        self._process: subprocess.Popen | None = None
        self._log = None
        self._startup_lock = threading.Lock()

    @staticmethod
    def find_binary() -> Path | None:
        candidates: list[Path] = []
        if os.environ.get("VC_OLLAMA"):
            candidates.append(Path(os.environ["VC_OLLAMA"]).expanduser())
        if os.environ.get("VC_BIN_DIR"):
            candidates.append(Path(os.environ["VC_BIN_DIR"]).expanduser() / "ollama")
        if getattr(sys, "_MEIPASS", None):
            bundle = Path(sys._MEIPASS)
            candidates.extend([bundle / "bin/ollama", bundle / "Resources/bin/ollama"])
        executable = Path(sys.executable).resolve()
        root = Path(__file__).resolve().parent.parent
        candidates.extend([
            executable.parent.parent / "Resources/bin/ollama",
            executable.parent / "bin/ollama",
            root / "assets/bin/ollama", root / "bin/ollama", root / "runtime/bin/ollama",
            root / "vendor/ollama/ollama",
            Path("/Applications/Ollama.app/Contents/Resources/ollama"),
            Path("/opt/homebrew/bin/ollama"),
            Path("/usr/local/bin/ollama"),
        ])
        return next((candidate for candidate in candidates if candidate.is_file() and os.access(candidate, os.X_OK)), None)

    def _tags(self, cancel: Any = None) -> list[str]:
        result = _request(self.base_url + "/api/tags", cancel=cancel, timeout=4, socket_timeout=3)
        if not isinstance(result, dict) or not isinstance(result.get("models"), list):
            raise ServiceError("An dieser Adresse läuft kein kompatibler Ollama-Server.")
        return [str(item.get("name", item.get("model", ""))) for item in result["models"] if isinstance(item, dict)]

    def ensure_running(self, progress: Callable | None = None, cancel: Any = None) -> None:
        _check_cancel(cancel)
        try:
            self._tags(cancel)
            return
        except ServiceError:
            pass
        with self._startup_lock:
            _check_cancel(cancel)
            try:
                self._tags(cancel)
                return
            except ServiceError:
                pass
            if self._process and self._process.poll() is None:
                raise ServiceError("Die verwaltete Ollama-Laufzeit läuft, antwortet aber nicht. Bitte die App neu starten.")
            binary = self.find_binary()
            if binary is None:
                raise ServiceError("Die mitgelieferte Ollama-Laufzeit fehlt. Bitte das vollständige SyllaBeat.app-Paket verwenden.")
            _progress(progress, "Lokale Ollama-Laufzeit wird gestartet …")
            env = os.environ.copy()
            parsed = urllib.parse.urlparse(self.base_url)
            host = "[::1]" if parsed.hostname == "::1" else "127.0.0.1"
            env["OLLAMA_HOST"] = f"{host}:{parsed.port or 11434}"
            model_dir = models_dir() / "ollama"
            model_dir.mkdir(parents=True, exist_ok=True)
            env["OLLAMA_MODELS"] = str(model_dir)
            # Official Ollama distributions keep Metal/MLX libraries next to the executable.
            native_dirs = [binary.parent, binary.parent / "lib", binary.parent / "lib/ollama"]
            existing_dirs = [str(path) for path in native_dirs if path.is_dir()]
            env["DYLD_LIBRARY_PATH"] = ":".join(existing_dirs + ([env["DYLD_LIBRARY_PATH"]] if env.get("DYLD_LIBRARY_PATH") else []))
            env["OLLAMA_LIBRARY_PATH"] = ":".join(existing_dirs)
            env["OLLAMA_NOHISTORY"] = "1"
            env["OLLAMA_NO_CLOUD"] = "1"
            env["OLLAMA_DEBUG_LOG_REQUESTS"] = "false"
            logs = app_support() / "logs"
            logs.mkdir(parents=True, exist_ok=True)
            self._log = (logs / "ollama.log").open("ab")
            try:
                self._process = subprocess.Popen([str(binary), "serve"], env=env, cwd=binary.parent, stdin=subprocess.DEVNULL, stdout=self._log, stderr=self._log, start_new_session=True)
            except OSError as exc:
                self._log.close()
                self._log = None
                raise ServiceError(f"Ollama konnte nicht gestartet werden: {exc}") from exc
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                _check_cancel(cancel)
                if self._process.poll() is not None:
                    raise ServiceError("Die Ollama-Laufzeit wurde unerwartet beendet. Details stehen unter Application Support/SyllaBeat/logs/ollama.log.")
                try:
                    self._tags(cancel)
                    return
                except ServiceError:
                    time.sleep(0.2)
            self.close()
            raise ServiceError("Ollama konnte innerhalb von 45 Sekunden nicht gestartet werden.")

    def list_models(self) -> list[str]:
        return self._tags()

    def pull_model(self, model: str, progress: Callable | None = None, cancel: Any = None) -> None:
        self.ensure_running(progress, cancel)
        model = model.strip()
        if not model or len(model) > 200:
            raise ValueError("Bitte einen gültigen Ollama-Modellnamen eingeben.")
        _progress(progress, f"Modell {model} wird geladen. Dieser einmalige Download kann mehrere GB umfassen …")
        previous = [None]
        done = [False]

        def on_item(item: dict) -> None:
            if item.get("error"):
                raise ServiceError(f"Modelldownload fehlgeschlagen: {item['error']}")
            status = str(item.get("status", "Modell wird geladen"))
            completed, total = item.get("completed", 0), item.get("total", 0)
            if total:
                status += f" · {completed / total * 100:.0f}% ({completed / 1e9:.2f}/{total / 1e9:.2f} GB)"
            if status != previous[0]:
                _progress(progress, status)
                previous[0] = status
            if item.get("status") == "success":
                done[0] = True

        _request(self.base_url + "/api/pull", {"model": model, "stream": True}, stream=True, on_item=on_item, cancel=cancel, timeout=6 * 3600, socket_timeout=300)
        if not done[0]:
            raise ServiceError("Der Modelldownload endete ohne Erfolgsbestätigung. Ein erneuter Download setzt vorhandene Teile fort.")

    def generate(self, prompt: str, model: str, schema: dict | None = None,
                 images: list[str] | None = None, progress: Callable | None = None,
                 cancel: Any = None) -> str:
        model = model.strip()
        if not model:
            raise ValueError("Bitte ein Ollama-Modell auswählen.")
        options = _context_options(prompt, len(images or []))
        self.ensure_running(progress, cancel)
        if not _model_present(model, self._tags(cancel)):
            self.pull_model(model, progress, cancel)
        _progress(progress, f"{model} analysiert die Anfrage …")
        payload: dict[str, Any] = {"model": model, "prompt": prompt, "stream": True, "keep_alive": "5m", "options": options}
        if schema:
            payload["format"] = schema
        if images:
            payload["images"] = images
        chunks: list[str] = []
        answer_size = [0]
        done = [False]

        def on_item(item: dict) -> None:
            if item.get("error"):
                raise ServiceError(f"Ollama: {item['error']}")
            if isinstance(item.get("response"), str):
                answer_size[0] += len(item["response"])
                if answer_size[0] > 16 * 1024 * 1024:
                    raise ServiceError("Die Modellantwort ist zu groß. Bitte den Song abschnittsweise planen.")
                chunks.append(item["response"])
            if item.get("done"):
                done[0] = True
                if item.get("done_reason") == "length":
                    raise ServiceError("Die Modellantwort wurde wegen des Ausgabelimits abgeschnitten. Bitte den Song abschnittsweise planen.")

        _request(self.base_url + "/api/generate", payload, stream=True, on_item=on_item, cancel=cancel, timeout=3600, socket_timeout=600)
        if not done[0]:
            raise ServiceError("Die Verbindung zu Ollama endete vor der vollständigen Antwort.")
        answer = "".join(chunks).strip()
        if not answer:
            raise ServiceError("Ollama hat eine leere Antwort zurückgegeben.")
        return answer

    def close(self) -> None:
        """Only stop the process started by this manager; never stop a user's server."""
        process, self._process = self._process, None
        if process and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=3)
        if self._log:
            self._log.close()
            self._log = None


def openai_generate(prompt: str, model: str, api_key: str, schema: dict,
                    progress: Callable | None = None, cancel: Any = None) -> str:
    if not api_key.strip():
        raise ValueError("Bitte den OpenAI-API-Key in den Einstellungen hinterlegen.")
    if not model.strip():
        raise ValueError("Bitte einen OpenAI-Modellnamen eingeben.")
    _progress(progress, f"OpenAI ({model}) erstellt den Schnittplan …")
    payload = {
        "model": model.strip(),
        "input": [{"role": "user", "content": [{"type": "input_text", "text": prompt}]}],
        "text": {"format": {"type": "json_schema", "name": "schnittplan", "strict": True, "schema": schema}},
        "store": False,
    }
    result = _request("https://api.openai.com/v1/responses", payload, headers={"Authorization": "Bearer " + api_key.strip()}, cancel=cancel, timeout=1200, socket_timeout=600)
    if not isinstance(result, dict):
        raise ServiceError("OpenAI hat kein gültiges Antwortobjekt geliefert.")
    if result.get("status") == "incomplete":
        reason = result.get("incomplete_details", {}).get("reason", "unbekannt")
        raise ServiceError(f"Die OpenAI-Antwort ist unvollständig ({reason}). Bitte den Song abschnittsweise planen.")
    if result.get("error"):
        raise ServiceError("OpenAI konnte die Anfrage nicht abschließen: " + str(result["error"].get("message", "Unbekannter Fehler")))
    texts: list[str] = []
    for output in result.get("output", []):
        for content in output.get("content", []):
            if content.get("type") == "refusal":
                raise ServiceError("OpenAI hat die Anfrage abgelehnt: " + str(content.get("refusal", "Keine Begründung")))
            if content.get("type") == "output_text":
                texts.append(content.get("text", ""))
    answer = "".join(texts).strip()
    if not answer:
        raise ServiceError("OpenAI hat keinen Schnittplan zurückgegeben.")
    return answer


VISION_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "description": {"type": "string"},
        "action": {"type": "string"},
        "motif": {"type": "string"},
        "mood": {"type": "string"},
        "tags": {"type": "array", "items": {"type": "string"}},
        "filename_suggestion": {"type": "string"},
        "moments": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["description", "action", "motif", "mood", "tags", "filename_suggestion", "moments"],
}


def _image_base64(value: Any) -> str:
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    if isinstance(value, Path):
        return base64.b64encode(value.read_bytes()).decode("ascii")
    if isinstance(value, str):
        return value.split(",", 1)[1] if value.startswith("data:") and "," in value else value
    raise ServiceError("Ein extrahiertes Vorschaubild hat ein ungültiges Format.")


def _step(progress: Callable | None, message: str, fraction: float) -> None:
    """Report a determinate step; plain one-argument callbacks stay supported."""
    if not progress:
        return
    try:
        progress(message, min(1.0, max(0.0, fraction)))
    except TypeError:
        progress(message)


def _describe_clip(clip: dict, manager: OllamaManager, model: str, frame_count: int,
                   progress: Callable | None, cancel: Any) -> dict:
    from .analysis import extract_frames
    name = Path(clip["path"]).name
    segments = [s for s in clip.get("segments", []) if isinstance(s, dict)]
    picked: list[dict] = []
    if len(segments) > 1:
        wanted = min(len(segments), max(int(frame_count), 6), 10)
        picked = [segments[round(i * (len(segments) - 1) / max(1, wanted - 1))] for i in range(wanted)] if wanted > 1 else segments[:1]
        picked = [s for n, s in enumerate(picked) if s not in picked[:n]]
    frames = extract_frames(clip, count=int(frame_count), times=[(s["start"] + s["end"]) / 2 for s in picked] or None)
    if not frames:
        raise ServiceError(f"Aus {name} konnten keine Bilder gelesen werden.")
    _check_cancel(cancel)
    images = [_image_base64(frame["image"]) for frame in frames]
    times = ", ".join(f"{float(frame['time']):.2f} s" for frame in frames)
    prompt = (
        "Du erstellst einen sachlichen Clip-Katalog für den Schnitt eines Musikvideos. "
        "Die beigefügten Bilder stammen in zeitlicher Reihenfolge aus einem einzigen Clip "
        f"(Positionen: {times}). Beschreibe ausschließlich sichtbare Inhalte auf Deutsch. "
        "Erfinde keine Handlung zwischen den Bildern und keine Identitäten oder Gefühle von Personen. "
        "description: ein kurzer prägnanter Satz zu Handlung, Motiv und visueller Stimmung; "
        "action: sichtbare Bewegung/Handlung; motif: Hauptmotiv und Umgebung; mood: visuelle Atmosphäre; "
        "moments: genau ein kurzer Satz pro Bild, in der Reihenfolge der Bilder, der nur dieses Bild beschreibt; "
        "tags: drei bis acht passende deutsche Suchbegriffe; filename_suggestion: drei bis sechs "
        "beschreibende Wörter, durch Unterstriche getrennt, ohne Dateiendung, keine Pfade. "
        "Antworte ausschließlich als JSON nach dem vorgegebenen Schema."
    )
    answer = manager.generate(prompt, model, schema=VISION_SCHEMA, images=images, progress=progress, cancel=cancel)
    try:
        vision = json.loads(answer)
    except (TypeError, ValueError) as exc:
        raise ServiceError(f"Die Bildanalyse für {name} ist kein gültiges JSON.") from exc
    if not isinstance(vision, dict) or any(not isinstance(vision.get(field), str) for field in ("description", "action", "motif", "mood", "filename_suggestion")) or not isinstance(vision.get("tags"), list) or any(not isinstance(tag, str) for tag in vision["tags"]):
        raise ServiceError(f"Die Bildanalyse für {name} hat nicht das erwartete Format.")
    if not vision["description"].strip():
        raise ServiceError(f"Die Bildanalyse für {name} enthält keine Beschreibung.")
    vision["tags"] = [tag.strip() for tag in vision["tags"] if tag.strip()][:12]
    moments = vision.get("moments")
    vision["moments"] = [str(m).strip()[:300] for m in moments] if isinstance(moments, list) else []
    if picked and len(vision["moments"]) == len(picked):
        for segment in segments:
            segment.pop("description", None)
        for segment, moment in zip(picked, vision["moments"]):
            segment["description"] = moment
        # Scenes between two described ones inherit the preceding description.
        last = ""
        for segment in segments:
            if segment.get("description"):
                last = segment["description"]
            else:
                segment["description"] = last
        clip["segments"] = segments
    clip["vision"] = vision
    clip["description"] = vision["description"].strip()
    clip["tags"] = vision["tags"]
    clip["suggested_filename"] = vision["filename_suggestion"]
    clip["vision_model"] = model
    clip["vision_frames"] = [{"time": float(frame["time"])} for frame in frames]
    clip.pop("vision_error", None)
    return clip


def analyze_vision(clips: list[dict], manager: OllamaManager, model: str = "qwen2.5vl:7b",
                   frame_count: int = 3, progress: Callable | None = None,
                   cancel: Any = None, only_missing: bool = False) -> list[dict]:
    """Describe clips one by one.

    A single unreadable clip or malformed model answer no longer discards the
    whole run: the clip keeps its previous description and receives a
    ``vision_error`` note. Only when every requested clip fails is an error raised.
    ``only_missing`` skips clips that already carry a description (resume mode).
    """
    if not 1 <= int(frame_count) <= 12:
        raise ValueError("Bitte zwischen 1 und 12 Frames pro Clip auswählen.")
    manager.ensure_running(progress, cancel)
    result = copy.deepcopy(clips)
    todo = [clip for clip in result if not (only_missing and str(clip.get("description", "")).strip())]
    if not todo:
        _step(progress, "Alle Clips haben bereits eine Beschreibung.", 1.0)
        return result
    failures: list[str] = []
    for index, clip in enumerate(todo, 1):
        _check_cancel(cancel)
        name = Path(clip["path"]).name
        _step(progress, f"Clip {index}/{len(todo)}: {name} – Vorschaubilder werden gelesen …", (index - 1) / len(todo))
        try:
            _describe_clip(clip, manager, model, frame_count, progress, cancel)
        except CancelledError:
            raise
        except (ServiceError, OSError, ValueError, RuntimeError) as exc:
            if isinstance(exc, ServiceError) and not str(exc).startswith("Die Bildanalyse") and "nicht erreichbar" in str(exc):
                raise  # The server is gone; further clips would fail the same way.
            clip["vision_error"] = str(exc)[:500]
            failures.append(f"{name}: {exc}")
            _step(progress, f"Clip {index}/{len(todo)} übersprungen: {exc}", index / len(todo))
            continue
        _step(progress, f"Clip {index}/{len(todo)}: {clip['description']}", index / len(todo))
    if len(failures) == len(todo):
        raise ServiceError("Kein Clip konnte beschrieben werden:\n" + "\n".join(failures[:5]))
    return result
