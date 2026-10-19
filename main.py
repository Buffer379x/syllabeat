"""App entry point. The frozen executable also runs isolated analysis workers."""
from __future__ import annotations

import os
import sys
from pathlib import Path


def configure_environment():
    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    binary_dir = root / "bin" if (root / "bin").exists() else root / "assets" / "bin"
    os.environ["PATH"] = str(binary_dir) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin")
    data = Path(os.environ.get("VC_DATA_DIR", Path.home() / "Library/Application Support/Video Creator"))
    data.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("VC_MODEL_DIR", str(data / "models"))
    os.environ.setdefault("HF_HOME", str(data / "models" / "huggingface"))
    os.environ.setdefault("NUMBA_CACHE_DIR", str(data / "cache" / "numba"))
    os.environ.setdefault("MPLCONFIGDIR", str(data / "cache" / "matplotlib"))
    try:
        import certifi
        os.environ.setdefault("SSL_CERT_FILE", certifi.where())
        os.environ.setdefault("REQUESTS_CA_BUNDLE", certifi.where())
    except ImportError:
        pass


def main():
    configure_environment()
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        from videocreator.worker import run_worker
        return run_worker(Path(sys.argv[2]), Path(sys.argv[3]))
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        from videocreator.diagnostics import self_test
        return self_test(Path(sys.argv[2]) if len(sys.argv) > 2 else None)
    if len(sys.argv) > 1 and sys.argv[1] == "--ui-smoke":
        from PySide6.QtWidgets import QApplication
        from videocreator.gui import MainWindow, STYLE
        application=QApplication([])
        application.setStyle("Fusion")
        application.setStyleSheet(STYLE)
        window=MainWindow()
        window.show()
        application.processEvents()
        window.grab().save(sys.argv[2])
        return 0
    from videocreator.gui import run_app
    return run_app(sys.argv)


if __name__ == "__main__":
    # PyInstaller must divert resource-tracker/worker children before GUI startup.
    import multiprocessing
    multiprocessing.freeze_support()
    raise SystemExit(main())
