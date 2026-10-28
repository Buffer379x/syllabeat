import Foundation

/// Nachrichten zwischen App und dem XPC-Dienst `SyllaBeatInference`. Alle Modelle laufen in diesem Dienst,
/// damit ein Absturz durch Speicherdruck die App nicht mitreißt.
public enum InferenceService {
    public static let bundleIdentifier = "de.syllabeat.app.inference"
    /// Nach so vielen Sekunden ohne Anfrage beendet sich der Dienst und gibt den Modellspeicher frei.
    public static let idleTimeout: TimeInterval = 120
}

public enum InferenceRequest: Codable, Sendable, Equatable {
    case ping
    /// Bild-Embeddings für Bilddateien (Vorschaubilder im Zwischenspeicher); Reihenfolge wie `paths`.
    case embedImages(model: String, paths: [String])
    case embedText(model: String, text: String)
}

public struct InferenceStatus: Codable, Sendable, Equatable {
    public var processID: Int32
    public var version: String
    public var residentMemoryBytes: UInt64
    public var uptime: TimeInterval
    public var idleTimeout: TimeInterval

    public init(
        processID: Int32, version: String, residentMemoryBytes: UInt64, uptime: TimeInterval,
        idleTimeout: TimeInterval
    ) {
        self.processID = processID
        self.version = version
        self.residentMemoryBytes = residentMemoryBytes
        self.uptime = uptime
        self.idleTimeout = idleTimeout
    }
}

public enum InferenceResponse: Codable, Sendable, Equatable {
    case status(InferenceStatus)
    /// Ein Vektor je Eingabe; ein leerer Vektor heißt: Eingabe nicht lesbar.
    case vectors([[Float]])
    case failure(String)
}

public enum InferenceError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case remote(String)
    case unexpectedReply

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Der Inferenzdienst ist nicht erreichbar: \(reason)"
        case .remote(let reason): "Der Inferenzdienst meldet einen Fehler: \(reason)"
        case .unexpectedReply: "Der Inferenzdienst hat unerwartet geantwortet."
        }
    }
}
