"""Liest OTIO-Exporte mit OpenTimelineIO ein und prüft die Dauern (CI, Plan Abschnitt 11).

    python3 tools/validate_otio.py <datei.otio> [<datei.otio> …]
"""
from __future__ import annotations

import sys

import opentimelineio as otio


def check(path: str) -> None:
    timeline = otio.adapters.read_from_file(path)
    audio, video = timeline.tracks[0], timeline.tracks[1]
    assert audio.kind == otio.schema.TrackKind.Audio and video.kind == otio.schema.TrackKind.Video, path
    meta = timeline.metadata["SyllaBeat"]
    rate = meta["fps_num"] / meta["fps_den"]
    frames = round(video.duration().rescaled_to(rate).value)
    song = audio.duration().to_seconds()
    assert len(video) > 0, f"{path}: keine Clips"
    for clip in video:
        reference = clip.media_reference
        assert reference.target_url.startswith("file://"), f"{path}: {reference.target_url}"
        available = reference.available_range.duration.to_seconds()
        used = clip.source_range.end_time_exclusive().to_seconds()
        assert used <= available + 1e-6, f"{path}: {clip.name} braucht {used:.3f} s, hat {available:.3f} s"
    # Bild und Song enden gemeinsam (höchstens ein Frame Rundung).
    assert abs(frames / rate - song) <= 1 / rate + 1e-6, f"{path}: Bild {frames / rate:.3f} s, Song {song:.3f} s"
    print(f"{path}: {len(video)} Clips, {frames} Frames bei {rate:g} fps, {len(video.markers)} Marker – gültig")


if __name__ == "__main__":
    for argument in sys.argv[1:]:
        check(argument)
