"""Offline diagnostic entry point shipped in the bundle for reproducible QA."""
from __future__ import annotations
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import traceback


def self_test(output: Path | None = None) -> int:
    report = {"ok": True, "frozen": bool(getattr(sys, "frozen", False)), "checks": {}}
    def check(name, action):
        try:
            value=action()
            report["checks"][name]={"ok":True,"result":str(value)}
        except BaseException as error:
            report["ok"]=False
            report["checks"][name]={"ok":False,"error":str(error),"detail":traceback.format_exc()}
    for name in ["PySide6.QtWidgets","PySide6.QtMultimedia","cv2","librosa","numpy","scipy","numba","opentimelineio","mlx_whisper","certifi"]:
        check(name,lambda n=name:importlib.import_module(n).__file__)
    from .analysis import find_binary,scan_clips,extract_frames,analyze_audio
    for name in ["ffmpeg","ffprobe","ollama"]:
        check(name,lambda n=name:subprocess.check_output([find_binary(n),"-version" if n!="ollama" else "--version"],stderr=subprocess.STDOUT,timeout=20).decode()[:250])
    with tempfile.TemporaryDirectory(prefix="videocreator-qa-") as tmp:
        folder=Path(tmp)
        def media():
            subprocess.run([find_binary("ffmpeg"),"-v","error","-f","lavfi","-i","color=c=teal:s=320x180:r=30000/1001:d=3","-an","-c:v","mpeg4",str(folder/"strand.mov")],check=True,timeout=30,capture_output=True)
            subprocess.run([find_binary("ffmpeg"),"-v","error","-f","lavfi","-i","sine=frequency=440:sample_rate=44100:duration=2","-c:a","pcm_s16le",str(folder/"song.wav")],check=True,timeout=30,capture_output=True)
            return "Video und WAV erzeugt"
        check("synthetic_media",media)
        project={}
        def pipeline():
            from .storage import new_project
            from .planning import draft_plan,compile_timeline
            from .exporters import export_xmeml,export_otio,export_fcpxml
            project.update(new_project())
            project["clips"]=scan_clips(folder)
            project["audio_path"]=str(folder/"song.wav")
            project["audio"]=analyze_audio(project["audio_path"],whisper_model="")
            project["audio"]["beats"]=[0.5,1.0,1.5]
            assert len(extract_frames(project["clips"][0],3))==3
            project["plan"]=draft_plan(project)
            tl=compile_timeline(project,project["plan"])
            assert tl["duration_frames"]==50
            for name,fn in [("timeline.xml",export_xmeml),("timeline.otio",export_otio),("timeline.fcpxml",export_fcpxml)]:
                fn(project,project["plan"],folder/name)
                assert (folder/name).stat().st_size>100
            import opentimelineio as otio
            timeline=otio.adapters.read_from_file(str(folder/"timeline.otio"))
            assert abs(timeline.duration().to_seconds()-2)<0.05
            return {"clips":len(project["clips"]),"shots":len(tl["shots"]),"duration_frames":tl["duration_frames"]}
        check("full_pipeline",pipeline)
    if os.environ.get("VC_TEST_METAL")=="1":
        def metal():
            import mlx.core as mx
            value=mx.sum(mx.array([1.0,2.0,3.0])).item()
            assert value==6.0
            return value
        check("metal",metal)
    text=json.dumps(report,ensure_ascii=False,indent=2)
    if output:
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_text(text,encoding="utf-8")
    print(text,flush=True)
    return 0 if report["ok"] else 1
