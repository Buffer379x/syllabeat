import Foundation
import Testing

@testable import SyllaBeatCore

@MainActor
private final class Editor: ProjectEditing {
    var project: Project
    init(_ project: Project) { self.project = project }
}

@MainActor
@Suite struct EditCommandTests {
    private func editor() -> Editor {
        let clip = Clip(
            id: "a", media: MediaRef(path: "/tmp/a.mov"),
            meta: ClipMetadata(duration: 4, fps: Rational(25), width: 1920, height: 1080))
        return Editor(Project(name: "Test", clips: [clip]))
    }

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private func step(_ manager: UndoManager, _ body: () throws -> Void) rethrows {
        manager.beginUndoGrouping()
        defer { manager.endUndoGrouping() }
        try body()
    }

    @Test func undoAndRedoRestoreEachStep() throws {
        let editor = editor()
        let manager = undoManager()
        try step(manager) { try editor.perform(SetClipExcluded(clipID: "a", excluded: true), undoManager: manager) }
        try step(manager) { try editor.perform(RenameProject(name: " Sommer "), undoManager: manager) }
        #expect(editor.project.name == "Sommer" && editor.project.clips[0].excluded)
        #expect(manager.undoActionName == "Projekt umbenennen")

        manager.undo()
        #expect(editor.project.name == "Test" && editor.project.clips[0].excluded)
        manager.undo()
        #expect(!editor.project.clips[0].excluded)
        #expect(!manager.canUndo)

        manager.redo()
        #expect(editor.project.clips[0].excluded)
        #expect(manager.undoActionName == "Clip ausschließen")
        manager.redo()
        #expect(editor.project.name == "Sommer")
        #expect(!manager.canRedo)
    }

    @Test func unchangedProjectCreatesNoUndoStep() throws {
        let editor = editor()
        let manager = UndoManager()
        try editor.perform(SetClipExcluded(clipID: "a", excluded: false), undoManager: manager)
        #expect(!manager.canUndo)
    }

    @Test func failingCommandChangesNothing() {
        let editor = editor()
        let before = editor.project
        #expect(throws: EditError.unknownClip("x")) {
            try editor.perform(SetClipExcluded(clipID: "x", excluded: true), undoManager: nil)
        }
        #expect(throws: EditError.self) { try editor.perform(RenameProject(name: "  "), undoManager: nil) }
        #expect(editor.project == before)
    }
}
