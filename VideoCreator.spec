# Reproducible ARM64 standalone application. Build with .venv/bin/pyinstaller.
from pathlib import Path
from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs, collect_submodules, copy_metadata

root = Path(SPECPATH)
datas = [(str(root/'BEDIENUNG.html'), '.'), (str(root/'assets/licenses'), 'licenses'), (str(root/'assets/binaries.json'), '.')]
binaries = []
hiddenimports = ['PySide6.QtMultimedia', 'PySide6.QtMultimediaWidgets']
for package in ['librosa', 'mlx_whisper', 'mlx', 'opentimelineio', 'tiktoken_ext']:
    datas += collect_data_files(package)
    binaries += collect_dynamic_libs(package)
    hiddenimports += collect_submodules(package, filter=lambda name: '.tests' not in name and '.convert' not in name)
for package in ['librosa', 'mlx-whisper', 'mlx', 'opentimelineio', 'huggingface_hub', 'tiktoken', 'numpy', 'scipy', 'numba', 'scikit-learn']:
    datas += copy_metadata(package)
# Ollama locates its dynamically loaded backends relative to its executable.
# Keep the vendor directory intact in Resources; do not rewrite install names.
datas += [(str(root/'assets/bin'), 'bin')]
a = Analysis([str(root/'main.py')], pathex=[str(root)], binaries=binaries, datas=datas,
    hiddenimports=hiddenimports, hookspath=[], hooksconfig={}, runtime_hooks=[],
    excludes=['torch','torchvision','torchaudio','matplotlib','IPython','jupyter','pytest','pandas','PySide6.QtWebEngineCore','PySide6.QtWebEngineWidgets','PySide6.QtPdf'],
    noarchive=False, optimize=1)
pyz = PYZ(a.pure)
exe = EXE(pyz,a.scripts,[],exclude_binaries=True,name='Video Creator',debug=False,bootloader_ignore_signals=False,
    strip=False,upx=False,console=False,argv_emulation=False,target_arch='arm64',codesign_identity=None,entitlements_file=None)
coll = COLLECT(exe,a.binaries,a.datas,strip=False,upx=False,name='Video Creator')
app = BUNDLE(coll,name='Video Creator.app',icon=str(root/'assets/VideoCreator.icns'),bundle_identifier='de.videocreator.desktop',
    info_plist={'CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True,
    'NSHumanReadableCopyright':'Video Creator — lokale Musikvideo-Regie', 'NSPrincipalClass':'NSApplication',
    'CFBundleDocumentTypes':[{'CFBundleTypeName':'Video Creator Projekt','CFBundleTypeRole':'Editor','LSHandlerRank':'Owner','CFBundleTypeExtensions':['vcproject']} ]})
