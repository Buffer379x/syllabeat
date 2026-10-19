"""Final Cut Pro 7, Final Cut Pro and OpenTimelineIO interchange exports.

All formats consume planning.compile_timeline's single absolute frame table.
No adapter or external executable is needed for the XML formats.
"""

from __future__ import annotations

import math
import os
import tempfile
import xml.etree.ElementTree as ET
from fractions import Fraction
from pathlib import Path

from .planning import PlanError, compile_timeline


def media_url(path: str | Path) -> str:
    """Encode spaces, umlauts, percent signs and URL metacharacters correctly."""
    if not path:
        raise PlanError("Ein Medienpfad fehlt.")
    return Path(path).expanduser().resolve().as_uri()


def _sub(parent: ET.Element, tag: str, value=None, **attributes) -> ET.Element:
    element = ET.SubElement(parent, tag, {k: str(v) for k, v in attributes.items()})
    if value is not None:
        element.text = str(value)
    return element


def _rate(parent: ET.Element, rate: Fraction) -> None:
    """Legacy xmeml represents integer or 1000/1001 rates, not arbitrary decimals."""
    element = _sub(parent, "rate")
    if rate.denominator == 1:
        base, ntsc = rate.numerator, False
    elif (rate * Fraction(1001, 1000)).denominator == 1:
        base, ntsc = int(rate * Fraction(1001, 1000)), True
    else:
        raise PlanError(f"FCP-7-XML kann die Bildrate {rate} nicht verlustfrei darstellen. Bitte eine Standard-Bildrate oder FCPXML/OTIO wählen.")
    _sub(element, "timebase", base)
    _sub(element, "ntsc", "TRUE" if ntsc else "FALSE")


def _timecode(parent: ET.Element, rate: Fraction) -> None:
    element = _sub(parent, "timecode")
    _rate(element, rate)
    _sub(element, "string", "00:00:00:00")
    _sub(element, "frame", 0)
    _sub(element, "displayformat", "NDF")


def _sample_video(parent: ET.Element, rate: Fraction, width: int, height: int) -> ET.Element:
    element = _sub(parent, "samplecharacteristics")
    _rate(element, rate)
    _sub(element, "width", width)
    _sub(element, "height", height)
    _sub(element, "anamorphic", "FALSE")
    _sub(element, "pixelaspectratio", "square")
    _sub(element, "fielddominance", "none")
    return element


def _write_xml(root: ET.Element, path: str | Path, doctype: str) -> Path:
    """A failed export never leaves a half-written timeline at the destination."""
    destination = Path(path).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root, space="  ")
    body = ET.tostring(root, encoding="unicode")
    payload = f'<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE {doctype}>\n{body}\n'
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=destination.parent, prefix=".timeline-", suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()
    return destination


def _source_frames(clip: dict, rate: Fraction) -> int:
    count = clip.get("frame_count")
    if isinstance(count, int) and count > 0:
        return count
    return max(1, math.floor(Fraction(str(clip["duration"])) * rate))


def export_xmeml(project: dict, plan: dict, path: str | Path) -> Path:
    """Write a version-4 xmeml sequence with V1 and linked stereo music channels."""
    timeline = compile_timeline(project, plan)
    rate = Fraction(timeline["fps_num"], timeline["fps_den"])
    root = ET.Element("xmeml", version="4")
    sequence = _sub(root, "sequence", id="sequence-1")
    _sub(sequence, "name", timeline["name"])
    _sub(sequence, "duration", timeline["duration_frames"])
    _rate(sequence, rate)
    _timecode(sequence, rate)
    _sub(sequence, "in", 0)
    _sub(sequence, "out", timeline["duration_frames"])
    media = _sub(sequence, "media")
    video = _sub(media, "video")
    video_format = _sub(video, "format")
    _sample_video(video_format, rate, timeline["width"], timeline["height"])
    track = _sub(video, "track")
    file_ids, defined_files = {}, set()
    for shot in timeline["shots"]:
        clip = shot["clip"]
        source_rate = Fraction(shot["source_fps_num"], shot["source_fps_den"])
        source_frames = _source_frames(clip, source_rate)
        item = _sub(track, "clipitem", id=shot["id"])
        _sub(item, "name", clip.get("name") or Path(clip["path"]).name)
        _sub(item, "enabled", "TRUE")
        _sub(item, "duration", source_frames)
        _rate(item, source_rate)
        _sub(item, "start", shot["start"])
        _sub(item, "end", shot["end"])
        _sub(item, "in", shot["source_in_frame"])
        _sub(item, "out", shot["source_out_frame"])
        _sub(item, "anamorphic", "FALSE")
        _sub(item, "pixelaspectratio", "square")
        _sub(item, "fielddominance", "none")
        file_id = file_ids.setdefault(clip["id"], f"video-file-{len(file_ids) + 1}")
        file = _sub(item, "file", id=file_id)
        if file_id not in defined_files:
            defined_files.add(file_id)
            _sub(file, "name", clip.get("name") or Path(clip["path"]).name)
            _sub(file, "pathurl", media_url(clip["path"]))
            _rate(file, source_rate)
            _sub(file, "duration", source_frames)
            _timecode(file, source_rate)
            file_media = _sub(file, "media")
            source_video = _sub(file_media, "video")
            _sub(source_video, "duration", source_frames)
            _sample_video(source_video, source_rate, clip.get("width", timeline["width"]), clip.get("height", timeline["height"]))
        source_track = _sub(item, "sourcetrack")
        _sub(source_track, "mediatype", "video")
        _sub(source_track, "trackindex", 1)
    _sub(track, "enabled", "TRUE")
    _sub(track, "locked", "FALSE")

    audio_data = timeline["audio"]
    audio = _sub(media, "audio")
    channels = max(1, min(2, int(audio_data.get("channels", 2))))
    _sub(audio, "channelcount", 2)
    audio_format = _sub(audio, "format")
    characteristics = _sub(audio_format, "samplecharacteristics")
    _sub(characteristics, "depth", 16)
    _sub(characteristics, "samplerate", int(audio_data.get("sample_rate") or 48000))
    outputs = _sub(audio, "outputs")
    group = _sub(outputs, "group")
    _sub(group, "index", 1)
    _sub(group, "numchannels", 2)
    _sub(group, "downmix", 0)
    for channel in (1, 2):
        _sub(_sub(group, "channel"), "index", channel)
    audio_name = Path(audio_data["path"]).name
    for channel in range(1, channels + 1):
        audio_track = _sub(audio, "track")
        item_id = f"music-channel-{channel}"
        item = _sub(audio_track, "clipitem", id=item_id)
        _sub(item, "name", audio_name)
        _sub(item, "enabled", "TRUE")
        _sub(item, "duration", timeline["duration_frames"])
        _rate(item, rate)
        for key, value in (("start", 0), ("end", timeline["duration_frames"]), ("in", 0), ("out", timeline["duration_frames"])):
            _sub(item, key, value)
        file = _sub(item, "file", id="music-file")
        if channel == 1:
            _sub(file, "name", audio_name)
            _sub(file, "pathurl", media_url(audio_data["path"]))
            _rate(file, rate)
            _sub(file, "duration", math.ceil(Fraction(str(audio_data["duration"])) * rate))
            _timecode(file, rate)
            file_media = _sub(file, "media")
            file_audio = _sub(file_media, "audio")
            sample = _sub(file_audio, "samplecharacteristics")
            _sub(sample, "depth", 16)
            _sub(sample, "samplerate", int(audio_data.get("sample_rate") or 48000))
            _sub(file_audio, "channelcount", channels)
        source = _sub(item, "sourcetrack")
        _sub(source, "mediatype", "audio")
        _sub(source, "trackindex", channel)
        for linked_channel in range(1, channels + 1):
            link = _sub(item, "link")
            _sub(link, "linkclipref", f"music-channel-{linked_channel}")
            _sub(link, "mediatype", "audio")
            _sub(link, "trackindex", linked_channel)
            _sub(link, "clipindex", 1)
            _sub(link, "groupindex", 1)
        _sub(audio_track, "enabled", "TRUE")
        _sub(audio_track, "locked", "FALSE")
        _sub(audio_track, "outputchannelindex", channel)
    return _write_xml(root, path, "xmeml")


def _time(value: Fraction | int) -> str:
    rational = Fraction(value)
    if rational.denominator == 1:
        return f"{rational.numerator}s"
    return f"{rational.numerator}/{rational.denominator}s"


def export_fcpxml(project: dict, plan: dict, path: str | Path) -> Path:
    """Write the conservative Apple FCPXML 1.6 vocabulary, readable by modern FCP.

    The primary storyline contains only video. The complete music asset is
    connected below its first shot, with offset expressed in that shot's source
    time coordinates as required by FCPXML.
    """
    timeline = compile_timeline(project, plan)
    rate = Fraction(timeline["fps_num"], timeline["fps_den"])
    frame = 1 / rate
    root = ET.Element("fcpxml", version="1.6")
    resources = _sub(root, "resources")
    _sub(resources, "format", id="timeline-format", frameDuration=_time(frame), width=timeline["width"], height=timeline["height"], fieldOrder="progressive", paspH="1", paspV="1")
    used = {}
    for shot in timeline["shots"]:
        clip = shot["clip"]
        if clip["id"] in used:
            continue
        number = len(used) + 1
        resource_id, format_id = f"video-{number}", f"format-{number}"
        used[clip["id"]] = resource_id
        source_rate = Fraction(shot["source_fps_num"], shot["source_fps_den"])
        _sub(resources, "format", id=format_id, frameDuration=_time(1 / source_rate), width=clip.get("width", timeline["width"]), height=clip.get("height", timeline["height"]), fieldOrder="progressive", paspH="1", paspV="1")
        _sub(resources, "asset", id=resource_id, name=clip.get("name") or Path(clip["path"]).name,
             src=media_url(clip["path"]), start="0s", duration=_time(Fraction(_source_frames(clip, source_rate), 1) / source_rate),
             hasVideo="1", hasAudio="0", format=format_id)
    audio = timeline["audio"]
    sample_rate = int(audio.get("sample_rate") or 48000)
    audio_duration = Fraction(round(float(audio["duration"]) * sample_rate), sample_rate)
    _sub(resources, "asset", id="music", name=Path(audio["path"]).name,
         src=media_url(audio["path"]), start="0s", duration=_time(audio_duration), hasVideo="0", hasAudio="1",
         audioSources="1", audioChannels=str(max(1, min(2, int(audio.get("channels", 2))))), audioRate=sample_rate)
    library = _sub(root, "library")
    event = _sub(library, "event", name="Video Creator")
    project_element = _sub(event, "project", name=timeline["name"])
    sequence = _sub(project_element, "sequence", format="timeline-format", duration=_time(timeline["duration_frames"] * frame), tcStart="0s", tcFormat="NDF", audioLayout="stereo", audioRate="48k")
    spine = _sub(sequence, "spine")
    for index, shot in enumerate(timeline["shots"]):
        source_rate = Fraction(shot["source_fps_num"], shot["source_fps_den"])
        source_start = Fraction(shot["source_in_frame"], 1) / source_rate
        item = _sub(spine, "asset-clip", name=shot["clip"].get("name") or Path(shot["clip"]["path"]).name,
                    ref=used[shot["clip_id"]], offset=_time(shot["start"] * frame), start=_time(source_start),
                    duration=_time(shot["duration_frames"] * frame), srcEnable="video")
        if index == 0:
            _sub(item, "asset-clip", name=Path(audio["path"]).name, ref="music", lane="-1",
                 offset=_time(source_start), start="0s", duration=_time(audio_duration), srcEnable="audio", audioRole="music")
    return _write_xml(root, path, "fcpxml")


def export_otio(project: dict, plan: dict, path: str | Path) -> Path:
    """Write native OTIO JSON; video durations remain in timeline time coordinates."""
    try:
        import opentimelineio as otio
    except ImportError as exc:
        raise PlanError("OpenTimelineIO ist in dieser App-Installation nicht verfügbar. XML-Exporte bleiben verfügbar.") from exc
    timeline_data = compile_timeline(project, plan)
    rate = timeline_data["fps"]
    rt, tr = otio.opentime.RationalTime, otio.opentime.TimeRange
    timeline = otio.schema.Timeline(name=timeline_data["name"], global_start_time=rt(0, rate))
    timeline.metadata["VideoCreator"] = {"fps_num": timeline_data["fps_num"], "fps_den": timeline_data["fps_den"], "width": timeline_data["width"], "height": timeline_data["height"]}
    audio_track = otio.schema.Track(name="Song", kind=otio.schema.TrackKind.Audio)
    video_track = otio.schema.Track(name="Video", kind=otio.schema.TrackKind.Video)
    audio = timeline_data["audio"]
    sample_rate = int(audio.get("sample_rate") or 48000)
    sample_count = round(audio["duration"] * sample_rate)
    audio_range = tr(rt(0, sample_rate), rt(sample_count, sample_rate))
    audio_ref = otio.schema.ExternalReference(target_url=media_url(audio["path"]), available_range=audio_range)
    audio_track.append(otio.schema.Clip(name=Path(audio["path"]).name, media_reference=audio_ref, source_range=audio_range))
    for shot in timeline_data["shots"]:
        source_rate = shot["source_fps_num"] / shot["source_fps_den"]
        source_start = shot["source_in_frame"] / source_rate * rate
        available = tr(rt(0, source_rate), rt(_source_frames(shot["clip"], Fraction(shot["source_fps_num"], shot["source_fps_den"])), source_rate))
        reference = otio.schema.ExternalReference(target_url=media_url(shot["clip"]["path"]), available_range=available)
        item = otio.schema.Clip(name=shot["clip"].get("name") or Path(shot["clip"]["path"]).name,
                                media_reference=reference,
                                source_range=tr(rt(source_start, rate), rt(shot["duration_frames"], rate)))
        item.metadata["VideoCreator"] = {"clip_id": shot["clip_id"], "start_beat": shot["start_beat"], "end_beat": shot["end_beat"], "source_fps_num": shot["source_fps_num"], "source_fps_den": shot["source_fps_den"]}
        video_track.append(item)
    timeline.tracks.extend([audio_track, video_track])
    destination = Path(path).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".timeline-", suffix=".otio", delete=False) as stream:
            temporary = Path(stream.name)
        otio.adapters.write_to_file(timeline, str(temporary), adapter_name="otio_json")
        os.replace(temporary, destination)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()
    return destination
