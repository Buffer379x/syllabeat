"""Build-time only: obtain verified ARM64 media binaries and Ollama runtime."""
from __future__ import annotations

import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tarfile
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "assets/downloads"
BIN = ROOT / "assets/bin"
LICENSES = ROOT / "assets/licenses"


def download(url: str, destination: Path) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        req = urllib.request.Request(url, headers={"User-Agent": "SyllaBeat-Build/0.1"})
        with urllib.request.urlopen(req, timeout=90) as source, destination.with_suffix(destination.suffix + ".part").open("wb") as out:
            shutil.copyfileobj(source, out)
            final_url = source.url
        destination.with_suffix(destination.suffix + ".part").replace(destination)
        return final_url
    return url


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _extract_ffmpeg(name: str, archive: Path) -> None:
    with zipfile.ZipFile(archive) as z:
        candidate = next(n for n in z.namelist() if Path(n).name == name and not n.startswith("__MACOSX"))
        (BIN / name).write_bytes(z.read(candidate))
    (BIN / name).chmod(0o755)


def _verified_download(url: str, destination: Path, expected: str) -> None:
    """Download into the cache; a stale cached file with another hash is fetched again once."""
    download(url, destination)
    if _sha256(destination) != expected.lower():
        destination.unlink()
        download(url, destination)
        if _sha256(destination) != expected.lower():
            raise RuntimeError(f"Prüfsumme stimmt nicht: {destination.name}")


def ffmpeg(name: str):
    url = f"https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/{name}.zip"
    archive = CACHE / f"{name}-arm64.zip"
    archive.unlink(missing_ok=True)  # "latest" must not reuse an older cached build.
    resolved = download(url, archive)
    # The build server publishes the checksum next to each resolved artifact.
    checksum = CACHE / f"{name}.sha256"
    checksum.unlink(missing_ok=True)
    download(resolved + ".sha256", checksum)
    expected = checksum.read_text().split()[0].lower()
    actual = _sha256(archive)
    if actual != expected:
        raise RuntimeError(f"Prüfsumme stimmt nicht: {name}")
    _extract_ffmpeg(name, archive)
    return {"name": name, "url": resolved, "sha256": actual}


def _install_ollama(archive: Path) -> None:
    extracted = CACHE / "ollama-extracted"
    if extracted.exists():
        shutil.rmtree(extracted)
    extracted.mkdir(parents=True)
    with tarfile.open(archive) as t:
        t.extractall(extracted, filter="data")
    for path in extracted.rglob("*"):
        if path.is_file():
            relative = path.relative_to(extracted)
            dest = BIN / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
            if path.name == "ollama" or path.suffix == ".dylib":
                dest.chmod(0o755)


def ollama():
    release = json.load(urllib.request.urlopen("https://api.github.com/repos/ollama/ollama/releases/latest", timeout=30))
    asset = next(a for a in release["assets"] if a["name"] == "ollama-darwin.tgz")
    archive = CACHE / f"ollama-{release['tag_name']}-darwin.tgz"
    download(asset["browser_download_url"], archive)
    checksum = CACHE / f"ollama-{release['tag_name']}-sha256.txt"
    download(next(a["browser_download_url"] for a in release["assets"] if a["name"] == "sha256sum.txt"), checksum)
    expected = next(line.split()[0] for line in checksum.read_text().splitlines() if line.strip().endswith("ollama-darwin.tgz"))
    actual = _sha256(archive)
    if actual != expected:
        raise RuntimeError("Ollama-Prüfsumme stimmt nicht")
    _install_ollama(archive)
    return {"name": "ollama", "version": release["tag_name"], "url": asset["browser_download_url"], "sha256": actual}


def pinned(entry: dict) -> dict:
    """Reproduce exactly the artifact recorded in assets/binaries.json."""
    name = entry["name"]
    if name in {"ffmpeg", "ffprobe"}:
        archive = CACHE / f"{name}-arm64.zip"
        _verified_download(entry["url"], archive, entry["sha256"])
        _extract_ffmpeg(name, archive)
    elif name == "ollama":
        archive = CACHE / f"ollama-{entry['version']}-darwin.tgz"
        _verified_download(entry["url"], archive, entry["sha256"])
        _install_ollama(archive)
    else:
        raise RuntimeError(f"Unbekannter Eintrag in binaries.json: {name}")
    return entry


def pinned_or_latest(entry: dict) -> dict:
    """CI safety net: an expired pinned URL falls back to the verified latest release."""
    try:
        return pinned(entry)
    except (urllib.error.URLError, OSError) as exc:
        print(f"Warnung: {entry['name']} aus binaries.json nicht ladbar ({exc}); verwende neueste Version.", file=sys.stderr)
        return ollama() if entry["name"] == "ollama" else ffmpeg(entry["name"])


if __name__ == "__main__":
    # Default: reproduce the versions in assets/binaries.json (SHA-256 verified).
    # "--latest" fetches the newest releases and records them in binaries.json.
    # "--fallback-latest" keeps pinned versions but tolerates vanished download URLs.
    BIN.mkdir(parents=True, exist_ok=True)
    LICENSES.mkdir(parents=True, exist_ok=True)
    manifest = ROOT / "assets/binaries.json"
    use_latest = "--latest" in sys.argv[1:] or not manifest.exists()
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        if use_latest:
            results = list(pool.map(lambda f: f(), [lambda: ffmpeg("ffmpeg"), lambda: ffmpeg("ffprobe"), ollama]))
        else:
            fetch = pinned_or_latest if "--fallback-latest" in sys.argv[1:] else pinned
            results = list(pool.map(fetch, json.loads(manifest.read_text(encoding="utf-8"))))
    if use_latest:
        manifest.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(json.dumps(results, indent=2))
