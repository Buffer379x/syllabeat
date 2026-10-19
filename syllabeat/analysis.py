"""Media inspection and local audio analysis, with no eager ML imports.

Times are seconds. Beat and speech timing are estimates and remain editable in the UI.
The bundled ffprobe is the authority for stream timing; OpenCV decodes thumbnails.
"""
from __future__ import annotations

import base64
from collections import Counter
from difflib import SequenceMatcher
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import uuid
from typing import Callable

Progress = Callable[[str, float], None]
Cancel = Callable[[], bool]
VIDEO_EXTENSIONS = frozenset({'.mp4', '.mov', '.m4v', '.mkv', '.avi', '.webm', '.mts', '.m2ts', '.mpg', '.mpeg', '.mxf', '.wmv'})


class AnalysisError(RuntimeError):
    """An actionable, user-facing analysis failure."""


class AnalysisCancelled(AnalysisError):
    pass


def _check_cancel(cancel: Cancel | None) -> None:
    if cancel is not None and cancel():
        raise AnalysisCancelled('Analyse abgebrochen.')


def _progress(callback: Progress | None, message: str, fraction: float) -> None:
    if callback is not None:
        callback(message, min(1.0, max(0.0, fraction)))


def find_binary(name: str) -> str:
    """Find our bundled binary before considering a user installation."""
    if name not in {'ffmpeg', 'ffprobe', 'ollama'}:
        raise AnalysisError(f'Unbekanntes Hilfsprogramm: {name}')
    candidates: list[Path] = []
    explicit = os.environ.get('VC_' + name.upper())
    if explicit:
        candidates.append(Path(explicit).expanduser())
    directories: list[Path] = []
    if os.environ.get('VC_BIN_DIR'):
        directories.append(Path(os.environ['VC_BIN_DIR']).expanduser())
    if getattr(sys, '_MEIPASS', None):
        frozen = Path(sys._MEIPASS)
        directories += [frozen / 'bin', frozen / 'Resources' / 'bin', frozen.parent / 'Resources' / 'bin']
    exe = Path(sys.executable).resolve().parent
    root = Path(__file__).resolve().parent.parent
    directories += [exe / 'bin', exe.parent / 'Resources' / 'bin', root / 'bin', root / 'assets' / 'bin', root / 'runtime' / 'bin']
    candidates.extend(folder / name for folder in directories)
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate.resolve())
    installed = shutil.which(name)
    if installed:
        return installed
    raise AnalysisError(f'{name} fehlt im App-Paket. Bitte die vollständige SyllaBeat.app verwenden.')


def _run(command: list[str], cancel: Cancel | None = None, timeout: float = 120) -> bytes:
    """Run without shell, allow cancellation, and never leave a decoder running."""
    _check_cancel(cancel)
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
    except OSError as exc:
        raise AnalysisError(f'Hilfsprogramm konnte nicht gestartet werden: {exc}') from exc
    deadline = time.monotonic() + timeout
    try:
        while True:
            _check_cancel(cancel)
            if time.monotonic() > deadline:
                raise AnalysisError('Zeitüberschreitung beim Lesen der Mediendatei.')
            try:
                out, err = process.communicate(timeout=0.15)
                break
            except subprocess.TimeoutExpired:
                continue
        if process.returncode:
            detail = err.decode('utf-8', errors='replace').strip()[-1000:]
            raise AnalysisError(f'Mediendatei konnte nicht gelesen werden: {detail or "Decoder-Fehler"}')
        return out
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


def _positive(value, default=0.0) -> float:
    try:
        number = float(value)
        return number if math.isfinite(number) and number > 0 else default
    except (ValueError, TypeError):
        return default


def _rate(value) -> Fraction | None:
    try:
        rate = Fraction(str(value))
        return rate if 0 < rate <= 1000 else None
    except (ValueError, TypeError, ZeroDivisionError):
        return None


def _fingerprint(path: Path) -> str:
    stat = path.stat()
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        digest.update(stream.read(131072))
        if stat.st_size > 131072:
            stream.seek(max(131072, stat.st_size - 131072))
            digest.update(stream.read(131072))
    # The size is part of the identity; mtime is deliberately excluded for renaming/copying.
    return f'{stat.st_size}:{digest.hexdigest()}'


def _probe(path: Path, cancel: Cancel | None = None) -> dict:
    raw = _run([find_binary('ffprobe'), '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)], cancel)
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeError) as exc:
        raise AnalysisError(f'Ungültige Metadaten für {path.name}.') from exc
    if not isinstance(data, dict):
        raise AnalysisError(f'Ungültige Metadaten für {path.name}.')
    return data


def _duration_from_probe(stream: dict, container: dict) -> tuple[float, str]:
    try:
        ticks = int(stream.get('duration_ts'))
        timebase = Fraction(str(stream.get('time_base')))
        value = float(ticks * timebase)
        if value > 0 and math.isfinite(value):
            return value, 'stream_time_base'
    except (ValueError, TypeError, ZeroDivisionError):
        pass
    value = _positive(stream.get('duration'))
    if value:
        return value, 'stream_duration'
    value = _positive(container.get('duration'))
    if value:
        return value, 'container_duration'
    raise AnalysisError('Die Datei enthält keine verlässliche Dauer. Bitte in MOV oder MP4 umwandeln.')


def _vfr_sample(path: Path, cancel: Cancel | None = None) -> bool | None:
    """Sample presentation times; rate fields alone do not prove variable FPS."""
    try:
        data = json.loads(_run([find_binary('ffprobe'), '-v', 'error', '-select_streams', 'v:0',
                              '-read_intervals', '%+#121', '-show_frames', '-show_entries',
                              'frame=best_effort_timestamp_time', '-of', 'json', str(path)], cancel, 30))
        stamps = sorted({float(frame['best_effort_timestamp_time']) for frame in data.get('frames', [])
                         if _positive(frame.get('best_effort_timestamp_time'), -1) >= 0})
        gaps = [b - a for a, b in zip(stamps, stamps[1:]) if b > a]
        if len(gaps) < 5:
            return None
        middle = sorted(gaps)[len(gaps) // 2]
        # Time-base quantisation causes small alternating differences in CFR material.
        return any(abs(value - middle) > max(0.0015, middle * 0.08) for value in gaps)
    except AnalysisCancelled:
        raise
    except (AnalysisError, ValueError, KeyError, TypeError):
        return None


def scan_clips(folder, existing_clips=None, progress=None, cancel=None) -> list[dict]:
    """Inspect top-level video files, preserving catalog IDs and annotations.

    Unreadable individual files are skipped with a visible progress warning. If no
    playable file remains, an AnalysisError explains the failure. No file is changed.
    """
    directory = Path(folder).expanduser().resolve()
    if not directory.is_dir():
        raise AnalysisError('Der gewählte Videoordner existiert nicht.')
    paths = sorted((p for p in directory.iterdir() if p.is_file() and p.suffix.lower() in VIDEO_EXTENSIONS),
                   key=lambda p: p.name.casefold())
    if not paths:
        raise AnalysisError('Im gewählten Ordner wurden keine unterstützten Videoclips gefunden.')
    try:
        import cv2
    except ImportError as exc:
        raise AnalysisError('OpenCV fehlt im App-Paket. Bitte die vollständige App verwenden.') from exc
    old = list(existing_clips or [])
    by_path = {str(Path(c['path']).resolve()): c for c in old if c.get('path')}
    by_fingerprint: dict[str, list[dict]] = {}
    for clip in old:
        if clip.get('fingerprint'):
            by_fingerprint.setdefault(clip['fingerprint'], []).append(clip)
    clips, failures, used_ids = [], [], set()
    for index, path in enumerate(paths):
        _check_cancel(cancel)
        _progress(progress, f'Metadaten: {path.name}', index / len(paths))
        capture = None
        try:
            data = _probe(path, cancel)
            streams = [s for s in data.get('streams', []) if s.get('codec_type') == 'video'
                       and not s.get('disposition', {}).get('attached_pic', 0)]
            if not streams:
                raise AnalysisError('Keine Videospur vorhanden.')
            stream = streams[0]
            duration, duration_source = _duration_from_probe(stream, data.get('format', {}))
            capture = cv2.VideoCapture(str(path))
            if not capture.isOpened():
                raise AnalysisError('OpenCV kann die Videospur nicht öffnen.')
            success, image = capture.read()
            if not success or image is None:
                raise AnalysisError('Das erste Videobild lässt sich nicht decodieren.')
            opencv_fps = _positive(capture.get(cv2.CAP_PROP_FPS))
            rate = _rate(stream.get('avg_frame_rate')) or _rate(stream.get('r_frame_rate'))
            if rate is None and opencv_fps:
                rate = Fraction(opencv_fps).limit_denominator(100000)
            if rate is None:
                raise AnalysisError('Die Bildrate konnte nicht ermittelt werden.')
            width = int(_positive(stream.get('width')) or capture.get(cv2.CAP_PROP_FRAME_WIDTH))
            height = int(_positive(stream.get('height')) or capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
            if width <= 0 or height <= 0:
                raise AnalysisError('Ungültige Videoauflösung.')
            rotation = 0
            for item in stream.get('side_data_list', []):
                if 'rotation' in item:
                    rotation = int(round(float(item['rotation']))) % 360
            if not rotation:
                try:
                    rotation = int(round(float(stream.get('tags', {}).get('rotate', 0)))) % 360
                except (ValueError, TypeError):
                    pass
            fingerprint = _fingerprint(path)
            previous = by_path.get(str(path))
            if previous and previous.get('fingerprint') not in (None, fingerprint):
                previous = None  # Content replacement must invalidate old visual descriptions.
            matches = by_fingerprint.get(fingerprint, [])
            if previous is None and len(matches) == 1:
                previous = matches[0]
            if previous and previous.get('id') in used_ids:
                previous = None
            result = dict(previous or {})
            if not result.get('samples'):
                thumbnail = _thumbnail(capture, cv2, image, duration)
                if thumbnail:
                    result['samples'] = [thumbnail]
            identity = result.get('id') or uuid.uuid4().hex
            used_ids.add(identity)
            vfr = _vfr_sample(path, cancel)
            warnings = []
            if duration_source == 'container_duration':
                warnings.append('Dauer aus Container; keine separate Videospurdauer vorhanden.')
            if vfr:
                warnings.append('Variable Bildrate erkannt. Für framegenauen Schnitt CFR-Arbeitskopie verwenden.')
            elif vfr is None:
                warnings.append('Variable Bildrate konnte mit der kurzen Stichprobe nicht geprüft werden.')
            try:
                frame_count = int(stream.get('nb_frames', 0))
            except (ValueError, TypeError):
                frame_count = 0
            result.update({'id': identity, 'path': str(path), 'original_name': result.get('original_name', path.name),
                           'name': path.name, 'duration': duration, 'fps_num': rate.numerator, 'fps_den': rate.denominator,
                           'fps': float(rate), 'width': width, 'height': height,
                           'display_width': height if rotation in (90, 270) else width,
                           'display_height': width if rotation in (90, 270) else height,
                           'rotation': rotation, 'frame_count': frame_count or int(_positive(capture.get(cv2.CAP_PROP_FRAME_COUNT))),
                           'description': result.get('description', ''), 'tags': result.get('tags', []),
                           'samples': result.get('samples', []), 'fingerprint': fingerprint,
                           'duration_source': duration_source, 'is_vfr': vfr,
                           'metadata_warnings': warnings, 'codec': stream.get('codec_name', ''),
                           'size_bytes': path.stat().st_size})
            clips.append(result)
        except AnalysisCancelled:
            raise
        except (AnalysisError, OSError, ValueError, TypeError) as exc:
            failures.append(f'{path.name}: {exc}')
            _progress(progress, f'Übersprungen: {path.name} – {exc}', (index + 1) / len(paths))
        finally:
            if capture is not None:
                capture.release()
    if not clips:
        raise AnalysisError('Kein Clip konnte gelesen werden. ' + '\n'.join(failures[:5]))
    suffix = f' ({len(failures)} unlesbare Dateien übersprungen)' if failures else ''
    _progress(progress, f'{len(clips)} Clips eingelesen{suffix}.', 1)
    return clips


def _thumbnail(capture, cv2, first_image, duration: float) -> dict | None:
    """Small catalog preview from ~30 % into the clip (fade-ins make frame 0 black)."""
    image, stamp = first_image, 0.0
    try:
        capture.set(cv2.CAP_PROP_POS_MSEC, duration * 300)
        ok, frame = capture.read()
        if ok and frame is not None:
            image, stamp = frame, duration * 0.3
        height, width = image.shape[:2]
        scale = min(1.0, 320 / max(height, width))
        if scale < 1:
            image = cv2.resize(image, (max(1, round(width * scale)), max(1, round(height * scale))), interpolation=cv2.INTER_AREA)
        success, encoded = cv2.imencode('.jpg', image, [cv2.IMWRITE_JPEG_QUALITY, 72])
    except Exception:  # A preview is optional; metadata must never fail because of it.
        return None
    if not success:
        return None
    return {'time': round(min(duration, stamp), 6), 'image': base64.b64encode(encoded.tobytes()).decode('ascii')}


BEAT_GRID_MODES = {
    'every_2': 'Jeden 2. Beat behalten',
    'every_4': 'Nur Taktanfänge (jeder 4. Beat)',
    'double': 'Beats verdoppeln (Zwischenschläge)',
}


def retime_beats(beats: list[float], mode: str, duration: float, offset: float = 0.0, phase: int = 0) -> list[float]:
    """Edit-grid helpers for half/double tempo detection and latency correction.

    ``phase`` chooses which beat of a group starts the grid (e.g. downbeat 1-4).
    ``offset`` shifts every beat in seconds; results stay strictly inside the song.
    """
    clean = sorted({float(b) for b in beats if isinstance(b, (int, float)) and math.isfinite(b)})
    if mode in ('every_2', 'every_4'):
        step = 2 if mode == 'every_2' else 4
        clean = clean[phase % step::step]
    elif mode == 'double':
        doubled = []
        for a, b in zip(clean, clean[1:]):
            doubled += [a, (a + b) / 2]
        clean = doubled + clean[-1:]
    elif mode != 'shift':
        raise ValueError(f'Unbekannter Beat-Modus: {mode}')
    if not math.isfinite(offset):
        raise ValueError('Der Versatz muss eine endliche Zahl sein.')
    return [round(t + offset, 6) for t in clean if 0 < t + offset < duration]


def extract_frames(clip: dict, count: int = 3) -> list[dict]:
    """Extract bounded-size JPEGs, evenly spread over the central 60% of a clip."""
    if isinstance(count, bool) or not isinstance(count, int) or not 1 <= count <= 30:
        raise AnalysisError('Bitte zwischen 1 und 30 Vorschaubilder pro Clip wählen.')
    import cv2
    path = Path(clip['path'])
    duration = _positive(clip.get('duration'))
    if not path.is_file() or not duration:
        raise AnalysisError(f'Clip fehlt oder hat keine gültige Dauer: {path.name}')
    capture = cv2.VideoCapture(str(path))
    if not capture.isOpened():
        capture.release()
        raise AnalysisError(f'Video konnte nicht geöffnet werden: {path.name}')
    results = []
    fractions = [0.5] if count == 1 else [0.2 + 0.6 * i / (count - 1) for i in range(count)]
    try:
        for position in fractions:
            target = duration * position
            capture.set(cv2.CAP_PROP_POS_MSEC, target * 1000)
            ok, frame = capture.read()
            if not ok or frame is None:
                # A keyframe seek can land past a very short stream's last image.
                capture.set(cv2.CAP_PROP_POS_FRAMES, 0)
                ok, frame = capture.read()
            if not ok or frame is None:
                continue
            actual_ms = capture.get(cv2.CAP_PROP_POS_MSEC)
            stamp = actual_ms / 1000 if math.isfinite(actual_ms) and actual_ms >= 0 else target
            height, width = frame.shape[:2]
            scale = min(1.0, 960 / max(height, width))
            if scale < 1:
                frame = cv2.resize(frame, (max(1, round(width * scale)), max(1, round(height * scale))),
                                   interpolation=cv2.INTER_AREA)
            success, encoded = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 82])
            if success:
                results.append({'time': round(min(duration, stamp), 6),
                                'image': base64.b64encode(encoded.tobytes()).decode('ascii')})
    finally:
        capture.release()
    if not results:
        raise AnalysisError(f'Keine Vorschaubilder für {path.name} decodierbar.')
    return results


def normalize_text(text: str) -> str:
    text = unicodedata.normalize('NFKC', text).casefold()
    return ' '.join(re.findall(r'[^\W_]+', text, re.UNICODE))


def _word_tokens(text: str) -> list[str]:
    return normalize_text(text).split()


def _clean_words(segments: list[dict], duration: float) -> list[dict]:
    """Keep word times monotonic and bounded, with segment fallback when absent."""
    words, previous = [], 0.0
    for segment in segments:
        entries = segment.get('words') or []
        if not entries and str(segment.get('text', '')).strip():
            tokens = str(segment['text']).split()
            start = max(previous, min(duration, float(segment.get('start', previous))))
            end = max(start, min(duration, float(segment.get('end', start))))
            step = (end - start) / max(1, len(tokens))
            entries = [{'word': word, 'start': start + index * step, 'end': start + (index + 1) * step,
                        'probability': 0.0, 'estimated': True} for index, word in enumerate(tokens)]
        for entry in entries:
            text = str(entry.get('word', '')).strip()
            if not text:
                continue
            try:
                start = float(entry.get('start', previous))
                end = float(entry.get('end', start))
            except (ValueError, TypeError):
                continue
            if not math.isfinite(start) or not math.isfinite(end):
                continue
            start = max(previous, min(duration, max(0, start)))
            end = min(duration, max(start, end))
            previous = end
            if end <= start:
                continue
            words.append({'word': text, 'start': start, 'end': end,
                          'probability': min(1.0, max(0.0, _positive(entry.get('probability')))),
                          'estimated': bool(entry.get('estimated', False))})
    return words


def _transcript_lines(segments: list[dict], duration: float) -> list[dict]:
    words = _clean_words(segments, duration)
    lines, current = [], []
    for word in words:
        if current and (word['start'] - current[-1]['end'] > 0.9
                        or word['end'] - current[0]['start'] > 7.0 or len(current) >= 14):
            lines.append(_line(current, len(lines)))
            current = []
        current.append(word)
        if re.search(r'[.!?。！？]$', word['word']) and len(current) >= 3:
            lines.append(_line(current, len(lines)))
            current = []
    if current:
        lines.append(_line(current, len(lines)))
    return lines


def _line(words: list[dict], index: int) -> dict:
    confidence = sum(w['probability'] for w in words) / len(words)
    return {'id': f'line_{index + 1:04d}', 'start': words[0]['start'], 'end': words[-1]['end'],
            'text': ' '.join(w['word'] for w in words), 'confidence': round(confidence, 3),
            'timing_estimated': any(w['estimated'] for w in words), 'needs_review': confidence < 0.55}


def _lyrics_rows(lyrics: str) -> list[dict]:
    """Blank lines and explicit headings create user-defined song sections."""
    rows, group, label = [], 0, ''
    for raw in lyrics.splitlines():
        text = raw.strip()
        heading = re.fullmatch(r'\[([^\]]+)\]', text)
        if not text or heading:
            if rows and rows[-1]['group'] == group:
                group += 1
            if heading:
                label = heading.group(1).strip()
            elif not text:
                label = ''
            continue
        if _word_tokens(text):
            rows.append({'text': text, 'group': group, 'label': label})
    return rows


def align_lyrics(lyrics: str, segments: list[dict], duration: float) -> tuple[list[dict], float]:
    """Align supplied lines to recognised words with monotonic token matching.

    Unmatched words receive interpolated timing, flagged for review. This is text
    alignment, not forced acoustic alignment, so uncertainty is kept in the result.
    """
    rows = _lyrics_rows(lyrics)
    words = _clean_words(segments, duration)
    if not rows:
        return _transcript_lines(segments, duration), 1.0
    supplied, line_for_token = [], []
    for i, row in enumerate(rows):
        tokens = _word_tokens(row['text'])
        supplied.extend(tokens)
        line_for_token.extend([i] * len(tokens))
    recognised, recognition_to_word = [], []
    for index, word in enumerate(words):
        tokens = _word_tokens(word['word'])
        recognised.extend(tokens)
        recognition_to_word.extend([index] * len(tokens))
    matcher = SequenceMatcher(None, supplied, recognised, autojunk=False)
    anchors: dict[int, tuple[float, float]] = {}
    for block in matcher.get_matching_blocks():
        for offset in range(block.size):
            w = words[recognition_to_word[block.b + offset]]
            anchors[block.a + offset] = (w['start'], w['end'])
    quality = len(anchors) / max(1, len(supplied))
    # Anchor interpolation is monotonic and explicitly uncertain. Never invent precision.
    starts = [None] * len(supplied)
    ends = [None] * len(supplied)
    for i, (start, end) in anchors.items():
        starts[i], ends[i] = start, end
    cursor = 0
    while cursor < len(supplied):
        if starts[cursor] is not None:
            cursor += 1
            continue
        first = cursor
        while cursor < len(supplied) and starts[cursor] is None:
            cursor += 1
        left = ends[first - 1] if first else 0.0
        right = starts[cursor] if cursor < len(supplied) else duration
        step = max(0.0, right - left) / (cursor - first)
        for i in range(first, cursor):
            starts[i] = left + (i - first) * step
            ends[i] = left + (i - first + 1) * step
    lines = []
    for row_index, row in enumerate(rows):
        indices = [i for i, value in enumerate(line_for_token) if value == row_index]
        matches = sum(i in anchors for i in indices)
        confidence = matches / len(indices)
        lines.append({'id': f'line_{row_index + 1:04d}', 'start': round(float(starts[indices[0]]), 6),
                      'end': round(float(ends[indices[-1]]), 6), 'text': row['text'],
                      'confidence': round(confidence, 3), 'timing_estimated': matches != len(indices),
                      'needs_review': matches != len(indices), 'group': row['group'], 'section_label': row['label']})
    return lines, round(quality, 4)


def detect_sections(lines: list[dict], duration: float) -> list[dict]:
    """Suggest repeated lyric blocks; section identity is stable within a project.

    Explicit lyric paragraph groups take precedence. Without paragraphs, repeated
    blocks of at least two consecutive lines are detected; single-line duplicates
    do not by themselves prove that a chorus repeats.
    """
    if not lines:
        return [{'id': 'section_001', 'label': 'Instrumental', 'start': 0.0, 'end': duration,
                 'repeat_of': None}]
    texts = [normalize_text(str(line.get('text', ''))) for line in lines]
    blocks: list[tuple[int, int, str]] = []
    has_groups = any('group' in line for line in lines)
    if has_groups:
        first = 0
        for index in range(1, len(lines) + 1):
            if index == len(lines) or lines[index].get('group') != lines[first].get('group'):
                blocks.append((first, index, lines[first].get('section_label', '')))
                first = index
    else:
        # Longest non-overlapping repeated blocks win, avoiding a sequence inside itself.
        repeats: list[tuple[int, int, int]] = []
        for a in range(len(lines)):
            for b in range(a + 2, len(lines)):
                length = 0
                while b + length < len(lines) and a + length < b and texts[a + length] and texts[a + length] == texts[b + length]:
                    length += 1
                if length >= 2:
                    repeats.append((length, a, b))
        claimed: set[int] = set()
        ranges: dict[int, int] = {}
        for length, a, b in sorted(repeats, reverse=True):
            a_conflict = ranges.get(a) != length and any(i in claimed for i in range(a, a + length))
            b_conflict = ranges.get(b) != length and any(i in claimed for i in range(b, b + length))
            if a_conflict or b_conflict:
                continue
            ranges[a] = ranges[b] = length
            claimed.update(range(a, a + length))
            claimed.update(range(b, b + length))
        index = 0
        while index < len(lines):
            if index in ranges:
                end = index + ranges[index]
            else:
                end = index + 1
                while end < len(lines) and end not in ranges and lines[end]['start'] - lines[end - 1]['end'] < 3:
                    end += 1
            blocks.append((index, end, ''))
            index = end
    signatures = [tuple(texts[a:b]) for a, b, _ in blocks]
    counts = Counter(signatures)
    known: dict[tuple[str, ...], str] = {}
    sections = []
    # Partition the entire song with no overlapping sections or uncovered lead-ins.
    for index, (a, b, explicit_label) in enumerate(blocks):
        signature = signatures[index]
        repeated = counts[signature] > 1 and (b - a >= 2 or has_groups)
        identity = f'section_{index + 1:03d}'
        start = 0.0 if index == 0 else min(duration, max(0.0, float(lines[a]['start'])))
        end = duration if index == len(blocks) - 1 else min(duration, max(start, float(lines[blocks[index + 1][0]]['start'])))
        repeat_of = known.get(signature) if repeated else None
        label = explicit_label or ('Refrain (Vorschlag)' if repeated else f'Abschnitt {index + 1}')
        sections.append({'id': identity, 'label': label, 'start': start, 'end': end,
                         'repeat_of': repeat_of, 'line_ids': [line['id'] for line in lines[a:b]],
                         'needs_review': repeated})
        if repeated:
            known.setdefault(signature, identity)
    return sections


def _decode_audio(path: Path, sample_rate: int, cancel: Cancel | None = None):
    import numpy as np
    raw = _run([find_binary('ffmpeg'), '-nostdin', '-v', 'error', '-i', str(path), '-map', '0:a:0', '-vn', '-ac', '1',
                '-ar', str(sample_rate), '-f', 'f32le', '-acodec', 'pcm_f32le', 'pipe:1'], cancel, 600)
    samples = np.frombuffer(raw, dtype='<f4').copy()
    if samples.size < sample_rate // 10:
        raise AnalysisError('Die Audiodatei ist leer oder kürzer als 0,1 Sekunden.')
    if not np.all(np.isfinite(samples)):
        raise AnalysisError('Die Audiodatei enthält ungültige Audiosamples.')
    return samples


def analyze_audio(audio_path, lyrics='', whisper_model='mlx-community/whisper-small-mlx',
                  progress=None, cancel=None, beats_only=False) -> dict:
    """Decode once, estimate beats, and transcribe vocals locally on Apple Silicon."""
    path = Path(audio_path).expanduser().resolve()
    if not path.is_file():
        raise AnalysisError('Die gewählte Audiodatei existiert nicht.')
    _check_cancel(cancel)
    _progress(progress, 'Audiodatei wird decodiert …', 0.02)
    try:
        import numpy as np
        import librosa
    except ImportError as exc:
        raise AnalysisError('Die Audioanalyse fehlt im App-Paket. Bitte die vollständige App verwenden.') from exc
    metadata = _probe(path, cancel)
    audio_streams = [stream for stream in metadata.get('streams', []) if stream.get('codec_type') == 'audio']
    if not audio_streams:
        raise AnalysisError('Die gewählte Datei enthält keine Audiospur.')
    source = audio_streams[0]
    source_sample_rate = int(_positive(source.get('sample_rate'), 48000))
    source_channels = max(1, int(_positive(source.get('channels'), 2)))
    sr = 16000  # Whisper's expected sample rate, also sufficient for beat estimation.
    audio = _decode_audio(path, sr, cancel)
    duration = len(audio) / sr
    _check_cancel(cancel)
    if float(np.max(np.abs(audio))) < 1e-7:
        raise AnalysisError('Die Audiodatei enthält nur Stille; Beats und Gesang können nicht erkannt werden.')
    _progress(progress, 'Beats werden erkannt …', 0.15)
    # 128-sample hops give 8 ms timing resolution without claiming acoustic certainty.
    hop_length = 128
    onset = librosa.onset.onset_strength(y=audio, sr=sr, hop_length=hop_length)
    _check_cancel(cancel)
    tempo, frames = librosa.beat.beat_track(onset_envelope=onset, sr=sr, hop_length=hop_length,
                                          trim=False, units='frames')
    times = librosa.frames_to_time(frames, sr=sr, hop_length=hop_length)
    beats = sorted({round(float(t), 6) for t in times if 0 < float(t) < duration})
    warnings = ['Beat- und Gesangszeitstempel sind automatische Schätzwerte. Vor dem Export prüfen.']
    if not beats:
        warnings.append('Keine verlässlichen Beats erkannt. Beatliste manuell ergänzen oder anderes Audio wählen.')
    _check_cancel(cancel)
    transcribe = not beats_only and bool(whisper_model)
    if transcribe:
        _progress(progress, 'MLX Whisper wird geladen; beim ersten Mal wird das Modell heruntergeladen …', 0.4)
    model_root = os.environ.get('VC_MODEL_DIR')
    if model_root:
        cache = Path(model_root).expanduser() / 'huggingface'
        cache.mkdir(parents=True, exist_ok=True)
        os.environ.setdefault('HF_HOME', str(cache))
        os.environ.setdefault('HF_HUB_CACHE', str(Path(os.environ['HF_HOME']).expanduser() / 'hub'))
    result = {}
    if transcribe:
        try:
            import mlx_whisper
        except ImportError as exc:
            raise AnalysisError('MLX Whisper fehlt im App-Paket. Die Gesangsanalyse benötigt die Apple-Silicon-Version der App.') from exc
        try:
            result = mlx_whisper.transcribe(audio, path_or_hf_repo=whisper_model, word_timestamps=True,
                                            verbose=None, condition_on_previous_text=False,
                                            initial_prompt=lyrics[:4000].strip() or None,
                                            hallucination_silence_threshold=2.0)
        except Exception as exc:
            raise AnalysisError(f'Whisper-Analyse fehlgeschlagen. Modell und Internetverbindung beim ersten Start prüfen: {exc}') from exc
    else:
        warnings.append('Gesangstranskription ausgeschaltet. Keine gesungenen Textzeiten ermittelt.')
        if lyrics.strip():
            warnings.append('Eigene Songtexte sind nur gleichmäßig über die Dauer verteilt. Alle Textzeiten vor lyrischem Schnitt manuell korrigieren.')
    _check_cancel(cancel)
    _progress(progress, 'Textzeilen und wiederkehrende Abschnitte werden zugeordnet …', 0.9)
    segments = result.get('segments') or []
    words = _clean_words(segments, duration)
    if lyrics.strip():
        lines, alignment_quality = align_lyrics(lyrics, segments, duration)
        if alignment_quality < 0.75:
            warnings.append('Eigene Songtexte stimmen nur teilweise mit der Transkription überein. Markierte Zeilen zeitlich korrigieren.')
    else:
        lines, alignment_quality = _transcript_lines(segments, duration), None
    if transcribe and not words:
        warnings.append('Kein Gesang erkannt. Instrumentalschnitt möglich; eingefügte Textzeiten sind unbestätigt.')
    sections = detect_sections(lines, duration)
    _progress(progress, f'Audioanalyse abgeschlossen: {len(beats)} Beats, {len(lines)} Textzeilen.', 1)
    tempo_array = np.asarray(tempo).reshape(-1)
    return {'path': str(path), 'duration': duration, 'sample_rate': source_sample_rate,
            'analysis_sample_rate': sr, 'channels': source_channels, 'beats': beats, 'lines': lines,
            'sections': sections, 'words': words, 'language': result.get('language', ''),
            'tempo': float(tempo_array[0]) if tempo_array.size else 0.0,
            'alignment_quality': alignment_quality, 'warnings': warnings, 'whisper_model': whisper_model if transcribe else None,
            'transcribed': transcribe,
            'timing_resolution_ms': 1000 * hop_length / sr}
