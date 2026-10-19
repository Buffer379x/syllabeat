"""UI/data boundary regressions, using Qt's offline platform."""
from __future__ import annotations
import json
import os
os.environ.setdefault("QT_QPA_PLATFORM","offscreen")
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PySide6.QtWidgets import QApplication
from videocreator.gui import MainWindow
from videocreator.storage import new_project,load_project


class GuiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app=QApplication.instance() or QApplication([])

    def setUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.environment=patch.dict(os.environ,{"VC_DATA_DIR":self.directory.name})
        self.environment.start()
        self.restore=patch.object(MainWindow,"_restore_autosave",lambda self:None)
        self.restore.start()
        self.window=MainWindow()
        self.errors=[]
        self.window._error=lambda error,detail=None:self.errors.append(str(error))
        project=new_project()
        project["audio"]={"duration":4.0,"beats":[0.5,1,1.5,2,2.5,3,3.5],"lines":[{"id":"line-1","start":0,"end":4,"text":"Sonne am Strand"}],"sections":[]}
        project["clips"]=[{"id":"strand","path":"/tmp/strand.mov","name":"strand.mov","original_name":"strand.mov","duration":10,"fps_num":25,"fps_den":1,"width":1920,"height":1080,"frame_count":250,"description":"Sonne am Strand"}]
        self.window.project=project
        self.window._refresh()

    def tearDown(self):
        self.window.autosave_timer.stop()
        self.window.deleteLater()
        self.app.processEvents()
        self.restore.stop()
        self.environment.stop()
        self.directory.cleanup()

    def test_manual_json_is_autosaved_before_validation(self):
        self.window.dirty=False
        self.window.plan_edit.setPlainText('{"unfertiger":"Entwurf"}')
        self.assertTrue(self.window.dirty)
        self.window._autosave()
        saved=load_project(Path(self.directory.name)/"autosave.json")
        self.assertEqual(saved["plan_draft"],'{"unfertiger":"Entwurf"}')

    def test_analysis_draft_survives_save_and_refresh(self):
        self.window.beat_table.item(0,0).setText("0.650000")
        self.window.line_table.item(0,2).setText("Korrigierter Text")
        self.window._autosave()
        saved=load_project(Path(self.directory.name)/"autosave.json")
        self.window.project=saved
        self.window._refresh()
        self.assertTrue(self.window.analysis_dirty)
        self.assertEqual(self.window.beat_table.item(0,0).text(),"0.650000")
        self.assertEqual(self.window.line_table.item(0,2).text(),"Korrigierter Text")

    def test_planning_commits_valid_table_corrections(self):
        self.window.beat_table.item(0,0).setText("0.650000")
        self.assertTrue(self.window._ready_for_plan())
        self.assertFalse(self.window.analysis_dirty)
        self.assertEqual(self.window.project["audio"]["beats"][0],0.65)
        self.assertFalse(self.errors)

    def test_invalid_table_correction_blocks_planning(self):
        self.window.beat_table.item(0,0).setText("nan")
        self.assertFalse(self.window._ready_for_plan())
        self.assertTrue(self.errors)
        self.assertEqual(self.window.project["audio"]["beats"][0],0.5)

    def test_basic_plan_reaches_export_table(self):
        self.window.basic_plan()
        self.assertFalse(self.errors)
        self.assertTrue(self.window.project["plan"])
        self.assertGreater(self.window.shot_table.rowCount(),0)
        self.assertIn("Geprüft",self.window.plan_status.text())


if __name__=="__main__":
    unittest.main()
