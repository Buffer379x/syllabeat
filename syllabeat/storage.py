"""Project persistence, Keychain access and reversible media renaming."""
from __future__ import annotations

import copy
import errno
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import APP_NAME, LEGACY_APP_NAME

KEYCHAIN_SERVICE = APP_NAME
LEGACY_KEYCHAIN_SERVICE = LEGACY_APP_NAME
RECENT_LIMIT = 8


def default_data_dir() -> Path:
    """~/Library/Application Support/SyllaBeat, migrated once from the legacy name.

    Downloaded Whisper/Ollama models can be several GB, so the legacy folder is
    renamed (same volume, instant) instead of copied or silently abandoned.
    """
    support = Path.home() / "Library/Application Support"
    current, legacy = support / APP_NAME, support / LEGACY_APP_NAME
    if not current.exists() and legacy.is_dir():
        try:
            legacy.rename(current)
        except OSError:
            return legacy
    return current


def app_support() -> Path:
    """Return the app's private, writable state directory."""
    root = Path(os.environ["VC_DATA_DIR"]) if os.environ.get("VC_DATA_DIR") else default_data_dir()
    root.mkdir(parents=True, exist_ok=True)
    return root


def recent_projects() -> list[str]:
    """Most recently used project files that still exist (newest first)."""
    try:
        data = json.loads((app_support() / "recent.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(data, list):
        return []
    return [item for item in data if isinstance(item, str) and Path(item).is_file()][:RECENT_LIMIT]


def remember_project(path: str | Path) -> list[str]:
    entry = str(Path(path).expanduser().absolute())
    items = [entry] + [item for item in recent_projects() if item != entry]
    items = items[:RECENT_LIMIT]
    try:
        _atomic_json(items, app_support() / "recent.json")
    except OSError:
        pass
    return items


def new_project() -> dict:
    return {
        "version": 1,
        "name": "Neues Musikvideo",
        "video_dir": "",
        "audio_path": "",
        "lyrics": "",
        "timeline": {"fps_num": 25, "fps_den": 1, "width": 1920, "height": 1080},
        "clips": [],
        "audio": {},
        "plan": None,
    }


def _atomic_json(value: Any, path: Path) -> None:
    path = Path(path).expanduser().absolute()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def load_project(path: str | Path) -> dict:
    path = Path(path).expanduser()
    if path.stat().st_size > 128 * 1024 * 1024:
        raise ValueError("Die Projektdatei ist größer als 128 MB und kann nicht sicher geladen werden.")

    def reject_constant(value):
        raise ValueError(f"Die Projektdatei enthält den ungültigen Zahlenwert {value}.")

    def reject_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Die Projektdatei enthält den Schlüssel {key!r} mehrfach.")
            result[key] = value
        return result

    try:
        with path.open(encoding="utf-8") as handle:
            loaded = json.load(handle, parse_constant=reject_constant, object_pairs_hook=reject_duplicates)
    except RecursionError:
        raise ValueError("Die Projektdatei ist zu tief verschachtelt.") from None
    if not isinstance(loaded, dict) or type(loaded.get("version")) is not int or loaded["version"] != 1:
        raise ValueError("Dieses Projektformat wird nicht unterstützt (erwartet: Version 1).")
    pending = [(loaded, 0)]
    while pending:
        value, depth = pending.pop()
        if depth > 128:
            raise ValueError("Die Projektdatei ist zu tief verschachtelt.")
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("Die Projektdatei enthält einen nicht endlichen Zahlenwert.")
        if isinstance(value, dict):
            pending.extend((child, depth + 1) for child in value.values())
        elif isinstance(value, list):
            pending.extend((child, depth + 1) for child in value)
    project = new_project()
    project.update(loaded)
    _validate_project(project)
    return project


def _validate_project(project: dict) -> None:
    """Validate every shape consumed directly by Qt before replacing GUI state."""
    def fail(field: str, expected: str):
        raise ValueError(f"Ungültige Projektdatei: {field} muss {expected} sein.")

    def text(value, field, *, nonempty=False, limit=4_000_000):
        if not isinstance(value, str) or len(value) > limit or "\x00" in value or (nonempty and not value.strip()):
            fail(field, "ein gültiger Text" + (" ohne Leerwert" if nonempty else ""))

    def number(value, field, minimum=0, maximum=7 * 24 * 3600, positive=False):
        if type(value) not in (int, float) or not minimum <= value <= maximum or not math.isfinite(value) or (positive and value <= 0):
            fail(field, "eine endliche Zahl im gültigen Bereich")

    def integer(value, field, minimum=1, maximum=1_000_000_000):
        if type(value) is not int or not minimum <= value <= maximum:
            fail(field, "eine ganze Zahl im gültigen Bereich")

    def array(value, field, maximum=100000):
        if not isinstance(value, list) or len(value) > maximum:
            fail(field, f"eine Liste mit höchstens {maximum} Einträgen")

    def string_list(value, field, maximum=10000):
        array(value, field, maximum)
        for item in value:
            text(item, field)

    def rate(value, field):
        if not isinstance(value, dict):
            fail(field, "ein Objekt")
        for key in ("fps_num", "fps_den"):
            integer(value.get(key), f"{field}.{key}")
        if value["fps_num"] / value["fps_den"] > 10000:
            fail(field, "eine Bildrate bis 10.000 FPS")

    for field in ("name", "video_dir", "audio_path", "lyrics"):
        text(project.get(field), field)
    timeline = project.get("timeline")
    rate(timeline, "timeline")
    for field in ("width", "height"):
        integer(timeline.get(field), f"timeline.{field}", minimum=16, maximum=16384)
    clips = project.get("clips")
    array(clips, "clips", 10000)
    identities = set()
    for index, clip in enumerate(clips):
        field = f"clips[{index + 1}]"
        if not isinstance(clip, dict):
            fail(field, "ein Clip-Objekt")
        for key in ("id", "path", "name"):
            text(clip.get(key), f"{field}.{key}", nonempty=True, limit=32768)
        if clip["id"] in identities:
            fail(f"{field}.id", "eine eindeutige Clip-ID")
        identities.add(clip["id"])
        rate(clip, field)
        number(clip.get("duration"), f"{field}.duration", positive=True)
        for key in ("width", "height"):
            integer(clip.get(key), f"{field}.{key}", maximum=131072)
        for key in ("fps", "opencv_fps"):
            if key in clip:
                number(clip[key], f"{field}.{key}", maximum=10000, positive=True)
        for key in ("frame_count", "size_bytes"):
            if key in clip:
                integer(clip[key], f"{field}.{key}", minimum=0, maximum=10 ** 16)
        for key in ("description", "original_name", "filename", "suggested_filename", "filename_suggestion", "vision_model", "codec"):
            if key in clip:
                text(clip[key], f"{field}.{key}")
        for key in ("tags", "metadata_warnings"):
            if key in clip:
                string_list(clip[key], f"{field}.{key}")
        if "vision" in clip:
            vision = clip["vision"]
            if not isinstance(vision, dict):
                fail(f"{field}.vision", "ein Objekt")
            for key in ("description", "action", "motif", "mood", "filename_suggestion"):
                if key in vision:
                    text(vision[key], f"{field}.vision.{key}")
            if "tags" in vision:
                string_list(vision["tags"], f"{field}.vision.tags")
        for key in ("samples", "vision_frames"):
            if key not in clip:
                continue
            array(clip[key], f"{field}.{key}", 100)
            for sample in clip[key]:
                if not isinstance(sample, dict):
                    fail(f"{field}.{key}", "eine Liste mit Bild-Objekten")
                number(sample.get("time"), f"{field}.{key}.time", maximum=clip["duration"] + 0.001)
                if key == "samples":
                    text(sample.get("image"), f"{field}.samples.image", nonempty=True, limit=8_000_000)
                    import base64
                    import binascii
                    try:
                        base64.b64decode(sample["image"], validate=True)
                    except (ValueError, binascii.Error):
                        fail(f"{field}.samples.image", "ein Base64-kodiertes Bild")
    audio = project.get("audio")
    if not isinstance(audio, dict):
        fail("audio", "ein Objekt")
    if audio:
        duration = audio.get("duration")
        number(duration, "audio.duration", positive=True)
        beats = audio.get("beats", [])
        array(beats, "audio.beats")
        for beat in beats:
            number(beat, "audio.beats", maximum=duration)
        for key, limit in (("lines", 50000), ("sections", 10000), ("words", 100000)):
            rows = audio.get(key, [])
            array(rows, f"audio.{key}", limit)
            row_ids = set()
            for index, row in enumerate(rows):
                field = f"audio.{key}[{index + 1}]"
                if not isinstance(row, dict):
                    fail(field, "ein Objekt mit Zeitangaben")
                number(row.get("start"), f"{field}.start", maximum=duration + 0.001)
                number(row.get("end"), f"{field}.end", minimum=row["start"], maximum=duration + 0.001)
                if key == "sections" and row["end"] <= row["start"]:
                    fail(field, "ein Abschnitt mit positiver Dauer")
                if key in ("lines", "words"):
                    text(row.get("text" if key == "lines" else "word"), field)
                if key == "sections" or "id" in row:
                    text(row.get("id"), f"{field}.id", nonempty=True)
                    if row["id"] in row_ids:
                        fail(f"{field}.id", "eine eindeutige ID")
                    row_ids.add(row["id"])
                if key == "sections":
                    text(row.get("label", ""), f"{field}.label")
                    if row.get("repeat_of") is not None:
                        text(row["repeat_of"], f"{field}.repeat_of", nonempty=True)
                for numeric in ("probability", "confidence"):
                    if numeric in row:
                        number(row[numeric], f"{field}.{numeric}", maximum=1)
            if key == "sections":
                references = {row["id"]: row.get("repeat_of") for row in rows}
                for identity, reference in references.items():
                    seen = {identity}
                    while reference:
                        if reference not in references or reference in seen:
                            fail("audio.sections.repeat_of", "ein vorhandener, zyklusfreier Abschnittsverweis")
                        seen.add(reference)
                        reference = references[reference]
        if "warnings" in audio:
            string_list(audio["warnings"], "audio.warnings")
        for key in ("sample_rate", "analysis_sample_rate", "channels"):
            if key in audio:
                integer(audio[key], f"audio.{key}")
        for key in ("tempo", "timing_resolution_ms"):
            if key in audio:
                number(audio[key], f"audio.{key}")
        if audio.get("alignment_quality") is not None:
            number(audio["alignment_quality"], "audio.alignment_quality", maximum=1)
    plan = project.get("plan")
    if plan is not None:
        if not isinstance(plan, dict) or type(plan.get("version")) is not int or plan["version"] != 1:
            fail("plan", "ein Schnittplan-Objekt der Version 1 oder null")
        array(plan.get("shots"), "plan.shots")
        for index, shot in enumerate(plan["shots"]):
            field = f"plan.shots[{index + 1}]"
            if not isinstance(shot, dict):
                fail(field, "ein Einstellungs-Objekt")
            text(shot.get("clip_id"), f"{field}.clip_id", nonempty=True)
            for key in ("start_beat", "end_beat"):
                integer(shot.get(key), f"{field}.{key}", minimum=0, maximum=100001)
            number(shot.get("source_in"), f"{field}.source_in")
    if "plan_draft" in project:
        text(project["plan_draft"], "plan_draft", limit=16_000_000)


def save_project(project: dict, path: str | Path) -> None:
    if not isinstance(project, dict) or project.get("version") != 1:
        raise ValueError("Nur Projekte der Version 1 können gespeichert werden.")
    _atomic_json(project, Path(path))


def _security(arguments: list[str]) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(["/usr/bin/security", *arguments], capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        # TimeoutExpired embeds the entire command, including -w. Never expose that exception.
        raise RuntimeError("Der macOS-Schlüsselbund antwortet nicht. Bitte den Zugriff erlauben und erneut versuchen.") from None


def keychain_get(account: str = "openai") -> str:
    """Keys stay in the macOS login Keychain and never enter a project file."""
    for service in (KEYCHAIN_SERVICE, LEGACY_KEYCHAIN_SERVICE):
        result = _security(["find-generic-password", "-s", service, "-a", account, "-w"])
        if result.returncode == 44:  # errSecItemNotFound
            continue
        if result.returncode:
            raise RuntimeError("Der macOS-Schlüsselbund konnte nicht gelesen werden. Bitte den Zugriff erlauben.")
        return result.stdout.rstrip("\n")
    return ""


def keychain_set(api_key: str, account: str = "openai") -> None:
    if not api_key:
        for service in (KEYCHAIN_SERVICE, LEGACY_KEYCHAIN_SERVICE):
            result = _security(["delete-generic-password", "-s", service, "-a", account])
            if result.returncode not in (0, 44):
                raise RuntimeError("Der API-Key konnte nicht aus dem macOS-Schlüsselbund entfernt werden.")
        return
    # The security utility receives the secret directly; no shell or application log is involved.
    result = _security(["add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", account, "-w", api_key])
    if result.returncode:
        raise RuntimeError("Der API-Key konnte nicht im macOS-Schlüsselbund gespeichert werden.")


def _filename_stem(text: str) -> str:
    text = str(text).replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "_", text).strip("_")[:72].rstrip("_") or "clip"


def rename_preview(clips: list[dict]) -> list[dict]:
    """Describe all proposed renames without touching media."""
    used: set[str] = set()
    result = []
    for index, clip in enumerate(clips, 1):
        old = Path(clip["path"]).expanduser().absolute()
        vision = clip.get("vision", {})
        if not isinstance(vision, dict):
            vision = {}
        suggestion = (
            clip.get("suggested_filename") or clip.get("filename_suggestion")
            or vision.get("filename_suggestion") or clip.get("description") or old.stem
        )
        if isinstance(suggestion, dict):
            suggestion = suggestion.get("description", old.stem)
        # Never let a model change the extension or inject a path.
        suggestion = str(suggestion)
        if Path(suggestion).suffix.lower() == old.suffix.lower():
            suggestion = Path(suggestion).stem
        stem = _filename_stem(suggestion)
        counter = index
        target = old.with_name(f"{stem}_{counter:03d}{old.suffix}")
        while str(target).casefold() in used or (target.exists() and target != old):
            counter += 1
            target = old.with_name(f"{stem}_{counter:03d}{old.suffix}")
        used.add(str(target).casefold())
        if target != old:
            result.append({"id": clip["id"], "old_path": str(old), "new_path": str(target)})
    return result


def _place_exclusive(source: Path, target: Path) -> bool:
    """Create target without overwriting. Return whether source was moved."""
    try:
        os.link(source, target)
        return False
    except OSError as error:
        # exFAT video disks do not support hard links. macOS offers an atomic,
        # no-overwrite rename specifically for this case (sys/stdio.h RENAME_EXCL).
        if sys.platform != "darwin" or error.errno not in (errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP):
            raise
        import ctypes
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        rename_exclusive = library.renamex_np
        rename_exclusive.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename_exclusive.restype = ctypes.c_int
        if rename_exclusive(os.fsencode(source), os.fsencode(target), 0x00000004):
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(target)) from None
        return True


def _apply_renames(clips: list[dict], mappings: list[dict]) -> list[dict]:
    updated = copy.deepcopy(clips)
    by_id = {str(clip["id"]): clip for clip in updated}
    if len(by_id) != len(updated):
        raise ValueError("Die Clip-IDs sind nicht eindeutig.")
    moves: list[tuple[dict, Path, Path, Path]] = []
    sources: set[str] = set()
    targets: set[str] = set()
    for mapping in mappings:
        clip = by_id.get(str(mapping["id"]))
        old, new = Path(mapping["old_path"]).absolute(), Path(mapping["new_path"]).absolute()
        if clip is None or Path(clip["path"]).absolute() != old:
            raise ValueError("Der Umbenennungsplan passt nicht mehr zum aktuellen Katalog.")
        if old.parent != new.parent:
            raise ValueError("Clips können nur innerhalb ihres bisherigen Ordners umbenannt werden.")
        if not old.is_file() or old.is_symlink():
            raise ValueError(f"Die Quelldatei fehlt oder ist ein symbolischer Link: {old.name}")
        if old == new:
            continue
        if str(old).casefold() in sources or str(new).casefold() in targets:
            raise ValueError("Der Umbenennungsplan enthält doppelte Quell- oder Zieldateien.")
        sources.add(str(old).casefold())
        targets.add(str(new).casefold())
        temporary = Path(mapping.get("staging_path", str(old.with_name(f".videocreator-rename-{uuid.uuid4().hex}{old.suffix}")))).absolute()
        if temporary.parent != old.parent or not temporary.name.startswith(".videocreator-rename-") or temporary.exists():
            raise ValueError("Der temporäre Umbenennungspfad ist ungültig oder bereits belegt.")
        moves.append((clip, old, new, temporary))
    for _, _, new, _ in moves:
        if new.exists() and str(new).casefold() not in sources:
            raise FileExistsError(f"Die Zieldatei existiert bereits: {new.name}")

    staged: list[tuple[dict, Path, Path, Path]] = []
    completed: list[tuple[dict, Path, Path, Path]] = []
    try:
        # Stage everything first, which also permits safe A->B / B->A exchanges.
        for item in moves:
            _, old, _, temporary = item
            old.rename(temporary)
            staged.append(item)
        for item in moves:
            _, _, new, temporary = item
            # A hard link fails if a competing process created the target; rename() would overwrite.
            moved = _place_exclusive(temporary, new)
            completed.append(item)
            if not moved:
                temporary.unlink()
    except BaseException as failure:
        # Move completed targets back to their staging names before restoring original names.
        rollback_errors = []
        for _, _, new, temporary in reversed(completed):
            try:
                if not temporary.exists():
                    _place_exclusive(new, temporary)
                new.unlink(missing_ok=True)
            except OSError as exc:
                rollback_errors.append(str(exc))
        for _, old, _, temporary in reversed(staged):
            try:
                if temporary.exists():
                    _place_exclusive(temporary, old)
                    temporary.unlink(missing_ok=True)
            except OSError as exc:
                rollback_errors.append(str(exc))
        if rollback_errors:
            raise RuntimeError("Umbenennen fehlgeschlagen. Einige Originalnamen konnten nicht wiederhergestellt werden: " + "; ".join(rollback_errors)) from failure
        raise
    for clip, old, new, _ in moves:
        clip.setdefault("original_name", old.name)
        clip["path"] = str(new)
        clip["name"] = new.name
        if "filename" in clip:
            clip["filename"] = new.name
    return updated


def _history_path() -> Path:
    return app_support() / "rename-history.json"


def _load_history() -> dict:
    path = _history_path()
    if not path.exists():
        return {"transactions": []}
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or not isinstance(data.get("transactions"), list):
        raise ValueError("Das Umbenennungsprotokoll ist ungültig.")
    return data


def rename_clips(clips: list[dict], mappings: list[dict]) -> list[dict]:
    if not mappings:
        return copy.deepcopy(clips)
    history = _load_history()
    changes = copy.deepcopy(mappings)
    for change in changes:
        old = Path(change["old_path"]).absolute()
        change["staging_path"] = str(old.with_name(f".videocreator-rename-{uuid.uuid4().hex}{old.suffix}"))
        change["signature"] = _file_signature(old)
    transaction = {"id": uuid.uuid4().hex, "at": datetime.now(timezone.utc).isoformat(), "changes": changes}
    # Persist every staging path and file identity before the first filesystem mutation.
    transaction["state"] = "pending"
    history["transactions"].append(transaction)
    _atomic_json(history, _history_path())
    try:
        updated = _apply_renames(clips, changes)
    except BaseException:
        transaction["state"] = "recovery_required" if any(Path(change["staging_path"]).exists() or not _signature_matches(Path(change["old_path"]), change["signature"]) for change in changes) else "failed"
        _atomic_json(history, _history_path())
        raise
    transaction["state"] = "complete"
    try:
        _atomic_json(history, _history_path())
    except BaseException:
        # A failed manifest update must not leave the caller's catalog behind the disk state.
        reverse = [{"id": m["id"], "old_path": m["new_path"], "new_path": m["old_path"]} for m in mappings]
        _apply_renames(updated, reverse)
        raise
    return updated


def _file_signature(path: Path) -> dict:
    info = path.stat()
    return {"device": info.st_dev, "inode": info.st_ino, "size": info.st_size, "mtime_ns": info.st_mtime_ns}


def _signature_matches(path: Path, signature: dict) -> bool:
    try:
        return path.is_file() and not path.is_symlink() and _file_signature(path) == signature
    except OSError:
        return False


def recover_pending_rename(clips: list[dict]) -> list[dict]:
    """Restore original filenames after interrupted transactions for this catalog.

    Only journaled files with the original filesystem identity are touched. Unknown
    or externally replaced files are never overwritten. Calling this repeatedly is safe.
    Completed transactions are retained for the normal Undo action.
    """
    updated = copy.deepcopy(clips)
    by_id = {str(clip["id"]): clip for clip in updated}
    history = _load_history()
    for transaction in reversed(history["transactions"]):
        if transaction.get("state") not in ("pending", "recovery_required"):
            continue
        changes = transaction.get("changes", [])
        if not changes or not all(isinstance(change, dict) and str(change.get("id")) in by_id for change in changes):
            continue
        if not all("staging_path" in change and isinstance(change.get("signature"), dict) for change in changes):
            continue  # Legacy journals predate crash recovery; normal Undo remains available.
        if not all(Path(by_id[str(change["id"])]["path"]).absolute() in (Path(change["old_path"]).absolute(), Path(change["new_path"]).absolute()) for change in changes):
            continue
        paths = []
        for change in changes:
            old = Path(change["old_path"]).absolute()
            new = Path(change["new_path"]).absolute()
            staging = Path(change["staging_path"]).absolute()
            if old.parent != new.parent or old.parent != staging.parent or not staging.name.startswith(".videocreator-rename-"):
                raise ValueError("Das Wiederherstellungsprotokoll enthält ungültige Pfade.")
            candidates = [candidate for candidate in (staging, old, new) if _signature_matches(candidate, change["signature"])]
            if not candidates:
                raise RuntimeError(f"Unterbrochene Umbenennung: Die Originaldatei {old.name} wurde verschoben oder verändert. Das Umbenennungsprotokoll bleibt zur manuellen Wiederherstellung erhalten.")
            if staging.exists() and not _signature_matches(staging, change["signature"]):
                raise FileExistsError(f"Wiederherstellung angehalten: Der temporäre Pfad {staging.name} ist durch eine andere Datei belegt.")
            paths.append((change, old, new, staging, candidates[0]))
        # Collect every original first so swapped names can also be recovered safely.
        for change, _, _, staging, source in paths:
            if not staging.exists():
                moved = _place_exclusive(source, staging)
                if not moved:
                    source.unlink()
        for change, old, new, _, _ in paths:
            for alias in {old, new}:
                if _signature_matches(alias, change["signature"]):
                    alias.unlink()
        # A conflicting external file may remain at an original name; keep the staged
        # originals and the pending journal instead of risking an overwrite.
        for _, old, _, _, _ in paths:
            if old.exists():
                raise FileExistsError(f"Wiederherstellung angehalten: {old.name} ist durch eine andere Datei belegt. Die Originaldatei bleibt im protokollierten Zwischenpfad erhalten.")
        for change, old, _, staging, _ in paths:
            moved = _place_exclusive(staging, old)
            if not moved:
                staging.unlink()
            clip = by_id[str(change["id"])]
            clip["path"] = str(old)
            clip["name"] = old.name
            if "filename" in clip:
                clip["filename"] = old.name
        transaction["state"] = "recovered"
        _atomic_json(history, _history_path())
    return updated


def undo_rename(clips: list[dict]) -> list[dict]:
    history = _load_history()
    by_id = {str(clip["id"]): clip for clip in clips}
    for transaction in reversed(history["transactions"]):
        if transaction.get("state") not in ("complete", "pending"):
            continue
        changes = transaction["changes"]
        if all(str(m["id"]) in by_id and Path(by_id[str(m["id"])]["path"]).absolute() == Path(m["new_path"]).absolute() for m in changes):
            reverse = [{"id": m["id"], "old_path": m["new_path"], "new_path": m["old_path"]} for m in changes]
            updated = _apply_renames(clips, reverse)
            transaction["state"] = "undone"
            try:
                _atomic_json(history, _history_path())
            except BaseException:
                _apply_renames(updated, changes)
                raise
            return updated
    raise ValueError("Für diese Clips ist keine passende Umbenennung zum Rückgängigmachen gespeichert.")
