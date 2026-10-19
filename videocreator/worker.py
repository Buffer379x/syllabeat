"""JSON-file job protocol for killable, isolated analysis processes."""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import traceback


def run_worker(request_path: Path, response_path: Path) -> int:
    cancelled = False
    manager = None

    def progress(message: str, fraction: float = 0):
        print(json.dumps({"event": "progress", "message": str(message), "fraction": max(0, min(1, float(fraction)))}, ensure_ascii=False), flush=True)

    def cancel():
        return cancelled

    def interrupted(_signum, _frame):
        nonlocal cancelled
        cancelled = True
        raise InterruptedError("Aufgabe abgebrochen.")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        request = json.loads(request_path.read_text(encoding="utf-8"))
        action, p = request["action"], request.get("payload", {})
        progress("Aufgabe wird vorbereitet …", 0.01)
        if action == "scan":
            from .analysis import scan_clips
            result = scan_clips(p["folder"], p.get("clips"), progress=progress, cancel=cancel)
        elif action == "frames":
            from .analysis import extract_frames
            result = extract_frames(p["clip"], count=p.get("count", 3))
        elif action == "audio":
            from .analysis import analyze_audio
            result = analyze_audio(p["path"], p.get("lyrics", ""), p["model"], progress=progress, cancel=cancel)
        elif action == "whisper_model":
            from huggingface_hub import snapshot_download
            progress("Whisper-Modell wird heruntergeladen; bereits vorhandene Dateien werden wiederverwendet …", 0.05)
            result = {"path": snapshot_download(repo_id=p["model"], allow_patterns=["config.json", "weights.safetensors", "weights.npz", "README.md"])}
        elif action in {"vision", "direct", "pull", "models"}:
            from .services import OllamaManager, analyze_vision, openai_generate
            if action == "direct" and p.get("provider") == "OpenAI":
                from .director import generate_project_plan
                result = generate_project_plan(p["project"], lambda prompt,schema: openai_generate(prompt, p["model"], os.environ.get("VC_OPENAI_KEY", ""), schema, progress=progress, cancel=cancel), progress=progress, cancel=cancel)
            else:
                manager = OllamaManager(p.get("base_url", "http://localhost:11434"))
                manager.ensure_running(progress=progress, cancel=cancel)
                if action == "models":
                    result = manager.list_models()
                elif action == "pull":
                    result = manager.pull_model(p["model"], progress=progress, cancel=cancel)
                elif action == "vision":
                    result = analyze_vision(p["clips"], manager, p.get("model", "qwen2.5vl:7b"), p.get("frame_count", 3), progress=progress, cancel=cancel)
                else:
                    from .director import generate_project_plan
                    result = generate_project_plan(p["project"], lambda prompt,schema: manager.generate(prompt, p["model"], schema=schema, progress=progress, cancel=cancel), progress=progress, cancel=cancel)
        elif action == "normalize":
            from .analysis import find_binary, scan_clips
            import uuid
            destination = Path(p["destination"]) / ("Video Creator CFR " + uuid.uuid4().hex[:8])
            destination.mkdir(parents=True, exist_ok=False)
            clips = p["clips"]
            originals = {}
            for i, clip in enumerate(clips):
                progress(f"Arbeitskopie {i+1}/{len(clips)}: {clip['name']}", i / max(len(clips), 1))
                output = destination / (Path(clip["name"]).stem[:140] + "_cfr_" + clip["id"][:6] + ".mov")
                originals[str(output.resolve())] = clip
                if output.exists():
                    raise ValueError(f"Arbeitskopie existiert bereits: {output.name}")
                process = subprocess.Popen([find_binary("ffmpeg"), "-v", "error", "-nostdin", "-i", clip["path"], "-map", "0:v:0", "-an", "-vf", f"fps={p['fps_num']}/{p['fps_den']}", "-c:v", "prores_ks", "-profile:v", "1", "-pix_fmt", "yuv422p10le", str(output)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                try:
                    _, error = process.communicate()
                    if process.returncode:
                        raise RuntimeError(error.decode(errors="replace")[-2000:])
                except BaseException:
                    process.kill()
                    process.wait()
                    output.unlink(missing_ok=True)
                    raise
            converted = scan_clips(str(destination), progress=progress, cancel=cancel)
            for clip in converted:
                original=originals[clip["path"]]
                for field in ["id","original_name","description","tags","vision","suggested_filename","vision_model","vision_frames"]:
                    if field in original:
                        clip[field]=original[field]
                clip["source_path"]=original["path"]
            result = {"clips":converted,"folder":str(destination)}
        elif action == "export":
            from .exporters import export_xmeml, export_otio, export_fcpxml
            project, plan = p["project"], p["project"]["plan"]
            destination = Path(p["destination"])
            destination.mkdir(parents=True, exist_ok=True)
            result = []
            for name, function in [("timeline.xml", export_xmeml), ("timeline.otio", export_otio), ("timeline.fcpxml", export_fcpxml)]:
                if name in p["formats"]:
                    progress(f"Exportiere {name} …", len(result) / max(1, len(p["formats"])))
                    function(project, plan, destination / name)
                    result.append(str(destination / name))
            for name, value in [("clip-katalog.json", project["clips"]), ("schnittplan.json", plan)]:
                (destination / name).write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
        else:
            raise ValueError(f"Unbekannte Aufgabe: {action}")
        if cancelled:
            raise InterruptedError("Aufgabe abgebrochen.")
        response = {"ok": True, "result": result}
        code = 0
    except BaseException as error:
        response = {"ok": False, "error": str(error) or error.__class__.__name__, "detail": traceback.format_exc()}
        code = 1
    finally:
        if manager is not None:
            try:
                manager.close()
            except Exception:
                pass
        request_path.unlink(missing_ok=True)
    temporary = response_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(response, ensure_ascii=False), encoding="utf-8")
    temporary.replace(response_path)
    return code
