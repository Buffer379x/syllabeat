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

public struct AddClips: EditCommand {
    public var clips: [Clip]
    public init(clips: [Clip]) { self.clips = clips }

    public var actionName: String { clips.count == 1 ? "Clip hinzufügen" : "\(clips.count) Clips hinzufügen" }

    /// Clips mit bereits vorhandener ID (gleicher Fingerprint) werden übersprungen.
    public func apply(to project: inout Project) throws {
        let existing = Set(project.clips.map(\.id))
        var seen = existing
        project.clips += clips.filter { seen.insert($0.id).inserted }
    }
}

public struct RemoveClips: EditCommand {
    public var clipIDs: Set<String>
    public init(clipIDs: Set<String>) { self.clipIDs = clipIDs }

    public var actionName: String { clipIDs.count == 1 ? "Clip entfernen" : "\(clipIDs.count) Clips entfernen" }

    /// Clips, die im Schnitt verwendet werden, bleiben erhalten; dafür gibt es „Nie verwenden“.
    public func apply(to project: inout Project) throws {
        let used = Set((project.cut?.shots ?? []).map(\.clipID))
        let blocked = clipIDs.intersection(used)
        guard blocked.isEmpty else {
            throw EditError.invalidValue(
                "\(blocked.count == 1 ? "Ein Clip wird" : "\(blocked.count) Clips werden") im Schnitt verwendet. "
                    + "Mit „Nie verwenden“ lässt er sich aus dem nächsten Schnitt heraushalten.")
        }
        project.clips.removeAll { clipIDs.contains($0.id) }
    }
}

public struct SetSong: EditCommand {
    public var song: MediaRef?
    public init(song: MediaRef?) { self.song = song }

    public var actionName: String { "Song wählen" }

    /// Ein anderer Song verwirft Analyse und Schnitt, denn beide hängen an seinen Beats.
    public func apply(to project: inout Project) throws {
        guard project.song?.fingerprint != song?.fingerprint || project.song?.path != song?.path else { return }
        project.song = song
        project.analysis = nil
        project.cut = nil
        project.variants = []
    }
}

public struct SetClipDescription: EditCommand {
    public var clipID: String
    public var description: String
    public init(clipID: String, description: String) {
        self.clipID = clipID
        self.description = description
    }

    public var actionName: String { "Beschreibung ändern" }

    public func apply(to project: inout Project) throws {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        try project.updateClip(clipID) { $0.description = text }
    }
}

public struct SetClipTags: EditCommand {
    public var clipID: String
    public var tags: [String]
    public init(clipID: String, tags: [String]) {
        self.clipID = clipID
        self.tags = tags
    }

    public var actionName: String { "Schlagwörter ändern" }

    public func apply(to project: inout Project) throws {
        var seen = Set<String>()
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        try project.updateClip(clipID) { $0.tags = cleaned }
    }
}

public struct SetClipRating: EditCommand {
    public var clipID: String
    public var rating: Int?
    public init(clipID: String, rating: Int?) {
        self.clipID = clipID
        self.rating = rating
    }

    public var actionName: String { "Bewertung ändern" }

    public func apply(to project: inout Project) throws {
        guard rating.map({ (1...5).contains($0) }) ?? true else {
            throw EditError.invalidValue("Die Bewertung muss zwischen 1 und 5 Sternen liegen.")
        }
        try project.updateClip(clipID) { $0.rating = rating }
    }
}

extension Project {
    mutating func updateClip(_ id: String, _ change: (inout Clip) -> Void) throws {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { throw EditError.unknownClip(id) }
        change(&clips[index])
    }

    /// Wie oft ein Clip im aktiven Schnitt vorkommt.
    public func usageCount(of clipID: String) -> Int {
        cut?.shots.filter { $0.clipID == clipID }.count ?? 0
    }
}
