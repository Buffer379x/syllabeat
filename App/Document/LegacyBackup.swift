import Foundation
import SyllaBeatCore

/// Legt neben einem migrierten 0.2.0-Projekt eine unveränderte Kopie an, bevor es als v2 gesichert wird:
/// `Sommerlied.syllabeat` → `Sommerlied (0.2).syllabeat`.
enum LegacyBackup {
    static func backupURL(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent + " (0.2)"
        return url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(url.pathExtension)
    }

    /// Gibt die Sicherungskopie zurück; legt sie nur an, wenn die Datei noch im alten Format vorliegt.
    static func ensureBackup(of url: URL) throws -> URL? {
        let backup = backupURL(for: url)
        let manager = FileManager.default
        if manager.fileExists(atPath: backup.path) { return backup }
        let data = try Data(contentsOf: url)
        guard (try? ProjectFile.decode(data))?.migratedFrom != nil else { return nil }
        try manager.copyItem(at: url, to: backup)
        Log.document.info("Sicherungskopie im alten Format angelegt")
        return backup
    }
}
