"""Developer/CI build entry point; end users open the resulting .app or .dmg directly.

    python scripts/build.py            # build dist/SyllaBeat.app and dist/SyllaBeat-<version>.dmg
    python scripts/build.py --no-dmg   # app bundle only

The DMG step of the earlier development build failed with
"hdiutil: create failed - Ordner nicht leer" because a stale staging folder
(including a Finder .DS_Store and an older app copy) was reused. The staging
folder is now always recreated from scratch and hdiutil is retried.
"""
from __future__ import annotations

import importlib.metadata
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "SyllaBeat"


def version() -> str:
    text = (ROOT / "syllabeat/__init__.py").read_text(encoding="utf-8")
    return re.search(r'__version__\s*=\s*"([^"]+)"', text).group(1)


def build_icns() -> None:
    # Modern ICNS supports PNG representations directly; no Xcode toolchain is needed.
    parts = []
    folder = ROOT / "assets/SyllaBeat.iconset"
    for kind, name in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("ic07", "icon_128x128.png"),
                       ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")]:
        data = (folder / name).read_bytes()
        parts.append(kind.encode() + struct.pack(">I", len(data) + 8) + data)
    payload = b"".join(parts)
    (ROOT / "assets/SyllaBeat.icns").write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)


def collect_licenses() -> None:
    license_root = ROOT / "assets/licenses/python"
    for dist in importlib.metadata.distributions():
        name = dist.metadata.get("Name", "unknown")
        for file in dist.files or []:
            text = str(file).lower()
            if ".dist-info/" in text and ("license" in text or "copying" in text or "notice" in text):
                source = Path(dist.locate_file(file))
                if source.is_file():
                    dest = license_root / name / Path(file).name
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, dest)
    (ROOT / "assets/licenses/NOTICE.txt").write_text(
        "SyllaBeat bundles shared, unmodified third-party runtimes.\n"
        "FFmpeg/ffprobe: https://ffmpeg.martin-riedl.de/ — FFmpeg https://ffmpeg.org/ (GPL v3 builds; configuration via ffmpeg -buildconf).\n"
        "Ollama: https://github.com/ollama/ollama (MIT); accompanying vendor licenses are in Resources/bin.\n"
        "Qt/PySide6: https://www.qt.io/ (LGPL v3/GPL v3; dynamic libraries included).\n"
        "OpenCV: Apache 2.0. librosa: ISC. MLX and MLX Whisper: MIT. OpenTimelineIO: Apache 2.0.\n"
        "Model weights are downloaded separately under their upstream licenses.\n"
        "See individual license files in this directory and binaries.json for verified artifact sources.\n",
        encoding="utf-8")


def prepare() -> None:
    os.chdir(ROOT)
    missing = [name for name in ("ffmpeg", "ffprobe", "ollama") if not (ROOT / "assets/bin" / name).is_file()]
    if missing:
        raise SystemExit(f"Fehlende Binärdateien in assets/bin: {', '.join(missing)}. Zuerst scripts/fetch_binaries.py ausführen.")
    build_icns()
    collect_licenses()
    if not os.environ.get("CI"):
        frozen = subprocess.check_output([sys.executable, "-m", "pip", "freeze"], text=True)
        (ROOT / "requirements.lock").write_text(frozen, encoding="utf-8")


def build_app() -> Path:
    environment = os.environ.copy()
    toolchain = Path("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin")
    if toolchain.is_dir():
        environment["PATH"] = str(toolchain) + os.pathsep + environment.get("PATH", "/usr/bin:/bin")
    environment["PYINSTALLER_CONFIG_DIR"] = str(ROOT / ".build/pyinstaller-cache")
    environment["VC_DATA_DIR"] = str(ROOT / ".build/build-data")
    subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "SyllaBeat.spec"], env=environment, check=True)
    app = ROOT / f"dist/{APP_NAME}.app"
    # Ad-hoc signature; a Developer ID signature/notarisation can be added later.
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    return app


def build_dmg(app: Path) -> Path:
    stage = ROOT / ".build/dmg"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    # ditto preserves symlinks, extended attributes and the code signature.
    subprocess.run(["/usr/bin/ditto", str(app), str(stage / app.name)], check=True)
    (stage / "Applications").symlink_to("/Applications")
    shutil.copy2(ROOT / "BEDIENUNG.html", stage / "Bedienungsanleitung.html")
    target = ROOT / f"dist/{APP_NAME}-{version()}.dmg"
    target.unlink(missing_ok=True)
    command = ["/usr/bin/hdiutil", "create", "-volname", f"{APP_NAME} {version()}", "-srcfolder", str(stage),
               "-fs", "HFS+", "-format", "UDZO", "-imagekey", "zlib-level=9", "-ov", str(target)]
    for attempt in range(1, 4):
        result = subprocess.run(command)
        if result.returncode == 0:
            break
        if attempt == 3:
            raise SystemExit("hdiutil konnte das DMG nicht erstellen.")
        time.sleep(5 * attempt)  # Spotlight/XProtect occasionally keep the image busy.
    subprocess.run(["/usr/bin/hdiutil", "verify", str(target)], check=True)
    return target


if __name__ == "__main__":
    prepare()
    built = build_app()
    if "--no-dmg" not in sys.argv[1:]:
        print(build_dmg(built))
