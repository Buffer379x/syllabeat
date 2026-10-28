import Foundation

public enum ProjectFileError: Error, Equatable, LocalizedError {
    case tooLarge
    case notJSON
    case unsupportedVersion(Int?)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Die Projektdatei ist größer als 128 MB und kann nicht sicher geladen werden."
        case .notJSON: "Die Datei ist kein SyllaBeat-Projekt (kein gültiges JSON)."
        case .unsupportedVersion(let version?):
            "Diese Projektversion (\(version)) ist neuer als diese App. Bitte SyllaBeat aktualisieren."
        case .unsupportedVersion(nil): "Die Datei ist kein SyllaBeat-Projekt (Versionsangabe fehlt)."
        case .invalid(let reason): "Die Projektdatei ist beschädigt: \(reason)"
        }
    }
}

/// Lesen und Schreiben der `.syllabeat`-Datei (eine JSON-Datei).
public enum ProjectFile {
    public struct Loaded: Sendable {
        public var project: Project
        /// Version der gelesenen Datei, falls sie migriert wurde (z. B. 1 für 0.2.0).
        public var migratedFrom: Int?
    }

    public static let maximumSize = 128 * 1024 * 1024

    public static func decode(_ data: Data) throws -> Loaded {
        guard data.count <= maximumSize else { throw ProjectFileError.tooLarge }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProjectFileError.notJSON
        }
        guard let dictionary = object as? [String: Any] else { throw ProjectFileError.notJSON }
        let version = dictionary["version"] as? Int
        do {
            switch version {
            case 1:
                let old = try JSONDecoder().decode(LegacyV1.Project.self, from: data)
                return Loaded(project: try MigrationV1.migrate(old), migratedFrom: 1)
            case Project.formatVersion:
                let project = try JSONDecoder().decode(Project.self, from: data)
                return Loaded(project: project, migratedFrom: nil)
            default:
                throw ProjectFileError.unsupportedVersion(version)
            }
        } catch let error as ProjectFileError {
            throw error
        } catch let error as DecodingError {
            throw ProjectFileError.invalid(error.readableDescription)
        }
    }

    public static func encode(_ project: Project) throws -> Data {
        var project = project
        project.version = Project.formatVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(project)
        data.append(0x0A)
        return data
    }
}

extension DecodingError {
    var readableDescription: String {
        func path(_ context: Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0 + 1)]" } ?? $0.stringValue }
            return keys.isEmpty ? "Datei" : keys.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch self {
        case .keyNotFound(let key, let context):
            return "\(path(context)): „\(key.stringValue)“ fehlt."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(path(context)) hat den falschen Typ."
        case .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return localizedDescription
        }
    }
}
