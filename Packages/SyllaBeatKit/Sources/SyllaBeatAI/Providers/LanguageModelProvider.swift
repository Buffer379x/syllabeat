import Foundation

/// Eine Anfrage an ein Sprach- oder Bildmodell.
public struct GenerationRequest: Sendable {
    /// Rolle und Regeln (Systemnachricht).
    public var instructions: String
    public var prompt: String
    /// Bilder (JPEG/PNG), z. B. Vorschaubilder der Szenen.
    public var images: [URL]
    /// Erwartete Antwortstruktur; `nil` heißt freier Text.
    public var schema: JSONSchema?
    public var maxTokens: Int
    public var temperature: Double

    public init(
        instructions: String, prompt: String, images: [URL] = [], schema: JSONSchema? = nil, maxTokens: Int = 1500,
        temperature: Double = 0.3
    ) {
        self.instructions = instructions
        self.prompt = prompt
        self.images = images
        self.schema = schema
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    /// Prompt mit Feldbeschreibung für Anbieter, die kein Schema erzwingen können.
    public var promptWithOutline: String {
        guard let schema else { return prompt }
        return prompt + "\n\nAntworte ausschließlich mit einem JSON-Objekt mit diesen Feldern:\n" + schema.outline()
    }
}

public struct GenerationResult: Sendable, Equatable {
    public var text: String
    /// Modell, das geantwortet hat (für die Anzeige und `visionModel`).
    public var model: String
    public var seconds: Double

    public init(text: String, model: String, seconds: Double) {
        self.text = text
        self.model = model
        self.seconds = seconds
    }
}

public struct ProviderCapabilities: Sendable, Equatable {
    public var vision: Bool
    /// Der Anbieter erzwingt das Schema selbst (sonst Prompt plus Prüfung).
    public var structuredOutput: Bool
    public var contextTokens: Int
    /// Daten verlassen den Mac.
    public var isCloud: Bool

    public init(vision: Bool, structuredOutput: Bool, contextTokens: Int, isCloud: Bool) {
        self.vision = vision
        self.structuredOutput = structuredOutput
        self.contextTokens = contextTokens
        self.isCloud = isCloud
    }
}

public protocol LanguageModelProvider: Sendable {
    var kind: ProviderKind { get }
    /// Modellname für die Anzeige.
    var modelName: String { get }
    var capabilities: ProviderCapabilities { get }
    func generate(_ request: GenerationRequest) async throws -> GenerationResult
    /// „Verbindung testen“: kurze Rückmeldung oder ein verständlicher Fehler.
    func testConnection() async throws -> String
}

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case appleIntelligence, mlx, ollama, openAICompatible, anthropic, manual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence (auf dem Mac)"
        case .mlx: "Lokales Modell (MLX)"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-kompatibel (LM Studio, OpenAI, …)"
        case .anthropic: "Anthropic Claude"
        case .manual: "Manuell (Prompt kopieren)"
        }
    }

    /// Anbieter, deren Server nicht auf diesem Mac läuft (OpenAI-kompatibel hängt von der Adresse ab).
    public var mayBeCloud: Bool { self == .anthropic || self == .openAICompatible }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case notConfigured(String)
    case unavailable(String)
    case http(status: Int, message: String)
    case offline(String)
    case invalidAnswer([String])
    /// Manueller Anbieter: Der Prompt muss von Hand an ein Modell gegeben werden.
    case manual(prompt: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let detail): "Der KI-Anbieter ist nicht eingerichtet: \(detail)"
        case .unavailable(let detail): detail
        case .http(let status, let message):
            switch status {
            case 401, 403: "Der Schlüssel wurde abgelehnt (\(status)). Bitte in den Einstellungen prüfen."
            case 404: "Modell oder Adresse nicht gefunden (404): \(message)"
            case 429: "Zu viele Anfragen oder Kontingent erschöpft (429). Später erneut versuchen."
            default: "Der Anbieter meldet einen Fehler (\(status)): \(message)"
            }
        case .offline(let host): "\(host) ist nicht erreichbar. Netzwerk oder Server prüfen."
        case .invalidAnswer(let problems):
            "Die Antwort des Modells passt nicht zum erwarteten Format: \(problems.prefix(3).joined(separator: "; "))"
        case .manual: "Den Prompt kopieren, an ein Modell geben und die Antwort einfügen."
        }
    }
}

/// Strukturierte Antwort: erzeugen, JSON herauslösen, prüfen; bei Abweichung ein gezielter Korrekturversuch.
public enum StructuredGeneration {
    public struct Outcome: Sendable {
        /// Geprüftes JSON-Objekt.
        public var data: Data
        public var result: GenerationResult
        /// 1 = gleich gültig, 2 = nach Korrektur.
        public var attempts: Int

        public func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: data)
        }
    }

    public static func run(_ provider: any LanguageModelProvider, _ request: GenerationRequest) async throws -> Outcome
    {
        guard let schema = request.schema else {
            throw ProviderError.notConfigured("Strukturierte Antwort ohne Schema")
        }
        var current = request
        var lastProblems: [String] = []
        var seconds = 0.0
        for attempt in 1...2 {
            let result = try await provider.generate(current)
            seconds += result.seconds
            let (data, problems) = parse(result.text, schema: schema)
            if let data, problems.isEmpty {
                var final = result
                final.seconds = seconds
                return Outcome(data: data, result: final, attempts: attempt)
            }
            lastProblems = problems
            current.prompt =
                request.prompt
                + "\n\nDeine letzte Antwort war ungültig (\(problems.prefix(5).joined(separator: "; "))). "
                + "Antworte erneut, ausschließlich mit gültigem JSON nach dem Schema."
        }
        throw ProviderError.invalidAnswer(lastProblems)
    }

    /// Antworttext → geprüftes JSON. Auch für eingefügte Antworten des manuellen Anbieters.
    public static func parse(_ text: String, schema: JSONSchema) -> (Data?, [String]) {
        guard let object = JSONExtraction.object(in: text) as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            return (nil, ["kein JSON-Objekt gefunden"])
        }
        return (data, schema.violations(of: object))
    }
}
