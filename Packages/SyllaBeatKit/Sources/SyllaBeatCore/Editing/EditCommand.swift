import Foundation

/// Eine Bearbeitung des Projekts. Jede Bearbeitung läuft als Befehl, damit Undo/Redo für alles gilt.
public protocol EditCommand: Sendable {
    /// Name im Menü „Bearbeiten“, z. B. „Rückgängig: Clip ausschließen“.
    var actionName: String { get }
    func apply(to project: inout Project) throws
}

public enum EditError: Error, Equatable, LocalizedError {
    case unknownClip(String)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .unknownClip(let id): "Der Clip „\(id)“ ist nicht im Projekt."
        case .invalidValue(let reason): reason
        }
    }
}

/// Besitzer eines Projekts, der Befehle mit Undo ausführt (das Dokument der App, Tests).
@MainActor
public protocol ProjectEditing: AnyObject {
    var project: Project { get set }
}

extension ProjectEditing {
    /// Führt den Befehl aus und registriert Undo. Ändert der Befehl nichts, entsteht kein Undo-Schritt.
    public func perform(_ command: some EditCommand, undoManager: UndoManager?) throws {
        var changed = project
        try command.apply(to: &changed)
        guard changed != project else { return }
        replaceProject(with: changed, actionName: command.actionName, undoManager: undoManager)
    }

    private func replaceProject(with new: Project, actionName: String, undoManager: UndoManager?) {
        let old = project
        project = new
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { owner in
            owner.replaceProject(with: old, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }
}

// MARK: - Befehle

public struct RenameProject: EditCommand {
    public var name: String
    public init(name: String) { self.name = name }

    public var actionName: String { "Projekt umbenennen" }

    public func apply(to project: inout Project) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditError.invalidValue("Der Projektname darf nicht leer sein.") }
        project.name = trimmed
    }
}

public struct SetClipExcluded: EditCommand {
    public var clipID: String
    public var excluded: Bool
    public init(clipID: String, excluded: Bool) {
        self.clipID = clipID
        self.excluded = excluded
    }

    public var actionName: String { excluded ? "Clip ausschließen" : "Clip wieder verwenden" }

    public func apply(to project: inout Project) throws {
        guard let index = project.clips.firstIndex(where: { $0.id == clipID }) else {
            throw EditError.unknownClip(clipID)
        }
        project.clips[index].excluded = excluded
    }
}

public struct SetBrief: EditCommand {
    public var brief: String
    public init(brief: String) { self.brief = brief }

    public var actionName: String { "Regieanweisung ändern" }

    public func apply(to project: inout Project) throws {
        project.brief = brief
    }
}
