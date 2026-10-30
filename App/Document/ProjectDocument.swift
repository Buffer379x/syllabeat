import SwiftUI
import SyllaBeatCore
import UniformTypeIdentifiers

extension UTType {
    static let syllabeatProject = UTType(exportedAs: "de.syllabeat.project", conformingTo: .json)
    /// `.vcproject` aus der Zeit vor 0.2.0 (Video Creator).
    static let syllabeatLegacyProject = UTType(exportedAs: "de.syllabeat.legacy-project", conformingTo: .json)
}

/// Dokument einer `.syllabeat`-Datei. Version-1-Dateien (0.2.0) werden beim Öffnen migriert
/// und beim Sichern als v2 geschrieben.
///
/// SwiftUI ändert und liest `project` nur auf dem Hauptthread; geschrieben wird ein Werttyp-Schnappschuss.
final class ProjectDocument: ReferenceFileDocument, @unchecked Sendable {
    static var readableContentTypes: [UTType] { [.syllabeatProject, .syllabeatLegacyProject] }
    static var writableContentTypes: [UTType] { [.syllabeatProject] }

    @Published var project: Project {
        didSet { rememberClipKnowledge(from: oldValue) }
    }
    /// Version der geöffneten Datei, falls sie migriert wurde.
    let migratedFrom: Int?

    init() {
        project = Project()
        migratedFrom = nil
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let loaded = try ProjectFile.decode(data)
        project = loaded.project
        migratedFrom = loaded.migratedFrom
        if let version = loaded.migratedFrom {
            Log.document.info("Projekt aus Format v\(version) migriert")
        }
    }

    func snapshot(contentType: UTType) throws -> Project {
        project
    }

    func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ProjectFile.encode(snapshot))
    }

    /// Markiert das Dokument als geändert, ohne einen Undo-Schritt anzulegen (setzt das Fenster).
    @MainActor var markChanged: () -> Void = {}

    /// Ergebnisse von Analysen: ändern das Dokument, landen aber nicht auf dem Undo-Stapel.
    @MainActor
    func applyAnalysis(_ change: (inout Project) -> Void) {
        var updated = project
        change(&updated)
        guard updated != project else { return }
        project = updated
        markChanged()
    }

    /// Führt einen Befehl aus und zeigt Fehler im Fenster statt still zu scheitern.
    @MainActor
    func run(_ command: some EditCommand, undoManager: UndoManager?) -> String? {
        do {
            try perform(command, undoManager: undoManager)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

extension ProjectDocument: ProjectEditing {}

extension ProjectDocument {
    /// Clip-Wissen (Sperrbereiche, Bewertung, „Nie verwenden“, eigene Merkmale) je Datei merken, damit es in anderen
    /// Projekten mit denselben Clips gilt. Läuft nach jeder Änderung, auch nach Undo und Redo.
    func rememberClipKnowledge(from old: Project) {
        guard UserDefaults.standard.object(forKey: "clipKnowledge") as? Bool ?? true else { return }
        let cache = MediaCache()
        for clip in ClipKnowledge.changes(from: old, to: project) {
            guard let fingerprint = clip.media.fingerprint else { continue }
            try? ClipKnowledge(clip).save(fingerprint: fingerprint, cache: cache)
        }
    }
}
