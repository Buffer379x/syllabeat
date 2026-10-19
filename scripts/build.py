"""Developer build entry point; end users open the resulting .app directly."""
from __future__ import annotations
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]


def prepare():
    os.chdir(ROOT)
    # Modern ICNS supports PNG representations directly; no Xcode toolchain is needed.
    parts=[]
    folder=ROOT/'assets/VideoCreator.iconset'
    for kind,name in [('icp4','icon_16x16.png'),('icp5','icon_32x32.png'),('ic07','icon_128x128.png'),('ic08','icon_256x256.png'),('ic09','icon_512x512.png'),('ic10','icon_512x512@2x.png')]:
        data=(folder/name).read_bytes()
        parts.append(kind.encode()+struct.pack('>I',len(data)+8)+data)
    payload=b''.join(parts)
    (ROOT/'assets/VideoCreator.icns').write_bytes(b'icns'+struct.pack('>I',len(payload)+8)+payload)
    license_root=ROOT/'assets/licenses/python'
    for dist in importlib.metadata.distributions():
        name=dist.metadata.get('Name','unknown')
        for file in dist.files or []:
            text=str(file).lower()
            if '.dist-info/' in text and ('license' in text or 'copying' in text or 'notice' in text):
                source=Path(dist.locate_file(file))
                if source.is_file():
                    dest=license_root/name/Path(file).name
                    dest.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copy2(source,dest)
    (ROOT/'assets/licenses/NOTICE.txt').write_text('Video Creator bundles shared, unmodified third-party runtimes.\nFFmpeg/ffprobe: https://ffmpeg.martin-riedl.de/ — FFmpeg https://ffmpeg.org/ (GPL v3 builds; configuration via ffmpeg -buildconf).\nOllama: https://github.com/ollama/ollama (MIT); accompanying vendor licenses are in Resources/bin.\nQt/PySide6: https://www.qt.io/ (LGPL v3/GPL v3; dynamic libraries included).\nOpenCV: Apache 2.0. librosa: ISC. MLX and MLX Whisper: MIT. OpenTimelineIO: Apache 2.0.\nModel weights are downloaded separately under their upstream licenses.\nSee individual license files in this directory and binaries.json for verified artifact sources.\n',encoding='utf-8')
    frozen=subprocess.check_output([sys.executable,'-m','pip','freeze'],text=True)
    (ROOT/'requirements.lock').write_text(frozen,encoding='utf-8')


if __name__=='__main__':
    prepare()
    environment=os.environ.copy()
    toolchain=Path('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin')
    if toolchain.is_dir():
        environment['PATH']=str(toolchain)+os.pathsep+environment.get('PATH','/usr/bin:/bin')
    environment['PYINSTALLER_CONFIG_DIR']=str(ROOT/'.build/pyinstaller-cache')
    environment['VC_DATA_DIR']=str(ROOT/'.build/build-data')
    subprocess.run([sys.executable,'-m','PyInstaller','--noconfirm','VideoCreator.spec'],env=environment,check=True)
    app=ROOT/'dist/Video Creator.app'
    subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(app)],check=True)
    stage=ROOT/'.build/dmg'
    stage.mkdir(parents=True,exist_ok=True)
    # hdiutil takes the .app directly; add Applications link and documentation in staging.
    target=stage/'Video Creator.app'
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(app,target,symlinks=True)
    link=stage/'Applications'
    if not link.exists():
        link.symlink_to('/Applications')
    shutil.copy2(ROOT/'BEDIENUNG.html',stage/'Bedienungsanleitung.html')
    subprocess.run(['/usr/bin/hdiutil','create','-volname','Video Creator','-srcfolder',str(stage),'-ov','-format','UDZO',str(ROOT/'dist/Video Creator.dmg')],check=True)
