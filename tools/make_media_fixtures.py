"""Erzeugt kleine Testclips für die Medientests (tests/Fixtures/media) mit ffmpeg.

Die Clips bestehen aus Farbflächen mit harten Schnitten an bekannten Frames und einem wandernden hellen Balken
(Bewegung). Sie liegen im Repository, weil AVAssetWriter auf CI-VMs ohne Hardware-Scaler hängt.

    SYLLABEAT_FFMPEG=/pfad/zu/ffmpeg python3 tools/make_media_fixtures.py tests/Fixtures/media
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

COLORS = ["0x1E5AC8", "0xDC3C28", "0x28B45A", "0xF0C828", "0x963CBE"]


def clip(ffmpeg: str, out: Path, rate: str, frames: int, cuts: list[int], *, timescale: int | None = None,
         rotation: int = 0, timecode: str | None = None, vfr: bool = False) -> dict:
    bounds = [0] + cuts + [frames]
    inputs, filters = [], []
    for index, (start, end) in enumerate(zip(bounds, bounds[1:])):
        inputs += ["-f", "lavfi", "-i", f"color=c={COLORS[index % len(COLORS)]}:s=192x108:r={rate}"]
        filters.append(f"[{index}:v]trim=end_frame={end - start},setpts=PTS-STARTPTS[s{index}]")
    count = len(bounds) - 1
    chain = "".join(f"[s{i}]" for i in range(count)) + f"concat=n={count}:v=1[c];"
    chain += "[c]drawbox=x='mod(t*100,184)':y=0:w=8:h=108:color=white:t=fill"
    if vfr:
        # Jeder dritte Frame doppelt so lang: unregelmäßige Präsentationszeiten.
        chain += f",setpts='(N+floor(N/3))/({rate})/TB'"
    chain += ",format=yuv420p[v]"
    command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *inputs, "-filter_complex"]
    command += [";".join(filters) + ";" + chain, "-map", "[v]", "-c:v", "libx264", "-preset", "veryfast",
                "-crf", "30", "-g", "12", "-bf", "0"]
    if vfr:
        command += ["-fps_mode", "passthrough"]
    if timescale:
        command += ["-video_track_timescale", str(timescale)]
    if timecode:
        command += ["-timecode", timecode]
    command.append(str(out))
    subprocess.run(command, check=True)
    if rotation:
        rotated = out.with_suffix(".tmp.mov")
        subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-display_rotation", str(-rotation),
                        "-i", str(out), "-c", "copy", *(["-timecode", timecode] if timecode else []), str(rotated)],
                       check=True)
        rotated.replace(out)
    num, den = (rate.split("/") + ["1"])[:2]
    return {"file": out.name, "fps_num": int(num), "fps_den": int(den), "frames": frames, "cuts": cuts,
            "rotation": rotation, "timecode": timecode, "vfr": vfr}


def main(folder: Path) -> None:
    ffmpeg = os.environ.get("SYLLABEAT_FFMPEG", "ffmpeg")
    folder.mkdir(parents=True, exist_ok=True)
    entries = [
        clip(ffmpeg, folder / "schnitte-25.mov", "25", 180, [37, 80]),
        clip(ffmpeg, folder / "schnitte-23976.mov", "24000/1001", 180, [50, 101]),
        clip(ffmpeg, folder / "schnitte-50.mov", "50", 180, [77]),
        clip(ffmpeg, folder / "schnitte-5994.mov", "60000/1001", 180, [61, 143]),
        # Zeitbasis 600 wie beim iPhone: Raten müssen trotzdem exakt erkannt werden.
        clip(ffmpeg, folder / "zeitbasis600-5994.mov", "60000/1001", 150, [], timescale=600),
        clip(ffmpeg, folder / "zeitbasis600-23976.mov", "24000/1001", 150, [], timescale=600),
        clip(ffmpeg, folder / "hoch-timecode.mov", "25", 50, [], rotation=90, timecode="10:00:00:00"),
        clip(ffmpeg, folder / "vfr.mov", "30", 60, [], vfr=True),
        clip(ffmpeg, folder / "analyse.mov", "25", 150, [60]),
    ]
    (folder / "clips.json").write_text(json.dumps({"clips": entries}, indent=2, ensure_ascii=False) + "\n")
    for entry in entries:
        print(f"{entry['file']}: {(folder / entry['file']).stat().st_size} Bytes")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
