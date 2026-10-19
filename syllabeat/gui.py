"""German desktop interface. Native file dialogs, isolated jobs, editable analyses."""
from __future__ import annotations

import base64
import copy
import json
from pathlib import Path
import sys
import time
import uuid

from PySide6.QtCore import Qt, QProcess, QProcessEnvironment, QSize, QTimer, QUrl, QEvent
from PySide6.QtGui import QAction, QColor, QDesktopServices, QFont, QIcon, QKeySequence, QPixmap
from PySide6.QtWidgets import (
    QGridLayout, QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog,
    QFormLayout, QFrame, QHBoxLayout, QHeaderView, QLabel, QLineEdit, QListWidget,
    QMainWindow, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QDoubleSpinBox, QSpinBox, QSplitter, QStackedWidget, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)

from . import APP_NAME, LEGACY_PROJECT_SUFFIXES, PROJECT_SUFFIX, __version__
from .analysis import BEAT_GRID_MODES, VIDEO_EXTENSIONS, retime_beats
from .storage import app_support, models_dir, default_cut_style, new_project, load_project, save_project, keychain_get, keychain_set, rename_preview, rename_clips, undo_rename, recover_pending_rename, recent_projects, remember_project
from .planning import validate_plan, apply_repeats, compile_timeline, draft_plan
from .director import build_prompt_parts, merge_plan_parts


STYLE = """
QWidget { background:#101419; color:#e7edf4; font-family:'Helvetica Neue'; font-size:13px; }
QMainWindow { background:#101419; }
QLabel { background:transparent; }
QLabel#title { font-size:27px; font-weight:700; letter-spacing:-0.7px; }
QLabel#subtitle { color:#93a3b5; font-size:13px; }
QLabel#eyebrow { color:#70dec4; font-size:10px; font-weight:700; letter-spacing:2px; }
QLabel#brand { font-size:20px; font-weight:700; }
QLabel#cardtitle { font-size:14px; font-weight:700; color:#e7edf4; }
QLabel#path { color:#93a3b5; font-size:12px; }
QLabel#step { color:#70dec4; font-size:11px; font-weight:700; }
QFrame#sidebar { background:#151c24; border-right:1px solid #293341; }
QFrame#card { background:#17202a; border:1px solid #2a3746; border-radius:14px; }
QFrame#card QLabel { background:transparent; }
QFrame#card QLineEdit, QFrame#card QSpinBox, QFrame#card QComboBox { background:#111820; }
QPushButton { background:#243040; border:1px solid #384a5f; border-radius:8px; padding:9px 14px; font-weight:500; }
QPushButton:hover { background:#304157; border-color:#70859c; }
QPushButton:pressed { background:#1c2834; }
QPushButton:disabled { color:#647385; background:#1a222c; border-color:#293340; }
QPushButton#primary { background:#76dfc3; color:#0b2922; border-color:#76dfc3; font-weight:700; padding:9px 18px; }
QPushButton#primary:hover { background:#9aeed8; }
QPushButton#primary:disabled { background:#284c43; color:#75978d; border-color:#284c43; }
QLineEdit, QPlainTextEdit, QSpinBox, QComboBox { background:#151c24; border:1px solid #344456; border-radius:6px; padding:8px; selection-background-color:#347a6b; }
QLineEdit:focus, QPlainTextEdit:focus, QSpinBox:focus, QComboBox:focus { border-color:#76dfc3; }
QPlainTextEdit { font-size:12px; }
QComboBox::drop-down { border:0; width:25px; }
QComboBox QAbstractItemView { background:#1e2936; selection-background-color:#34554f; }
QListWidget { border:0; background:transparent; outline:0; }
QListWidget::item { padding:14px 12px; margin:3px 0; border-radius:7px; color:#9daec0; }
QListWidget::item:selected { background:#263d3b; color:#94efd7; }
QListWidget::item:hover { background:#23313f; }
QTableWidget { background:#151c24; alternate-background-color:#19232e; gridline-color:#293747; border:1px solid #2b3949; border-radius:7px; selection-background-color:#294c47; }
QHeaderView::section { background:#202c39; color:#acbccc; border:0; border-right:1px solid #344354; padding:9px; font-size:11px; font-weight:600; }
QTableWidget::item { padding:6px; }
QScrollArea { border:0; }
QProgressBar { background:#23313e; border:0; border-radius:3px; height:6px; text-align:center; }
QProgressBar::chunk { background:#76dfc3; border-radius:3px; }
QCheckBox { spacing:8px; background:transparent; }
QCheckBox::indicator { width:16px; height:16px; border:1px solid #516276; border-radius:4px; background:#19222d; }
QCheckBox::indicator:checked { background:#76dfc3; border-color:#76dfc3; }
QSplitter::handle { background:#293747; }
QMenuBar, QMenu { background:#19232e; }
QMenu::item:selected { background:#294c47; }
QToolTip { background:#253442; color:#ecf5fa; border:1px solid #567066; padding:5px; }
QFrame#footer { background:#121820; border-top:1px solid #293341; }
QFrame#dropzone { background:#16202a; border:1px dashed #3d5266; border-radius:10px; }
QLabel#badge { background:#203a36; color:#94efd7; border-radius:9px; padding:3px 9px; font-size:11px; font-weight:600; }
QLabel#warn { color:#f0c674; font-size:12px; }
QLineEdit#search { padding:7px 10px; }
"""

AUDIO_EXTENSIONS = frozenset({".mp3", ".wav", ".aiff", ".aif", ".m4a", ".flac", ".ogg", ".aac", ".opus"})
PROJECT_SUFFIXES = (PROJECT_SUFFIX, *LEGACY_PROJECT_SUFFIXES)
PROJECT_FILTER = f"{APP_NAME}-Projekt (*{PROJECT_SUFFIX} " + " ".join(f"*{s}" for s in LEGACY_PROJECT_SUFFIXES) + " *.json)"
FORMAT_PRESETS = [
    ("Full HD · 16:9", 1920, 1080), ("4K UHD · 16:9", 3840, 2160), ("HD 720p · 16:9", 1280, 720),
    ("Hochformat · 9:16 (Reels/TikTok)", 1080, 1920), ("Quadrat · 1:1", 1080, 1080), ("Kino · 2,39:1", 1920, 804),
]
STEPS = ["Medien", "Clip-Katalog", "Songanalyse", "KI-Regie", "Schnitt & Export"]


def label(text, name=None, wrap=True):
    widget = QLabel(text)
    if name:
        widget.setObjectName(name)
    widget.setWordWrap(wrap)
    return widget


def button(text, callback, primary=False):
    widget = QPushButton(text)
    if primary:
        widget.setObjectName("primary")
    widget.clicked.connect(callback)
    return widget


def table(headers):
    widget = QTableWidget(0, len(headers))
    widget.setHorizontalHeaderLabels(headers)
    widget.setAlternatingRowColors(True)
    widget.verticalHeader().hide()
    widget.verticalHeader().setDefaultSectionSize(38)
    widget.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
    widget.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
    return widget


def set_rows(widget, rows, readonly=False):
    widget.blockSignals(True)
    widget.setRowCount(len(rows))
    for row, values in enumerate(rows):
        for column, value in enumerate(values):
            item = QTableWidgetItem(str(value))
            if readonly:
                item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEditable)
            widget.setItem(row, column, item)
    widget.blockSignals(False)


def cell(widget, row, column):
    item = widget.item(row, column)
    return item.text().strip() if item else ""


def app_icon():
    """The bundle's own .icns is the single source of truth inside the app.

    Setting a different (painted) icon at start-up made the Dock icon change
    right after launch, so the packaged app sets none. From source we load the
    same artwork the .icns is built from.
    """
    if getattr(sys, "frozen", False):
        return QIcon()
    png = Path(__file__).resolve().parents[1] / "assets/icon-1024.png"
    return QIcon(str(png)) if png.is_file() else QIcon()


def logo_pixmap(size):
    png = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1])) / "assets/icon-1024.png"
    if not png.is_file():
        png = Path(__file__).resolve().parents[1] / "assets/icon-1024.png"
    pixmap = QPixmap(str(png)) if png.is_file() else QPixmap()
    return pixmap.scaled(size, size, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation) if not pixmap.isNull() else pixmap


def card(title=None, hint=None):
    """A rounded group box; returns (frame, layout)."""
    frame = QFrame()
    frame.setObjectName("card")
    layout = QVBoxLayout(frame)
    layout.setContentsMargins(18, 16, 18, 16)
    layout.setSpacing(10)
    if title:
        layout.addWidget(label(title, "cardtitle"))
    if hint:
        layout.addWidget(label(hint, "subtitle"))
    return frame, layout


# Approximate download sizes (GB) shown before a download starts.
MODEL_SIZES = {
    "qwen2.5vl:3b": 3.2, "qwen2.5vl:7b": 6.0, "qwen2.5vl:32b": 21.0, "qwen2.5:3b": 1.9, "qwen2.5:7b": 4.7,
    "qwen2.5:14b": 9.0, "llama3.2-vision:11b": 7.8, "gemma3:4b": 3.3, "gemma3:12b": 8.1,
    "mlx-community/whisper-tiny": 0.08, "mlx-community/whisper-small-mlx": 0.5, "mlx-community/whisper-large-v3-turbo": 1.6,
}


def model_size_hint(model, config=None):
    import shutil
    model = model.strip()
    size = MODEL_SIZES.get(model) or MODEL_SIZES.get(model + ":latest")
    try:
        free = shutil.disk_usage(models_dir(config)).free / 1e9
    except OSError:
        free = None
    parts = [f"Download ca. {size:.1f} GB" if size else "Downloadgröße unbekannt"]
    if free is not None:
        parts.append(f"frei: {free:.0f} GB")
    warning = " – zu wenig freier Speicher!" if size and free is not None and free < size * 1.2 else ""
    return " · ".join(parts) + warning


def thumbnail_icon(encoded):
    pixmap = QPixmap()
    if encoded and pixmap.loadFromData(base64.b64decode(encoded)):
        return QIcon(pixmap.scaled(96, 54, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
    return QIcon()


class SettingsDialog(QDialog):
    def __init__(self, config, parent):
        super().__init__(parent)
        self.setWindowTitle("Modelle und Verbindungen")
        self.setMinimumWidth(560)
        layout = QVBoxLayout(self)
        layout.addWidget(label("Modelle und Verbindungen", "title"))
        layout.addWidget(label("Modelle werden bei der ersten Verwendung geladen. Lokale Analysen bleiben auf deinem Mac.", "subtitle"))
        form = QFormLayout()
        self.url = QLineEdit(config.get("ollama_url", "http://localhost:11434"))
        self.director = QLineEdit(config.get("director_model", "qwen2.5:7b"))
        self.vision = QLineEdit(config.get("vision_model", "qwen2.5vl:7b"))
        self.whisper = QComboBox()
        self.whisper.setEditable(True)
        self.whisper.addItems(["mlx-community/whisper-small-mlx", "mlx-community/whisper-tiny", "mlx-community/whisper-large-v3-turbo"])
        self.whisper.setCurrentText(config.get("whisper_model", "mlx-community/whisper-small-mlx"))
        self.openai = QLineEdit(config.get("openai_model", "gpt-4.1-mini"))
        self.key = QLineEdit(parent.api_key)
        self.key.setEchoMode(QLineEdit.EchoMode.Password)
        self.remember = QCheckBox("API-Key im macOS-Schlüsselbund speichern")
        form.addRow("Ollama-URL", self.url)
        form.addRow("Regie-Modell", self.director)
        form.addRow("Vision-Modell", self.vision)
        form.addRow("Whisper-Modell", self.whisper)
        form.addRow("OpenAI-Modell", self.openai)
        form.addRow("OpenAI API-Key", self.key)
        form.addRow("", self.remember)
        self.models = QLineEdit(str(models_dir(config)))
        self.models.setReadOnly(True)
        choose = QPushButton("Ändern …")
        choose.clicked.connect(self._choose_models)
        reveal = QPushButton("Im Finder")
        reveal.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(self.models.text())))
        folder_row = QHBoxLayout()
        folder_row.addWidget(self.models, 1)
        folder_row.addWidget(choose)
        folder_row.addWidget(reveal)
        form.addRow("Modell-Ordner", folder_row)
        layout.addLayout(form)
        layout.addWidget(label("Hierhin werden Whisper- und Ollama-Modelle heruntergeladen (mehrere GB). Bereits geladene Modelle werden nicht verschoben: kopiere sie bei Bedarf in den neuen Ordner (Unterordner „ollama“ und „huggingface“).", "subtitle"))
        layout.addWidget(label("Qwen Vision 7B benötigt etwa 6 GB Download plus Arbeitsspeicher. Für kleinere Macs kannst du qwen2.5vl:3b wählen. API-Aufrufe werden über deinen OpenAI-Account abgerechnet.", "subtitle"))
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _choose_models(self):
        folder = QFileDialog.getExistingDirectory(self, "Ordner für heruntergeladene Modelle", self.models.text())
        if folder:
            self.models.setText(folder)

    def values(self):
        return {"models_dir": self.models.text().strip(), "ollama_url": self.url.text().strip().rstrip("/"), "director_model": self.director.text().strip(), "vision_model": self.vision.text().strip(), "whisper_model": self.whisper.currentText().strip(), "openai_model": self.openai.text().strip()}


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP_NAME)
        self.setWindowIcon(app_icon())
        self.setAcceptDrops(True)
        self.resize(1280, 860)
        self.setMinimumSize(1060, 740)
        self.project = new_project()
        self.project_path = None
        self.dirty = False
        self.updating = False
        self.analysis_dirty = False
        self.job = None
        self.job_cancelled = False
        self.response_path = None
        self.request_path = None
        self.stdout_buffer = ""
        self.stderr_tail = ""
        self.api_key = ""  # Load the keychain only when the user opens settings or uses OpenAI.
        self.config_path = app_support() / "settings.json"
        try:
            self.config = json.loads(self.config_path.read_text())
        except (OSError, ValueError):
            self.config = {}
        self._build_ui()
        self._build_menu()
        self.autosave_timer = QTimer(self)
        self.autosave_timer.setSingleShot(True)
        self.autosave_timer.timeout.connect(self._autosave)
        self._refresh()
        QTimer.singleShot(400, self._restore_autosave)

    def _build_ui(self):
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        body = QHBoxLayout()
        body.setSpacing(0)
        sidebar = QFrame()
        sidebar.setObjectName("sidebar")
        sidebar.setFixedWidth(228)
        side = QVBoxLayout(sidebar)
        side.setContentsMargins(20, 28, 20, 22)
        side.setSpacing(14)
        head = QHBoxLayout()
        logo = QLabel()
        logo.setPixmap(logo_pixmap(44))
        logo.setFixedSize(46, 46)
        head.addWidget(logo)
        titles = QVBoxLayout()
        titles.setSpacing(0)
        titles.addWidget(label(APP_NAME, "brand", wrap=False))
        titles.addWidget(label("MUSIKVIDEOS", "eyebrow", wrap=False))
        head.addLayout(titles, 1)
        side.addLayout(head)
        side.addWidget(label("Jede Silbe. Jeder Beat.", "subtitle"))
        self.navigation = QListWidget()
        self.navigation.addItems([f"{i:02d}   {name}" for i, name in enumerate(STEPS, 1)])
        for row in range(self.navigation.count()):
            self.navigation.item(row).setToolTip(f"{STEPS[row]} · ⌘{row + 1}")
        side.addWidget(self.navigation)
        self.project_summary = label("Neues Projekt", "subtitle")
        side.addWidget(self.project_summary)
        side.addWidget(button("Modelle && Einstellungen", self.settings))
        side.addWidget(label(f"Apple Silicon · Version {__version__}", "subtitle"))
        body.addWidget(sidebar)
        self.pages = QStackedWidget()
        self.pages.addWidget(self._media_page())
        self.pages.addWidget(self._catalog_page())
        self.pages.addWidget(self._analysis_page())
        self.pages.addWidget(self._director_page())
        self.pages.addWidget(self._export_page())
        body.addWidget(self.pages, 1)
        root.addLayout(body, 1)
        footer = QFrame()
        footer.setObjectName("footer")
        foot = QHBoxLayout(footer)
        foot.setContentsMargins(24, 12, 24, 12)
        self.status_text = label("Bereit. Wähle zuerst deinen Videoordner und den Song.", "subtitle")
        self.progress_bar = QProgressBar()
        self.progress_bar.setFixedWidth(180)
        self.progress_bar.setRange(0, 1000)
        self.progress_bar.setTextVisible(False)
        self.cancel_button = button("Abbrechen", self.cancel_job)
        self.cancel_button.hide()
        foot.addWidget(self.status_text, 1)
        foot.addWidget(self.progress_bar)
        foot.addWidget(self.cancel_button)
        root.addWidget(footer)
        self.setCentralWidget(central)
        self.navigation.currentRowChanged.connect(self.pages.setCurrentIndex)
        self.navigation.setCurrentRow(0)

    def _page(self, eyebrow, title, subtitle):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(30, 28, 30, 22)
        layout.setSpacing(15)
        layout.addWidget(label(eyebrow, "eyebrow"))
        layout.addWidget(label(title, "title"))
        layout.addWidget(label(subtitle, "subtitle"))
        return page, layout

    def _media_page(self):
        page, layout = self._page("DEIN MATERIAL", "Ein Song. Deine Bilder.", "Wähle deine Medien. Analysen und Schnittpläne werden im Projekt gespeichert.")
        form = QFormLayout()
        form.setVerticalSpacing(12)
        self.name_edit = QLineEdit("Neues Musikvideo")
        self.name_edit.textEdited.connect(self._edited)
        form.addRow("Projektname", self.name_edit)
        self.folder_edit = QLineEdit()
        self.folder_edit.setReadOnly(True)
        row = QHBoxLayout()
        row.addWidget(self.folder_edit, 1)
        row.addWidget(button("Ordner auswählen …", self.choose_folder, True))
        form.addRow("Videoclips", row)
        self.audio_edit = QLineEdit()
        self.audio_edit.setReadOnly(True)
        row = QHBoxLayout()
        row.addWidget(self.audio_edit, 1)
        row.addWidget(button("Song auswählen …", self.choose_audio))
        form.addRow("Audiodatei", row)
        settings = QHBoxLayout()
        self.fps = QComboBox()
        for title, value in [("23,976 FPS", (24000,1001)),("24 FPS", (24,1)),("25 FPS", (25,1)),("29,97 FPS", (30000,1001)),("30 FPS", (30,1)),("50 FPS", (50,1)),("59,94 FPS", (60000,1001)),("60 FPS", (60,1))]:
            self.fps.addItem(title, value)
        self.fps.setCurrentIndex(2)
        self.fps.currentIndexChanged.connect(self._timeline_changed)
        self.width = QSpinBox()
        self.width.setRange(16, 16384)
        self.width.setValue(1920)
        self.height = QSpinBox()
        self.height.setRange(16, 16384)
        self.height.setValue(1080)
        self.width.valueChanged.connect(self._timeline_changed)
        self.height.valueChanged.connect(self._timeline_changed)
        self.format_preset = QComboBox()
        for title, width, height in FORMAT_PRESETS:
            self.format_preset.addItem(title, (width, height))
        self.format_preset.addItem("Eigenes Format", None)
        self.format_preset.activated.connect(self._preset_chosen)
        self.width.setSuffix(" px")
        self.height.setSuffix(" px")
        self.width.setMinimumWidth(110)
        self.height.setMinimumWidth(110)
        settings.addWidget(self.fps)
        settings.addWidget(self.format_preset, 1)
        settings.addSpacing(8)
        settings.addWidget(self.width)
        settings.addWidget(label("×", wrap=False))
        settings.addWidget(self.height)
        form.addRow("Timeline", settings)
        self.media_hint = label("Tipp: Du kannst einen Videoordner, eine Audiodatei oder ein Projekt auch direkt ins Fenster ziehen.", "subtitle")
        form.addRow("", self.media_hint)
        media_card, media_layout = card("Material und Format")
        media_layout.addLayout(form)
        layout.addWidget(media_card)
        layout.addWidget(label("Eigene Songtexte · optional", "cardtitle"))
        self.lyrics_edit = QPlainTextEdit()
        self.lyrics_edit.setPlaceholderText("Songtext hier einfügen. Leerzeilen trennen Abschnitte; [Refrain] und [Strophe] helfen bei der Zuordnung.\n\nOhne Vorlage transkribiert die App den Gesang selbst.")
        self.lyrics_edit.textChanged.connect(self._lyrics_changed)
        layout.addWidget(self.lyrics_edit, 1)
        row = QHBoxLayout()
        self.transcribe_check = QCheckBox("Gesang mit MLX Whisper transkribieren")
        self.transcribe_check.setChecked(True)
        row.addWidget(self.transcribe_check)
        row.addStretch()
        row.addWidget(button("Song analysieren", self.analyze_song, True))
        layout.addLayout(row)
        layout.addWidget(label("Beim ersten Gebrauch wird das gewählte Whisper-Modell geladen. Für Instrumentalmusik kannst du die Transkription ausschalten.", "subtitle"))
        return page

    def _catalog_page(self):
        page, layout = self._page("BILDER VERSTEHEN", "Dein Clip-Katalog", "Beschreibungen helfen der Regie, passende Bilder zu jeder Textzeile zu wählen.")
        row = QHBoxLayout()
        row.addWidget(button("Ordner neu einlesen", self.rescan))
        row.addWidget(label("Frames pro Clip", wrap=False))
        self.frame_count = QSpinBox()
        self.frame_count.setRange(1, 12)
        self.frame_count.setValue(3)
        row.addWidget(self.frame_count)
        self.only_missing = QCheckBox("Nur Clips ohne Beschreibung")
        self.only_missing.setToolTip("Setzt eine abgebrochene Analyse fort, ohne bereits beschriebene Clips erneut zu senden.")
        row.addWidget(self.only_missing)
        row.addStretch()
        row.addWidget(button("Clips mit Vision analysieren", self.analyze_clips, True))
        layout.addLayout(row)
        row = QHBoxLayout()
        self.clip_search = QLineEdit()
        self.clip_search.setObjectName("search")
        self.clip_search.setPlaceholderText("Clips filtern: Dateiname, Beschreibung oder Tag …")
        self.clip_search.setClearButtonEnabled(True)
        self.clip_search.textChanged.connect(self._filter_clips)
        row.addWidget(self.clip_search, 1)
        self.catalog_badge = label("", "badge", wrap=False)
        row.addWidget(self.catalog_badge)
        layout.addLayout(row)
        self.clip_table = table(["Dateiname", "Dauer", "Auflösung · FPS", "Beschreibung"])
        self.clip_table.setIconSize(QSize(72, 40))
        self.clip_table.verticalHeader().setDefaultSectionSize(46)
        self.clip_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        self.clip_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.clip_table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        self.clip_table.cellChanged.connect(self._clip_changed)
        self.clip_table.itemSelectionChanged.connect(self._select_clip)
        self.clip_table.cellDoubleClicked.connect(lambda row, col: self.reveal_clip() if col == 0 else None)
        layout.addWidget(self.clip_table, 1)
        bottom = QHBoxLayout()
        self.thumbnail = label("Clip auswählen")
        self.thumbnail.setFixedSize(216, 122)
        self.thumbnail.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.thumbnail.setStyleSheet("background:#1a2530; border-radius:8px; color:#8194a8;")
        bottom.addWidget(self.thumbnail)
        details = QVBoxLayout()
        self.clip_detail = label("Beschreibungen lassen sich direkt in der Tabelle bearbeiten.", "subtitle")
        details.addWidget(self.clip_detail, 1)
        actions = QHBoxLayout()
        actions.addWidget(button("Vorschaubild laden", self.load_thumbnail))
        actions.addWidget(button("Datei im Finder zeigen", self.reveal_clip))
        details.addLayout(actions)
        bottom.addLayout(details, 1)
        layout.addLayout(bottom)
        row = QHBoxLayout()
        row.addWidget(button("Umbenennungen prüfen …", self.rename_files))
        row.addWidget(button("Umbenennung rückgängig", self.undo_rename))
        row.addStretch()
        row.addWidget(button("CFR-Arbeitskopien erstellen …", self.normalize_clips))
        layout.addLayout(row)
        layout.addWidget(label("Vision beschreibt Stichproben. Prüfe wichtige Motive selbst. Originaldateien werden erst nach der Umbenennungsvorschau geändert.", "subtitle"))
        return page

    def _analysis_page(self):
        page, layout = self._page("RHYTHMUS & TEXT", "Dein Song auf der Zeitachse", "Beat- und Textpositionen sind Schätzwerte. Hier kannst du sie vor der Regie korrigieren.")
        row = QHBoxLayout()
        self.audio_summary = label("Noch keine Audioanalyse vorhanden.", "subtitle")
        row.addWidget(self.audio_summary, 1)
        row.addWidget(button("Song anhören", self.play_song))
        row.addWidget(button("Neu analysieren", self.analyze_song))
        layout.addLayout(row)
        split = QSplitter(Qt.Orientation.Horizontal)
        beats_box = QWidget()
        b = QVBoxLayout(beats_box)
        b.setContentsMargins(0,0,5,0)
        b.addWidget(label("Beats · Sekunden"))
        self.beat_table = table(["Position"])
        self.beat_table.cellChanged.connect(self._analysis_edited)
        b.addWidget(self.beat_table, 1)
        row = QHBoxLayout()
        row.addWidget(button("+", lambda: self._add_row(self.beat_table, ["0.000"])))
        row.addWidget(button("−", lambda: self._remove_rows(self.beat_table)))
        b.addLayout(row)
        b.addWidget(label("Schnittraster", wrap=False))
        self.beat_mode = QComboBox()
        for key, title in BEAT_GRID_MODES.items():
            self.beat_mode.addItem(title, key)
        self.beat_mode.setToolTip("Hilft, wenn librosa das halbe oder doppelte Tempo erkannt hat oder nur auf Takten geschnitten werden soll.")
        b.addWidget(self.beat_mode)
        row = QHBoxLayout()
        self.beat_phase = QSpinBox()
        self.beat_phase.setRange(1, 4)
        self.beat_phase.setPrefix("ab Beat ")
        self.beat_phase.setToolTip("Mit welchem Beat der Gruppe das Raster beginnt (z. B. Taktanfang).")
        row.addWidget(self.beat_phase)
        row.addWidget(button("Anwenden", self.apply_beat_grid))
        b.addLayout(row)
        row = QHBoxLayout()
        self.beat_offset = QDoubleSpinBox()
        self.beat_offset.setRange(-500, 500)
        self.beat_offset.setDecimals(0)
        self.beat_offset.setSuffix(" ms")
        self.beat_offset.setToolTip("Alle Beats gemeinsam verschieben, z. B. wenn Schnitte durchgehend zu früh wirken.")
        row.addWidget(self.beat_offset)
        row.addWidget(button("Verschieben", self.shift_beats))
        b.addLayout(row)
        split.addWidget(beats_box)
        text_box = QWidget()
        t = QVBoxLayout(text_box)
        t.setContentsMargins(5,0,0,0)
        t.addWidget(label("Textzeilen · Start / Ende in Sekunden"))
        self.line_table = table(["Start", "Ende", "Text"])
        self.line_table.cellChanged.connect(self._analysis_edited)
        self.line_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        self.line_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        t.addWidget(self.line_table, 1)
        row = QHBoxLayout()
        row.addWidget(button("Zeile hinzufügen", lambda: self._add_row(self.line_table, ["0.000", "1.000", ""])))
        row.addWidget(button("Zeile entfernen", lambda: self._remove_rows(self.line_table)))
        row.addStretch()
        t.addLayout(row)
        split.addWidget(text_box)
        split.setSizes([230,600])
        layout.addWidget(split, 3)
        layout.addWidget(label("Songabschnitte · Wiederholung verweist auf die ID der ersten Sequenz"))
        self.section_table = table(["ID", "Bezeichnung", "Start", "Ende", "Wiederholung von"])
        self.section_table.cellChanged.connect(self._analysis_edited)
        layout.addWidget(self.section_table, 1)
        row = QHBoxLayout()
        row.addWidget(button("Abschnitt hinzufügen", self._add_section))
        row.addWidget(button("Abschnitt entfernen", lambda: self._remove_rows(self.section_table)))
        row.addStretch()
        row.addWidget(button("Änderungen übernehmen", self.apply_analysis_edits, True))
        layout.addLayout(row)
        self.analysis_warnings = label("", "subtitle")
        layout.addWidget(self.analysis_warnings)
        return page

    def _director_page(self):
        page, layout = self._page("KREATIVE ENTSCHEIDUNGEN", "Deine KI-Regie", "Clipnamen, Beschreibungen und Songtexte bestimmen die Bildauswahl. Die App prüft alle Schnittregeln.")
        style_card, style_layout = card("Schnittstil", "Gilt für den lokalen Basisplan und wird der KI-Regie als Vorgabe mitgegeben.")
        grid = QGridLayout()
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(8)
        self.variation = QComboBox()
        for key, title in [("gleichmaessig", "Gleichmäßig"), ("abwechslungsreich", "Abwechslungsreich"), ("wild", "Wild")]:
            self.variation.addItem(title, key)
        self.verse_beats = QSpinBox()
        self.verse_beats.setRange(1, 32)
        self.verse_beats.setSuffix(" Beats")
        self.chorus_beats = QSpinBox()
        self.chorus_beats.setRange(1, 32)
        self.chorus_beats.setSuffix(" Beats")
        self.chorus_faster = QCheckBox("Refrain schneller schneiden")
        self.dice_button = button("Neu würfeln", self.reroll_style)
        grid.addWidget(label("Variation der Cliplängen", wrap=False), 0, 0)
        grid.addWidget(self.variation, 0, 1)
        grid.addWidget(label("Strophe: Schnitt etwa alle", wrap=False), 0, 2)
        grid.addWidget(self.verse_beats, 0, 3)
        grid.addWidget(self.chorus_faster, 1, 0, 1, 2)
        grid.addWidget(label("Refrain: Schnitt etwa alle", wrap=False), 1, 2)
        grid.addWidget(self.chorus_beats, 1, 3)
        grid.addWidget(self.dice_button, 0, 4, 2, 1)
        grid.setColumnStretch(1, 1)
        style_layout.addLayout(grid)
        for widget in (self.variation,):
            widget.currentIndexChanged.connect(self._style_changed)
        for widget in (self.verse_beats, self.chorus_beats):
            widget.valueChanged.connect(self._style_changed)
        self.chorus_faster.toggled.connect(self._style_changed)
        layout.addWidget(style_card)
        row = QHBoxLayout()
        self.provider = QComboBox()
        self.provider.addItems(["Ollama", "OpenAI"])
        row.addWidget(label("Automatisch", wrap=False))
        row.addWidget(self.provider)
        row.addStretch()
        row.addWidget(button("Schnittplan erstellen", self.generate_plan, True))
        layout.addLayout(row)
        row = QHBoxLayout()
        row.addWidget(button("Analyse-Prompt kopieren", self.copy_prompt))
        row.addWidget(button("Prompt als Datei speichern …", self.save_prompt))
        row.addStretch()
        row.addWidget(button("Lokalen Basisplan erstellen", self.basic_plan))
        layout.addLayout(row)
        layout.addWidget(label("Manuell mit ChatGPT: Prompt kopieren, im Web senden und die JSON-Antwort hier einfügen.", "subtitle"))
        self.plan_edit = QPlainTextEdit()
        self.plan_edit.setPlaceholderText('{\n  "version": 1,\n  "shots": [\n    {"clip_id": "…", "start_beat": 0, "end_beat": 4, "source_in": 0}\n  ]\n}')
        self.plan_edit.setFont(QFont("Menlo", 11))
        self.plan_edit.textChanged.connect(self._edited)
        layout.addWidget(self.plan_edit, 1)
        row = QHBoxLayout()
        self.plan_status = label("Noch kein Schnittplan vorhanden.", "subtitle")
        row.addWidget(self.plan_status, 1)
        row.addWidget(button("JSON prüfen und übernehmen", self.accept_plan, True))
        layout.addLayout(row)
        layout.addWidget(label("Der Basisplan funktioniert ohne Regie-Modell. Er nutzt Wortübereinstimmungen und dient als bearbeitbarer Ausgangspunkt.", "subtitle"))
        return page

    def _export_page(self):
        page, layout = self._page("BEREIT FÜR DEN SCHNITT", "Prüfen. Exportieren. Weiterarbeiten.", "Eine Bildspur und der vollständige Song. Medien bleiben über absolute Dateipfade verknüpft.")
        self.timeline_summary = label("Übernimm zuerst einen geprüften Schnittplan.", "subtitle")
        layout.addWidget(self.timeline_summary)
        self.shot_table = table(["Start", "Ende", "Clip", "Quelle ab", "Beats"])
        self.shot_table.setToolTip("Doppelklick spielt den Song ab dieser Einstellung ab.")
        self.shot_table.cellDoubleClicked.connect(self._play_shot)
        layout.addWidget(self.shot_table, 1)
        formats_card, formats_layout = card("Exportformate", "Eine Bildspur plus der vollständige Song. Wähle das Programm, in dem du weiterarbeitest.")
        self.format_fcpxml = QCheckBox("Final Cut Pro · timeline.fcpxml")
        self.format_fcpxml.setChecked(True)
        self.format_fcpxml.setToolTip("Final Cut Pro XML 1.8: Ablage → Import → XML …")
        self.format_xml = QCheckBox("DaVinci Resolve / Premiere · timeline.xml")
        self.format_xml.setChecked(True)
        self.format_xml.setToolTip("FCP-7-XML (xmeml): in DaVinci Resolve Datei → Importieren → Timeline …")
        self.format_edl = QCheckBox("DaVinci Resolve (nur Video) · timeline.edl")
        self.format_edl.setChecked(True)
        self.format_edl.setToolTip("CMX-3600-EDL als Rückfalloption; Resolve verknüpft die Clips über den Dateinamen. Der Song muss separat auf die Tonspur gelegt werden.")
        self.format_otio = QCheckBox("OpenTimelineIO · timeline.otio")
        self.format_otio.setChecked(False)
        for box in (self.format_fcpxml, self.format_xml, self.format_edl, self.format_otio):
            formats_layout.addWidget(box)
        layout.addWidget(formats_card)
        row = QHBoxLayout()
        row.addWidget(button("Schnittplan prüfen", self.accept_plan))
        row.addWidget(button("Song ab Auswahl abspielen", lambda: self._play_shot(self.shot_table.currentRow(), 0)))
        row.addStretch()
        row.addWidget(button("Projekt speichern", self.save_project))
        row.addWidget(button("Timeline exportieren …", self.export, True))
        layout.addLayout(row)
        self.export_result = label("", "subtitle")
        layout.addWidget(self.export_result)
        layout.addWidget(label("Jeder innere Schnitt folgt einem Beat und wird auf den nächsten Timeline-Frame gerundet. Songanfang und Songende sind die äußeren Grenzen.", "subtitle"))
        return page

    def _build_menu(self):
        menu = self.menuBar().addMenu("Ablage")
        for title, shortcut, callback in [("Neues Projekt", "Ctrl+N", self.new_project), ("Projekt öffnen …", "Ctrl+O", self.open_project), ("Projekt speichern", "Ctrl+S", self.save_project), ("Projekt speichern unter …", "Ctrl+Shift+S", lambda: self.save_project(True))]:
            action = QAction(title, self)
            action.setShortcut(shortcut)
            action.triggered.connect(callback)
            menu.addAction(action)
        self.recent_menu = menu.addMenu("Zuletzt geöffnet")
        self.recent_menu.aboutToShow.connect(self._fill_recent_menu)
        menu.addSeparator()
        menu.addAction("Beenden", self.close)
        view = self.menuBar().addMenu("Darstellung")
        for index, name in enumerate(STEPS):
            action = QAction(f"{index + 1}  {name}", self)
            action.setShortcut(QKeySequence(f"Ctrl+{index + 1}"))
            action.triggered.connect(lambda _checked=False, row=index: self.navigation.setCurrentRow(row))
            view.addAction(action)
        help_menu = self.menuBar().addMenu("Hilfe")
        help_menu.addAction("Bedienungsanleitung", self.show_help)
        help_menu.addAction("Modell herunterladen …", self.download_model)
        help_menu.addAction("Lokale Modelle anzeigen", self.list_models)
        help_menu.addAction("Datenordner im Finder zeigen", lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(app_support()))))
        help_menu.addSeparator()
        about = QAction(f"Über {APP_NAME}", self)
        about.setMenuRole(QAction.MenuRole.AboutRole)
        about.triggered.connect(self.show_about)
        help_menu.addAction(about)

    def _fill_recent_menu(self):
        self.recent_menu.clear()
        items = recent_projects()
        if not items:
            self.recent_menu.addAction("Keine Projekte").setEnabled(False)
            return
        for path in items:
            self.recent_menu.addAction(Path(path).name, lambda _checked=False, p=path: self.open_project_path(p)).setToolTip(path)

    def show_about(self):
        QMessageBox.about(self, f"Über {APP_NAME}", f"<h3>{APP_NAME} {__version__}</h3><p>Lokale, beatgenaue Musikvideo-Regie für macOS auf Apple Silicon.</p>"
                          "<p>Beat-Analyse mit librosa, Gesang mit MLX Whisper, Bildbeschreibung mit Ollama Vision; Export für Final Cut Pro (FCPXML), DaVinci Resolve (XML, EDL) und OpenTimelineIO.</p>")

    def _notify(self, message):
        self.status_text.setText(message)
        self.status_text.setToolTip(message)

    def _error(self, message, detail=None):
        box = QMessageBox(QMessageBox.Icon.Warning, APP_NAME, str(message), QMessageBox.StandardButton.Ok, self)
        if detail:
            box.setDetailedText(str(detail))
        box.exec()

    def _edited(self, *_):
        if self.updating:
            return
        self.dirty = True
        self._update_title()
        self.autosave_timer.start(1500)

    def _update_title(self):
        name = self.name_edit.text().strip() or self.project.get("name") or "Neues Musikvideo"
        self.setWindowTitle(f"{name}[*] — {APP_NAME}")
        self.setWindowModified(bool(self.dirty))
        if self.project_path:
            self.setWindowFilePath(str(self.project_path))

    def _update_steps(self):
        """Sidebar check marks show which steps are already done."""
        p = self.project
        audio = p.get("audio") or {}
        done = [bool(p.get("clips") and p.get("audio_path")),
                bool(p.get("clips")) and all(str(c.get("description", "")).strip() for c in p.get("clips", [])),
                bool(audio.get("duration")), bool(p.get("plan")), bool(p.get("last_export"))]
        for row, finished in enumerate(done):
            item = self.navigation.item(row)
            item.setText(f"{'✓' if finished else f'{row + 1:02d}'}   {STEPS[row]}")

    def _preset_chosen(self, index):
        size = self.format_preset.itemData(index)
        if size:
            self.updating = True
            self.width.setValue(size[0])
            self.height.setValue(size[1])
            self.updating = False
            self._timeline_changed()

    def _sync_preset(self):
        current = (self.width.value(), self.height.value())
        index = next((i for i in range(self.format_preset.count()) if self.format_preset.itemData(i) and tuple(self.format_preset.itemData(i)) == current), self.format_preset.count() - 1)
        self.format_preset.setCurrentIndex(index)

    def _lyrics_changed(self):
        if not self.updating:
            self._edited()

    def _timeline_changed(self, *_):
        if not self.updating:
            self._sync_preset()
            self._edited()
            self._refresh_timeline()

    def _sync_form(self):
        self.project.update(name=self.name_edit.text().strip() or "Neues Musikvideo", lyrics=self.lyrics_edit.toPlainText())
        self.project["plan_draft"] = self.plan_edit.toPlainText()
        if self.analysis_dirty:
            self.project["analysis_draft"] = {
                name: [[cell(widget,r,c) for c in range(widget.columnCount())] for r in range(widget.rowCount())]
                for name,widget in [("beats",self.beat_table),("lines",self.line_table),("sections",self.section_table)]
            }
        style = self.project.get("cut_style") or default_cut_style()
        self.project["cut_style"] = {**style, "variation": self.variation.currentData(), "verse_beats": self.verse_beats.value(),
                                     "chorus_beats": self.chorus_beats.value(), "chorus_faster": self.chorus_faster.isChecked()}
        num, den = self.fps.currentData()
        self.project["timeline"] = {"fps_num": num, "fps_den": den, "width": self.width.value(), "height": self.height.value()}

    def _autosave(self):
        try:
            self._sync_form()
            save_project(self.project, app_support() / "autosave.json")
        except OSError as error:
            self._notify(f"Automatisches Speichern fehlgeschlagen: {error}")

    def _restore_autosave(self):
        if self.project_path:
            return
        path = app_support() / "autosave.json"
        try:
            previous = load_project(path)
        except (OSError, ValueError, KeyError):
            return
        if not previous.get("clips") and not previous.get("audio_path"):
            return
        if QMessageBox.question(self, "Projekt fortsetzen", f"Das zuletzt automatisch gesicherte Projekt „{previous.get('name', 'Neues Musikvideo')}“ wiederherstellen?") == QMessageBox.StandardButton.Yes:
            try:
                previous["clips"]=recover_pending_rename(previous["clips"])
                self.project = previous
                self.dirty = True  # Not yet saved to a project file of its own.
                self._refresh()
            except Exception as error:
                self._error(error)

    def _refresh(self):
        try:
            self._populate_ui()
        finally:
            self.updating=False

    def _populate_ui(self):
        self.updating = True
        p = self.project
        self.name_edit.setText(p.get("name", "Neues Musikvideo"))
        self.folder_edit.setText(p.get("video_dir", ""))
        self.audio_edit.setText(p.get("audio_path", ""))
        self.lyrics_edit.setPlainText(p.get("lyrics", ""))
        tl = p.get("timeline", {})
        target = (tl.get("fps_num",25), tl.get("fps_den",1))
        for index in range(self.fps.count()):
            if tuple(self.fps.itemData(index)) == target:
                self.fps.setCurrentIndex(index)
        style = {**default_cut_style(), **(p.get("cut_style") or {})}
        self.variation.setCurrentIndex(max(0, self.variation.findData(style["variation"])))
        self.verse_beats.setValue(style["verse_beats"])
        self.chorus_beats.setValue(style["chorus_beats"])
        self.chorus_faster.setChecked(style["chorus_faster"])
        self.chorus_beats.setEnabled(style["chorus_faster"])
        self.width.setValue(tl.get("width",1920))
        self.height.setValue(tl.get("height",1080))
        self._sync_preset()
        clips = p.get("clips", [])
        set_rows(self.clip_table, [[c["name"], f"{c['duration']:.3f} s", f"{c['width']} × {c['height']} · {c['fps_num']/c['fps_den']:.3f}", c.get("description", "")] for c in clips])
        self.clip_table.blockSignals(True)
        for row in range(self.clip_table.rowCount()):
            clip = clips[row]
            for col in range(3):
                item = self.clip_table.item(row,col)
                item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEditable)
            first = self.clip_table.item(row,0)
            samples = clip.get("samples") or []
            if samples and samples[0].get("image"):
                first.setIcon(thumbnail_icon(samples[0]["image"]))
            notes = list(clip.get("metadata_warnings", []))
            if clip.get("vision_error"):
                notes.insert(0, "Vision: " + clip["vision_error"])
            first.setToolTip("\n".join([clip["path"], *notes]))
            if clip.get("vision_error") or clip.get("is_vfr"):
                first.setForeground(QColor("#f0c674"))
            if not str(clip.get("description", "")).strip():
                self.clip_table.item(row,3).setToolTip("Noch keine Beschreibung – Vision-Analyse starten oder selbst eintragen.")
        self.clip_table.blockSignals(False)
        described = sum(1 for c in clips if str(c.get("description", "")).strip())
        self.catalog_badge.setText(f"{described}/{len(clips)} beschrieben" if clips else "")
        self.catalog_badge.setVisible(bool(clips))
        self._filter_clips(self.clip_search.text())
        a = p.get("audio") or {}
        set_rows(self.beat_table, [[f"{x:.6f}"] for x in a.get("beats",[])])
        set_rows(self.line_table, [[f"{x['start']:.3f}", f"{x['end']:.3f}", x["text"]] for x in a.get("lines",[])])
        set_rows(self.section_table, [[x["id"],x.get("label",""),f"{x['start']:.3f}",f"{x['end']:.3f}",x.get("repeat_of") or ""] for x in a.get("sections",[])])
        draft=p.get("analysis_draft")
        self.analysis_dirty=bool(draft)
        if draft:
            for key,widget in [("beats",self.beat_table),("lines",self.line_table),("sections",self.section_table)]:
                set_rows(widget,draft.get(key,[]))
        duration = a.get("duration",0)
        tempo = a.get("tempo") or 0
        self.audio_summary.setText((f"{duration:.2f} s · {len(a.get('beats',[]))} Beats" + (f" · ≈ {tempo:.0f} BPM" if tempo else "") + f" · {len(a.get('lines',[]))} Textzeilen") if duration else "Noch keine Audioanalyse vorhanden.")
        self.analysis_warnings.setText(("Ungesicherte Tabellenkorrekturen: vor der Regie werden sie geprüft und übernommen.\n" if self.analysis_dirty else "")+"\n".join(a.get("warnings",[])[:3]))
        self.project_summary.setText(f"{p.get('name','Neues Musikvideo')}\n{len(clips)} Clips · {duration:.1f} s Song")
        self.plan_edit.setPlainText(p.get("plan_draft") or (json.dumps(p["plan"],ensure_ascii=False,indent=2) if p.get("plan") else ""))
        self.updating = False
        self._refresh_timeline()
        self._update_steps()
        self._update_title()

    def _refresh_timeline(self):
        if not self.project.get("plan"):
            set_rows(self.shot_table, [], True)
            self.timeline_summary.setText("Übernimm zuerst einen geprüften Schnittplan.")
            self.plan_status.setText("Noch kein geprüfter Schnittplan vorhanden.")
            return
        self._sync_form()
        try:
            timeline = compile_timeline(self.project, self.project["plan"])
            rate = timeline["fps_num"] / timeline["fps_den"]
            shots = timeline["shots"]
            set_rows(self.shot_table, [[f"{s['start']/rate:.3f} s",f"{s['end']/rate:.3f} s",s["clip"]["name"],f"{s['source_in_frame']/(s['clip']['fps_num']/s['clip']['fps_den']):.3f} s",f"{s.get('start_beat','')} → {s.get('end_beat','')}"] for s in shots],True)
            self.timeline_summary.setText(f"{len(shots)} Einstellungen · {timeline['duration_frames']/rate:.3f} s · {timeline['width']} × {timeline['height']} · {rate:.3f} FPS\nMaximale Beat-Rundung: {500/rate:.2f} ms")
            self.plan_status.setText(f"Geprüft · {len(shots)} Einstellungen")
        except (ValueError, KeyError, TypeError) as error:
            self.timeline_summary.setText(f"Schnittplan muss geprüft werden: {error}")
            self.plan_status.setText("Schnittplan muss erneut geprüft werden.")

    def _invalidate_plan(self):
        self.project["plan"] = None
        self.project.pop("plan_draft", None)
        self.project.pop("last_export", None)
        self.plan_edit.clear()
        self._refresh_timeline()
        self._update_steps()

    def _filter_clips(self, text=""):
        needle = text.strip().casefold()
        clips = self.project.get("clips", [])
        for row in range(self.clip_table.rowCount()):
            clip = clips[row] if row < len(clips) else {}
            haystack = " ".join([str(clip.get("name", "")), str(clip.get("description", "")), " ".join(map(str, clip.get("tags", [])))]).casefold()
            self.clip_table.setRowHidden(row, bool(needle) and needle not in haystack)

    def _table_beats(self):
        values = []
        for row in range(self.beat_table.rowCount()):
            try:
                values.append(float(cell(self.beat_table, row, 0).replace(",", ".")))
            except ValueError:
                raise ValueError(f"Beat in Zeile {row + 1} ist keine Zahl.") from None
        return values

    def _set_table_beats(self, beats, message):
        set_rows(self.beat_table, [[f"{x:.6f}"] for x in beats])
        self._analysis_edited()
        self._notify(message + " Mit „Änderungen übernehmen“ bestätigen.")

    def apply_beat_grid(self):
        duration = float((self.project.get("audio") or {}).get("duration") or 0)
        if not duration:
            self._error("Analysiere zuerst den Song.")
            return
        try:
            before = self._table_beats()
            mode = self.beat_mode.currentData()
            beats = retime_beats(before, mode, duration, phase=self.beat_phase.value() - 1)
        except ValueError as error:
            self._error(error)
            return
        if len(beats) < 1:
            self._error("Das Raster würde alle Beats entfernen.")
            return
        self._set_table_beats(beats, f"Schnittraster angewendet: {len(before)} → {len(beats)} Beats.")

    def shift_beats(self):
        duration = float((self.project.get("audio") or {}).get("duration") or 0)
        offset = self.beat_offset.value() / 1000
        if not duration or not offset:
            return
        try:
            beats = retime_beats(self._table_beats(), "shift", duration, offset=offset)
        except ValueError as error:
            self._error(error)
            return
        self._set_table_beats(beats, f"Alle Beats um {offset * 1000:+.0f} ms verschoben.")

    def _play_shot(self, row, _column=0):
        if row < 0 or not self.project.get("plan"):
            return
        try:
            seconds = float(cell(self.shot_table, row, 0).split()[0])
        except (ValueError, IndexError):
            return
        self.play_song(start=seconds, toggle=False)

    def _drop_paths(self, event):
        return [Path(url.toLocalFile()) for url in event.mimeData().urls() if url.isLocalFile()]

    def dragEnterEvent(self, event):
        if not self.job and any(p.is_dir() or p.suffix.lower() in AUDIO_EXTENSIONS | VIDEO_EXTENSIONS | set(PROJECT_SUFFIXES) for p in self._drop_paths(event)):
            event.acceptProposedAction()

    def dropEvent(self, event):
        paths = self._drop_paths(event)
        event.acceptProposedAction()
        project = next((p for p in paths if p.suffix.lower() in PROJECT_SUFFIXES), None)
        if project:
            QTimer.singleShot(0, lambda: self.open_project_path(str(project)))
            return
        audio = next((p for p in paths if p.suffix.lower() in AUDIO_EXTENSIONS), None)
        if audio:
            self._set_audio(str(audio))
        folder = next((p for p in paths if p.is_dir()), None)
        if folder is None:
            videos = [p for p in paths if p.suffix.lower() in VIDEO_EXTENSIONS]
            folder = videos[0].parent if videos else None
        if folder:
            QTimer.singleShot(0, lambda: self._scan(str(folder)))

    def choose_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "Videoordner auswählen", self.project.get("video_dir", ""))
        if folder:
            self._scan(folder)

    def _scan(self, folder):
        def signature(items):
            return sorted((c.get("id"), c.get("path"), c.get("duration"), c.get("fps_num"), c.get("fps_den"), c.get("frame_count")) for c in items)
        def done(clips):
            unchanged = signature(clips) == signature(self.project.get("clips", []))
            self.project["video_dir"] = folder
            self.project["clips"] = clips
            if not unchanged:
                self._invalidate_plan()  # A rescan of identical media keeps the checked plan.
            self._edited()
            self._refresh()
            self.navigation.setCurrentRow(1)
            self._notify(f"{len(clips)} Clips eingelesen." + (" Schnittplan bleibt gültig." if unchanged and self.project.get("plan") else ""))
        self._start_job("scan", {"folder":folder,"clips":self.project.get("clips",[])}, done)

    def rescan(self):
        if self.project.get("video_dir"):
            self._scan(self.project["video_dir"])
        else:
            self.choose_folder()

    def choose_audio(self):
        path, _ = QFileDialog.getOpenFileName(self,"Song auswählen",str(Path(self.project.get("audio_path") or "").parent) if self.project.get("audio_path") else "","Audiodateien (" + " ".join("*"+e for e in sorted(AUDIO_EXTENSIONS)) + ");;Alle Dateien (*)")
        if path:
            self._set_audio(path)

    def _set_audio(self, path):
        self.project["audio_path"] = path
        self.project["audio"] = {}
        self.project.pop("analysis_draft", None)
        self.analysis_dirty = False
        self._invalidate_plan()
        self._edited()
        self._refresh()
        self._notify(f"Song gewählt: {Path(path).name}. Als Nächstes „Song analysieren“.")

    def analyze_song(self):
        self._sync_form()
        if not self.project.get("audio_path"):
            self._error("Wähle zuerst eine Audiodatei aus.")
            return
        def done(audio):
            self.project["audio"] = audio
            self.project.pop("analysis_draft",None)
            self.analysis_dirty=False
            self._invalidate_plan()
            self._edited()
            self._refresh()
            self.navigation.setCurrentRow(2)
        self._start_job("audio",{"path":self.project["audio_path"],"lyrics":self.project["lyrics"],"model":self.config.get("whisper_model","mlx-community/whisper-small-mlx") if self.transcribe_check.isChecked() else ""},done)

    def analyze_clips(self):
        if not self.project.get("clips"):
            self._error("Wähle zuerst einen Ordner mit Videoclips.")
            return
        def done(clips):
            self.project["clips"] = clips
            self._edited()
            self._refresh()
            failed = [c for c in clips if c.get("vision_error")]
            if failed:
                self._notify(f"Vision fertig · {len(failed)} Clip(s) übersprungen. Details im Tooltip der gelb markierten Zeilen.")
            else:
                self._notify("Vision-Analyse abgeschlossen. Beschreibungen kannst du direkt in der Tabelle anpassen.")
        self._start_job("vision",{"clips":self.project["clips"],"frame_count":self.frame_count.value(),"only_missing":self.only_missing.isChecked(),"model":self.config.get("vision_model","qwen2.5vl:7b"),"base_url":self.config.get("ollama_url","http://localhost:11434")},done)

    def _clip_changed(self,row,col):
        if not self.updating and col == 3 and row < len(self.project["clips"]):
            self.project["clips"][row]["description"] = cell(self.clip_table,row,3)
            self.project["clips"][row].pop("vision_error", None)
            self._edited()
            self._update_steps()

    def _selected_clip(self):
        index = self.clip_table.currentRow()
        return self.project["clips"][index] if 0 <= index < len(self.project["clips"]) else None

    def _select_clip(self):
        clip = self._selected_clip()
        if clip:
            warnings = clip.get("metadata_warnings", [])
            scenes = [x for x in clip.get("segments", []) if isinstance(x, dict)]
            scene_text = ""
            if len(scenes) > 1:
                scene_text = "\nSzenen: " + " · ".join(f"{x['start']:.1f}–{x['end']:.1f} s" + (f" {x['description']}" if x.get("description") else "") for x in scenes[:6]) + (" …" if len(scenes) > 6 else "")
            self.clip_detail.setText((clip.get("description") or clip["path"])+scene_text+("\n"+"\n".join(warnings[:2]) if warnings else ""))
            self.clip_detail.setToolTip("\n".join(warnings))
            samples = clip.get("samples") or []
            if samples and samples[0].get("image"):
                self._show_thumbnail(samples[0]["image"])
            else:
                self.thumbnail.setPixmap(QPixmap())
                self.thumbnail.setText("Vorschaubild laden")

    def _show_thumbnail(self, encoded):
        pixmap = QPixmap()
        pixmap.loadFromData(base64.b64decode(encoded))
        self.thumbnail.setPixmap(pixmap.scaled(self.thumbnail.size(),Qt.AspectRatioMode.KeepAspectRatio,Qt.TransformationMode.SmoothTransformation))

    def load_thumbnail(self):
        clip = self._selected_clip()
        if clip:
            row = self.clip_table.currentRow()
            def done(samples):
                if samples:
                    clip["samples"] = samples[:1]
                    self._show_thumbnail(samples[0]["image"])
                    item = self.clip_table.item(row, 0)
                    if item:
                        item.setIcon(thumbnail_icon(samples[0]["image"]))
                    self._edited()
            self._start_job("frames",{"clip":clip,"count":1},done)

    def reveal_clip(self):
        clip = self._selected_clip()
        if clip:
            QProcess.startDetached("/usr/bin/open",["-R",clip["path"]])

    def rename_files(self):
        try:
            mappings = rename_preview(self.project.get("clips",[]))
            changed = [m for m in mappings if m["old_path"] != m["new_path"]]
            if not changed:
                self._notify("Keine Umbenennungen vorgeschlagen. Analysiere zunächst die Clips mit Vision.")
                return
            dialog = QDialog(self)
            dialog.setWindowTitle("Umbenennungsvorschau")
            dialog.resize(850,500)
            layout = QVBoxLayout(dialog)
            layout.addWidget(label("Diese Originaldateien werden umbenannt. Die Änderung kann über die App rückgängig gemacht werden.","subtitle"))
            preview = table(["Aktueller Name","Neuer Name"])
            set_rows(preview,[[Path(m["old_path"]).name,Path(m["new_path"]).name] for m in changed],True)
            layout.addWidget(preview)
            controls = QDialogButtonBox(QDialogButtonBox.StandardButton.Apply | QDialogButtonBox.StandardButton.Cancel)
            controls.button(QDialogButtonBox.StandardButton.Apply).setText("Dateien umbenennen")
            controls.button(QDialogButtonBox.StandardButton.Apply).clicked.connect(dialog.accept)
            controls.rejected.connect(dialog.reject)
            layout.addWidget(controls)
            if dialog.exec() == QDialog.DialogCode.Accepted:
                self.project["clips"] = rename_clips(self.project["clips"],changed)
                self._edited()
                self._refresh()
        except Exception as error:
            self._error(error)

    def undo_rename(self):
        try:
            self.project["clips"] = undo_rename(self.project["clips"])
            self._edited()
            self._refresh()
        except Exception as error:
            self._error(error)

    def normalize_clips(self):
        if not self.project.get("clips"):
            return
        path = QFileDialog.getExistingDirectory(self,"Zielordner für ProRes-Arbeitskopien auswählen")
        if not path:
            return
        self._sync_form()
        def done(result):
            self.project["clips"] = result["clips"]
            self.project["video_dir"] = result["folder"]
            self._invalidate_plan()
            self._edited()
            self._refresh()
        self._start_job("normalize",{"clips":self.project["clips"],"destination":path,**self.project["timeline"]},done)

    def _add_row(self,widget,values):
        row=widget.rowCount()
        widget.insertRow(row)
        for col,value in enumerate(values):
            widget.setItem(row,col,QTableWidgetItem(str(value)))
        self._analysis_edited()

    def _remove_rows(self,widget):
        for row in sorted({x.row() for x in widget.selectedIndexes()},reverse=True):
            widget.removeRow(row)
        self._analysis_edited()

    def _analysis_edited(self,*_):
        if not self.updating:
            self.analysis_dirty=True
            self.analysis_warnings.setText("Tabellenkorrekturen sind als Entwurf gesichert. Vor der Regie werden sie geprüft und übernommen.")
            self._edited()

    def _add_section(self):
        self._add_row(self.section_table,[f"abschnitt-{uuid.uuid4().hex[:5]}","Refrain","0.000",f"{self.project.get('audio',{}).get('duration',1):.3f}",""])

    def apply_analysis_edits(self,_checked=False,*,notify=True):
        a = copy.deepcopy(self.project.get("audio") or {})
        try:
            duration = float(a.get("duration",0))
            if duration <= 0:
                raise ValueError("Analysiere zuerst den Song.")
            beats = sorted(set(float(cell(self.beat_table,r,0).replace(",",".")) for r in range(self.beat_table.rowCount())))
            if any(not 0 <= t <= duration for t in beats):
                raise ValueError("Beatpositionen müssen innerhalb des Songs liegen.")
            lines=[]
            for r in range(self.line_table.rowCount()):
                start,end=(float(cell(self.line_table,r,c).replace(",",".")) for c in [0,1])
                if not 0 <= start < end <= duration+0.001:
                    raise ValueError(f"Ungültige Zeit in Textzeile {r+1}.")
                lines.append({"id":f"line-{r+1}","start":start,"end":min(end,duration),"text":cell(self.line_table,r,2)})
            sections=[]
            for r in range(self.section_table.rowCount()):
                start,end=(float(cell(self.section_table,r,c).replace(",",".")) for c in [2,3])
                if not 0 <= start < end <= duration+0.001:
                    raise ValueError(f"Ungültige Zeit in Abschnitt {r+1}.")
                sections.append({"id":cell(self.section_table,r,0),"label":cell(self.section_table,r,1),"start":start,"end":min(end,duration),"repeat_of":cell(self.section_table,r,4) or None})
            ids=[s["id"] for s in sections]
            if len(ids)!=len(set(ids)) or "" in ids:
                raise ValueError("Abschnitt-IDs müssen eindeutig und ausgefüllt sein.")
            for section in sections:
                if section["repeat_of"] and (section["repeat_of"] not in ids or section["repeat_of"]==section["id"]):
                    raise ValueError("Eine Wiederholung muss auf die ID eines anderen vorhandenen Abschnitts verweisen.")
            a.update(beats=beats,lines=sorted(lines,key=lambda x:x["start"]),sections=sections)
            self.project["audio"]=a
            self.project.pop("analysis_draft",None)
            self.analysis_dirty=False
            self._invalidate_plan()
            self._edited()
            self._refresh()
            if notify:
                self._notify("Beat-, Text- und Abschnittskorrekturen übernommen.")
            return True
        except (ValueError,TypeError) as error:
            self._error(error)
            return False

    def play_song(self, start=None, toggle=True):
        if not self.project.get("audio_path"):
            return
        from PySide6.QtMultimedia import QAudioOutput,QMediaPlayer
        if not hasattr(self,"player"):
            self.player=QMediaPlayer(self)
            self.audio_output=QAudioOutput(self)
            self.audio_output.setVolume(0.7)
            self.player.setAudioOutput(self.audio_output)
        url=QUrl.fromLocalFile(self.project["audio_path"])
        if self.player.source()!=url:
            self.player.setSource(url)
        if toggle and self.player.playbackState()==QMediaPlayer.PlaybackState.PlayingState:
            self.player.pause()
            self._notify("Wiedergabe pausiert.")
            return
        if start is None:
            row=self.line_table.currentRow()
            if row>=0:
                try:
                    start=float(cell(self.line_table,row,0).replace(",","."))
                except ValueError:
                    start=None
        if start is not None:
            self.player.setPosition(int(max(0.0,start)*1000))
        self.player.play()
        self._notify("Wiedergabe" + (f" ab {start:.2f} s" if start is not None else "") + " · „Song anhören“ pausiert.")

    def _ready_for_plan(self):
        if self.analysis_dirty:
            pending=self.plan_edit.toPlainText()
            if not self.apply_analysis_edits(notify=False):
                return False
            if pending:
                self.plan_edit.setPlainText(pending)
        self._sync_form()
        if not self.project.get("clips") or not self.project.get("audio",{}).get("duration"):
            self._error("Lies zuerst Videoclips ein und analysiere den Song.")
            return False
        return True

    def copy_prompt(self):
        if self._ready_for_plan():
            try:
                parts=build_prompt_parts(self.project)
                if len(parts)==1:
                    QApplication.clipboard().setText(parts[0])
                    self._notify("Analyse-Prompt kopiert. Füge ihn in ChatGPT ein und übernimm anschließend die JSON-Antwort.")
                else:
                    dialog=QDialog(self)
                    dialog.setWindowTitle("Analyse-Prompt in Teilen")
                    dialog.resize(800,600)
                    layout=QVBoxLayout(dialog)
                    layout.addWidget(label(f"Dieses Projekt hat {len(parts)} Teile. Kopiere jeden Prompt nach ChatGPT. Füge danach alle JSON-Antworten nacheinander in das Antwortfeld ein; die App fügt sie zusammen.","subtitle"))
                    selection=QComboBox()
                    selection.addItems([f"Teil {i+1} von {len(parts)}" for i in range(len(parts))])
                    preview=QPlainTextEdit(parts[0])
                    preview.setReadOnly(True)
                    selection.currentIndexChanged.connect(lambda i:preview.setPlainText(parts[i]))
                    layout.addWidget(selection)
                    layout.addWidget(preview,1)
                    row=QHBoxLayout()
                    row.addWidget(button("Diesen Teil kopieren",lambda:QApplication.clipboard().setText(parts[selection.currentIndex()]),True))
                    row.addStretch()
                    row.addWidget(button("Schließen",dialog.accept))
                    layout.addLayout(row)
                    dialog.exec()
            except Exception as error:
                self._error(error)

    def save_prompt(self):
        if not self._ready_for_plan():
            return
        try:
            parts=build_prompt_parts(self.project)
            path,_=QFileDialog.getSaveFileName(self,"Analyse-Prompt speichern","analyse-prompt.txt","Textdatei (*.txt)")
            if path:
                text="\n\n".join(f"=== TEIL {i+1} VON {len(parts)} ===\n\n{part}" for i,part in enumerate(parts)) if len(parts)>1 else parts[0]
                Path(path).write_text(text,encoding="utf-8")
        except Exception as error:
            self._error(error)

    def _style_changed(self, *_):
        if self.updating:
            return
        self._sync_form()
        self.chorus_beats.setEnabled(self.chorus_faster.isChecked())
        self._edited()

    def reroll_style(self):
        import random
        self.project.setdefault("cut_style", default_cut_style())["seed"] = random.randint(1, 2 ** 31 - 1)
        self._edited()
        self.basic_plan()

    def generate_plan(self):
        if not self._ready_for_plan():
            return
        provider=self.provider.currentText()
        if provider=="OpenAI" and not self.api_key:
            try:
                self.api_key=keychain_get() or ""
            except Exception:
                pass
            if not self.api_key:
                self.settings()
            if not self.api_key:
                return
        model=self.config.get("openai_model","gpt-4.1-mini") if provider=="OpenAI" else self.config.get("director_model","qwen2.5:7b")
        def done(text):
            self.plan_edit.setPlainText(text)
            self.accept_plan()
        self._start_job("direct",{"provider":provider,"model":model,"base_url":self.config.get("ollama_url","http://localhost:11434"),"project":self.project},done)

    def basic_plan(self):
        if not self._ready_for_plan():
            return
        try:
            plan=draft_plan(self.project)
            self.plan_edit.setPlainText(json.dumps(plan,ensure_ascii=False,indent=2))
            self.accept_plan()
        except Exception as error:
            self._error(error)

    def accept_plan(self):
        if not self._ready_for_plan():
            return False
        try:
            plan=merge_plan_parts(self.plan_edit.toPlainText())
            plan=apply_repeats(self.project,plan)
            errors=validate_plan(self.project,plan)
            if errors:
                raise ValueError("\n".join(errors[:20]))
            compile_timeline(self.project,plan)
            self.project["plan"]=plan
            self.plan_edit.setPlainText(json.dumps(plan,ensure_ascii=False,indent=2))
            self._edited()
            self._refresh_timeline()
            self._update_steps()
            self._notify("Schnittplan geprüft und übernommen.")
            return True
        except Exception as error:
            self.plan_status.setText("Schnittplan enthält Fehler.")
            self._error(error)
            return False

    def export(self):
        if not self.accept_plan():
            return
        formats=[]
        for check,name in [(self.format_fcpxml,"timeline.fcpxml"),(self.format_xml,"timeline.xml"),(self.format_edl,"timeline.edl"),(self.format_otio,"timeline.otio")]:
            if check.isChecked():
                formats.append(name)
        if not formats:
            self._error("Wähle mindestens ein Exportformat.")
            return
        missing=[c["path"] for c in self.project["clips"] if not Path(c["path"]).is_file()]
        if not Path(self.project["audio_path"]).is_file():
            missing.append(self.project["audio_path"])
        if missing:
            self._error("Mediendateien fehlen. Stelle sie wieder her oder lies den Ordner neu ein.","\n".join(missing))
            return
        destination=QFileDialog.getExistingDirectory(self,"Exportordner auswählen")
        if not destination:
            return
        existing=[name for name in formats+["clip-katalog.json","schnittplan.json"] if (Path(destination)/name).exists()]
        if existing and QMessageBox.question(self,"Dateien ersetzen","Diese Exportdateien existieren bereits und werden ersetzt:\n\n"+"\n".join(existing))!=QMessageBox.StandardButton.Yes:
            return
        def done(paths):
            self.project["last_export"] = {"folder": destination, "formats": formats, "at": time.strftime("%Y-%m-%d %H:%M")}
            self._edited()
            self._update_steps()
            self.export_result.setText("Exportiert:\n"+"\n".join(paths))
            self._notify("Timeline und Projektkatalog exportiert.")
            QDesktopServices.openUrl(QUrl.fromLocalFile(destination))
        self._start_job("export",{"project":self.project,"destination":destination,"formats":formats},done)

    def settings(self):
        if self.job:
            return
        if not self.api_key:
            try:
                self.api_key=keychain_get() or ""
            except Exception:
                pass
        dialog=SettingsDialog(self.config,self)
        if dialog.exec()==QDialog.DialogCode.Accepted:
            values=dialog.values()
            try:
                from .services import OllamaManager
                OllamaManager(values["ollama_url"])
            except ValueError as error:
                self._error(error)
                return
            self.config.update(values)
            self.api_key=dialog.key.text().strip()
            self.config_path.write_text(json.dumps(self.config,indent=2),encoding="utf-8")
            if dialog.remember.isChecked():
                try:
                    keychain_set(self.api_key)
                except Exception as error:
                    self._error(f"Einstellungen gespeichert; Schlüsselbund konnte nicht aktualisiert werden: {error}")
            self._notify("Einstellungen gespeichert.")

    def download_model(self):
        dialog=QDialog(self)
        dialog.setWindowTitle("Modell herunterladen")
        layout=QVBoxLayout(dialog)
        layout.addWidget(label("Whisper oder ein lokales Ollama-Modell herunterladen. Downloads benötigen je nach Modell mehrere GB.","subtitle"))
        kind=QComboBox()
        kind.addItems(["Ollama","Whisper"])
        name=QLineEdit(self.config.get("vision_model","qwen2.5vl:7b"))
        layout.addWidget(kind)
        layout.addWidget(name)
        size_hint=label("","subtitle")
        layout.addWidget(size_hint)
        layout.addWidget(label(f"Speicherort: {models_dir(self.config)}  (änderbar unter Modelle & Einstellungen)","path"))
        def update_size(*_):
            size_hint.setText(model_size_hint(name.text(),self.config))
        name.textChanged.connect(update_size)
        update_size()
        kind.currentTextChanged.connect(lambda x:name.setText(self.config.get("whisper_model","mlx-community/whisper-small-mlx") if x=="Whisper" else self.config.get("vision_model","qwen2.5vl:7b")))
        controls=QDialogButtonBox(QDialogButtonBox.StandardButton.Ok|QDialogButtonBox.StandardButton.Cancel)
        controls.accepted.connect(dialog.accept)
        controls.rejected.connect(dialog.reject)
        layout.addWidget(controls)
        if dialog.exec()==QDialog.DialogCode.Accepted and name.text().strip():
            self._start_job("whisper_model" if kind.currentText()=="Whisper" else "pull",{"model":name.text().strip(),"base_url":self.config.get("ollama_url","http://localhost:11434")},lambda _:self._notify("Modell heruntergeladen und bereit."))

    def list_models(self):
        self._start_job("models",{"base_url":self.config.get("ollama_url","http://localhost:11434")},lambda models:QMessageBox.information(self,"Lokale Ollama-Modelle",json.dumps(models,ensure_ascii=False,indent=2)))

    def _start_job(self,action,payload,callback):
        if self.job:
            return
        self._sync_form()
        jobdir=app_support()/"jobs"
        jobdir.mkdir(parents=True,exist_ok=True)
        token=uuid.uuid4().hex
        self.request_path=jobdir/(token+".request.json")
        self.response_path=jobdir/(token+".response.json")
        self.request_path.write_text(json.dumps({"action":action,"payload":payload},ensure_ascii=False),encoding="utf-8")
        self.request_path.chmod(0o600)
        self.job_callback=callback
        self.job_cancelled=False
        self.stdout_buffer=""
        self.stderr_tail=""
        process=QProcess(self)
        self.job=process
        environment=QProcessEnvironment.systemEnvironment()
        if self.api_key and action=="direct" and payload.get("provider")=="OpenAI":
            environment.insert("VC_OPENAI_KEY",self.api_key)
        environment.insert("PYTHONUNBUFFERED","1")
        if self.config.get("models_dir"):
            environment.insert("VC_MODEL_DIR",self.config["models_dir"])
        process.setProcessEnvironment(environment)
        process.readyReadStandardOutput.connect(self._read_progress)
        process.readyReadStandardError.connect(self._read_error_output)
        process.finished.connect(self._job_finished)
        process.errorOccurred.connect(self._job_error)
        args=[] if getattr(sys,"frozen",False) else [str(Path(__file__).resolve().parents[1]/"main.py")]
        args += ["--worker",str(self.request_path),str(self.response_path)]
        self.pages.setEnabled(False)
        self.navigation.setEnabled(False)
        self.menuBar().setEnabled(False)
        self.cancel_button.show()
        self.progress_bar.setRange(0,0)
        self._notify("Aufgabe wird gestartet …")
        process.start(sys.executable,args)

    def _read_progress(self):
        if not self.job:
            return
        self.stdout_buffer+=bytes(self.job.readAllStandardOutput()).decode("utf-8",errors="replace")
        while "\n" in self.stdout_buffer:
            line,self.stdout_buffer=self.stdout_buffer.split("\n",1)
            try:
                event=json.loads(line)
            except ValueError:
                continue
            if event.get("event")=="progress":
                self._notify(event["message"])
                fraction=float(event.get("fraction",0))
                if fraction>0:
                    self.progress_bar.setRange(0,1000)
                    self.progress_bar.setValue(int(fraction*1000))

    def _read_error_output(self):
        if self.job:
            self.stderr_tail=(self.stderr_tail+bytes(self.job.readAllStandardError()).decode("utf-8",errors="replace"))[-12000:]

    def _job_error(self,error):
        if error==QProcess.ProcessError.FailedToStart:
            self._job_finished(-1,QProcess.ExitStatus.CrashExit)

    def _job_finished(self,*_):
        if self.job is None:
            return
        self._read_error_output()
        process=self.job
        self.job=None
        self.pages.setEnabled(True)
        self.navigation.setEnabled(True)
        self.menuBar().setEnabled(True)
        self.cancel_button.hide()
        self.progress_bar.setRange(0,1000)
        self.progress_bar.setValue(0 if self.job_cancelled else 1000)
        try:
            if self.job_cancelled:
                self._notify("Aufgabe abgebrochen. Bereits gespeicherte Analysen bleiben erhalten.")
                return
            if not self.response_path.exists():
                raise RuntimeError("Der Analyseprozess wurde unerwartet beendet. Details stehen im Fehlerprotokoll.")
            response=json.loads(self.response_path.read_text(encoding="utf-8"))
            if not response.get("ok"):
                self._error(response.get("error","Unbekannter Fehler"),response.get("detail",self.stderr_tail))
                self._notify("Aufgabe fehlgeschlagen. Einstellungen und Medien prüfen.")
                return
            self._notify("Aufgabe abgeschlossen.")
            self.job_callback(response.get("result"))
        except Exception as error:
            self._error(error,self.stderr_tail)
        finally:
            for path in [self.request_path,self.response_path]:
                if path:
                    path.unlink(missing_ok=True)
            process.deleteLater()

    def cancel_job(self):
        if self.job:
            self.job_cancelled=True
            self._notify("Aufgabe wird abgebrochen …")
            process=self.job
            process.terminate()
            QTimer.singleShot(4000,lambda:process.kill() if self.job is process else None)

    def _confirm_discard(self):
        if self.job:
            self._error("Beende oder stoppe zuerst die laufende Aufgabe.")
            return False
        if not self.dirty:
            return True
        answer=QMessageBox.question(self,"Projekt sichern","Änderungen vor dem Fortfahren speichern?",QMessageBox.StandardButton.Save|QMessageBox.StandardButton.Discard|QMessageBox.StandardButton.Cancel)
        if answer==QMessageBox.StandardButton.Cancel:
            return False
        if answer==QMessageBox.StandardButton.Save:
            return self.save_project()
        return True

    def new_project(self):
        if self._confirm_discard():
            self.project=new_project()
            self.project_path=None
            self.dirty=False
            self.setWindowFilePath("")
            self._refresh()
            self.navigation.setCurrentRow(0)

    def open_project(self):
        if not self._confirm_discard():
            return
        path,_=QFileDialog.getOpenFileName(self,"Projekt öffnen","",PROJECT_FILTER)
        if path:
            self.open_project_path(path,confirm=False)

    def open_project_path(self,path,confirm=True):
        if confirm and not self._confirm_discard():
            return
        previous,previous_path,previous_dirty=self.project,self.project_path,self.dirty
        try:
            loaded=load_project(path)
            loaded["clips"]=recover_pending_rename(loaded["clips"])
            self.project=loaded
            self.project_path=str(path)
            self.dirty=False
            self._refresh()
            remember_project(path)
            self._notify(f"Projekt geöffnet: {Path(path).name}")
        except Exception as error:
            self.project,self.project_path,self.dirty=previous,previous_path,previous_dirty
            self._refresh()
            self._error(error)

    def save_project(self,save_as=False):
        self._sync_form()
        path=self.project_path
        if save_as or not path:
            path,_=QFileDialog.getSaveFileName(self,"Projekt speichern",self.project["name"]+PROJECT_SUFFIX,PROJECT_FILTER)
            if path and Path(path).suffix.lower() not in PROJECT_SUFFIXES:
                path += PROJECT_SUFFIX
        if not path:
            return False
        try:
            save_project(self.project,path)
            self.project_path=path
            self.dirty=False
            remember_project(path)
            self._update_title()
            self._notify(f"Projekt gespeichert: {Path(path).name}")
            return True
        except Exception as error:
            self._error(error)
            return False

    def show_help(self):
        root=Path(getattr(sys,"_MEIPASS",Path(__file__).resolve().parents[1]))
        path=root/"BEDIENUNG.html"
        if path.exists():
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))
        else:
            QMessageBox.information(self,APP_NAME,"1. Medien auswählen\n2. Clips mit Vision beschreiben\n3. Song analysieren und Positionen prüfen\n4. KI-Regie oder ChatGPT-Prompt nutzen\n5. JSON prüfen und Timeline exportieren")

    def closeEvent(self,event):
        if self.job:
            if QMessageBox.question(self,"Laufende Aufgabe","Aufgabe abbrechen und App schließen?")!=QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.cancel_job()
            if self.job:
                self.job.waitForFinished(4500)
                if self.job:
                    self.job.kill()
                    self.job.waitForFinished(1000)
        self._autosave()
        event.accept()


class CreatorApplication(QApplication):
    def event(self,event):
        if event.type()==QEvent.Type.FileOpen:
            path=event.file()
            window=getattr(self,"main_window",None)
            if window is not None:
                QTimer.singleShot(0,lambda:window.open_project_path(path))
            else:
                self.pending_project=path
            return True
        return super().event(event)


def run_app(argv):
    application=CreatorApplication(argv)
    application.setApplicationName(APP_NAME)
    application.setApplicationDisplayName(APP_NAME)
    application.setOrganizationName(APP_NAME)
    application.setApplicationVersion(__version__)
    application.setWindowIcon(app_icon())
    application.setStyle("Fusion")
    application.setStyleSheet(STYLE)
    window=MainWindow()
    application.main_window=window
    window.show()
    project_path=getattr(application,"pending_project",None)
    if not project_path:
        project_path=next((arg for arg in argv[1:] if not arg.startswith("-") and Path(arg).suffix.lower() in {*PROJECT_SUFFIXES,".json"} and Path(arg).is_file()),None)
    if project_path:
        QTimer.singleShot(0,lambda:window.open_project_path(project_path,confirm=False))
    return application.exec()
