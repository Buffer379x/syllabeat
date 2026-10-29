import Foundation
import ImageIO

/// Gemeinsames für Anbieter mit HTTP-Schnittstelle: JSON senden, Fehler verständlich machen.
struct HTTPJSON: Sendable {
    var session: URLSession
    var timeout: TimeInterval = 300

    func send(
        _ url: URL, method: String = "POST", headers: [String: String] = [:], body: [String: Any]? = nil
    )
        async throws -> [String: Any]
    {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError
            where [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost]
            .contains(error.code)
        {
            throw ProviderError.offline(url.host() ?? url.absoluteString)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message =
                ((object?["error"] as? [String: Any])?["message"] as? String) ?? (object?["error"] as? String)
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ProviderError.http(status: status, message: message)
        }
        guard let object else { throw ProviderError.invalidAnswer(["Antwort ist kein JSON"]) }
        return object
    }
}

/// Bilder als Base64 mit Medientyp. HEIC (Vorschaubilder im Zwischenspeicher) wird zu JPEG, weil die Cloud-Anbieter
/// nur JPEG, PNG, GIF und WebP annehmen.
enum ImagePayload {
    static func load(_ url: URL) throws -> (mediaType: String, base64: String) {
        switch url.pathExtension.lowercased() {
        case "png": return ("image/png", try Data(contentsOf: url).base64EncodedString())
        case "jpg", "jpeg": return ("image/jpeg", try Data(contentsOf: url).base64EncodedString())
        default: return ("image/jpeg", try jpeg(url).base64EncodedString())
        }
    }

    static func jpeg(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ProviderError.unavailable("Bild nicht lesbar: \(url.lastPathComponent)") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw ProviderError.unavailable("JPEG nicht erzeugt")
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProviderError.unavailable("JPEG nicht erzeugt") }
        return data as Data
    }
}

func elapsed(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

/// Ollama (`/api/chat`), lokal oder im Netz. Das Schema geht als `format` mit.
public struct OllamaProvider: LanguageModelProvider {
    public var baseURL: URL
    public var model: String
    var http: HTTPJSON

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.http = HTTPJSON(session: session)
    }

    public var kind: ProviderKind { .ollama }
    public var modelName: String { model }
    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(vision: true, structuredOutput: true, contextTokens: 8192, isCloud: false)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let start = DispatchTime.now().uptimeNanoseconds
        var user: [String: Any] = ["role": "user", "content": request.promptWithOutline]
        if !request.images.isEmpty { user["images"] = try request.images.map { try ImagePayload.load($0).base64 } }
        var body: [String: Any] = [
            "model": model, "stream": false,
            "messages": [["role": "system", "content": request.instructions], user],
            "options": ["temperature": request.temperature, "num_predict": request.maxTokens],
        ]
        if let schema = request.schema { body["format"] = schema.dictionary }
        let answer = try await http.send(baseURL.appending(path: "api/chat"), body: body)
        guard let text = (answer["message"] as? [String: Any])?["content"] as? String else {
            throw ProviderError.invalidAnswer(["message.content fehlt"])
        }
        return GenerationResult(text: text, model: model, seconds: elapsed(since: start))
    }

    public func models() async throws -> [String] {
        let answer = try await http.send(baseURL.appending(path: "api/tags"), method: "GET")
        return ((answer["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
    }

    public func testConnection() async throws -> String {
        let names = try await models()
        guard names.contains(model) else {
            throw ProviderError.notConfigured(
                "„\(model)“ ist in Ollama nicht geladen (vorhanden: \(names.prefix(5).joined(separator: ", ")))")
        }
        return "Verbunden, \(names.count) Modelle, „\(model)“ bereit."
    }
}

/// OpenAI-kompatible Server (`/v1/chat/completions`): LM Studio, llama.cpp, vLLM, OpenAI.
public struct OpenAICompatibleProvider: LanguageModelProvider {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    var http: HTTPJSON

    public init(baseURL: URL, apiKey: String? = nil, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.http = HTTPJSON(session: session)
    }

    public var kind: ProviderKind { .openAICompatible }
    public var modelName: String { model }
    /// Cloud, sobald der Server nicht auf diesem Mac oder im lokalen Netz liegt.
    public var isLocal: Bool {
        let host = baseURL.host() ?? ""
        return ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".local")
            || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(vision: true, structuredOutput: true, contextTokens: 32_000, isCloud: !isLocal)
    }

    private var headers: [String: String] {
        apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:]
    }

    /// `…/v1` darf in der Adresse stehen oder fehlen.
    private func endpoint(_ path: String) -> URL {
        baseURL.path().hasSuffix("/v1") || baseURL.path().hasSuffix("/v1/")
            ? baseURL.appending(path: path) : baseURL.appending(path: "v1").appending(path: path)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let start = DispatchTime.now().uptimeNanoseconds
        var content: [[String: Any]] = [["type": "text", "text": request.promptWithOutline]]
        for image in request.images {
            let payload = try ImagePayload.load(image)
            content.append([
                "type": "image_url", "image_url": ["url": "data:\(payload.mediaType);base64,\(payload.base64)"],
            ])
        }
        var body: [String: Any] = [
            "model": model, "temperature": request.temperature, "max_tokens": request.maxTokens,
            "messages": [
                ["role": "system", "content": request.instructions],
                ["role": "user", "content": request.images.isEmpty ? request.promptWithOutline as Any : content],
            ],
        ]
        if let schema = request.schema {
            body["response_format"] = [
                "type": "json_schema", "json_schema": ["name": "antwort", "schema": schema.dictionary],
            ]
        }
        let answer = try await http.send(endpoint("chat/completions"), headers: headers, body: body)
        guard let choice = (answer["choices"] as? [[String: Any]])?.first,
            let text = (choice["message"] as? [String: Any])?["content"] as? String
        else { throw ProviderError.invalidAnswer(["choices[0].message.content fehlt"]) }
        return GenerationResult(
            text: text, model: (answer["model"] as? String) ?? model, seconds: elapsed(since: start))
    }

    public func models() async throws -> [String] {
        let answer = try await http.send(endpoint("models"), method: "GET", headers: headers)
        return ((answer["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    public func testConnection() async throws -> String {
        let names = try await models()
        return names.contains(model)
            ? "Verbunden, „\(model)“ verfügbar."
            : "Verbunden, aber „\(model)“ fehlt in der Modellliste (\(names.count) Modelle)."
    }
}

/// Anthropic Claude (`/v1/messages`). Strukturierte Antworten über ein erzwungenes Werkzeug mit dem Schema.
public struct AnthropicProvider: LanguageModelProvider {
    public static let defaultModel = "claude-sonnet-5-5"
    public static let economyModel = "claude-haiku-5-5"

    public var apiKey: String
    public var model: String
    public var baseURL: URL
    var http: HTTPJSON

    public init(
        apiKey: String, model: String = AnthropicProvider.defaultModel,
        baseURL: URL = URL(string: "https://api.anthropic.com")!, session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.http = HTTPJSON(session: session)
    }

    public var kind: ProviderKind { .anthropic }
    public var modelName: String { model }
    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(vision: true, structuredOutput: true, contextTokens: 200_000, isCloud: true)
    }

    private var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        guard !apiKey.isEmpty else { throw ProviderError.notConfigured("Kein API-Schlüssel für Anthropic") }
        let start = DispatchTime.now().uptimeNanoseconds
        var content: [[String: Any]] = []
        for image in request.images {
            let payload = try ImagePayload.load(image)
            content.append([
                "type": "image", "source": ["type": "base64", "media_type": payload.mediaType, "data": payload.base64],
            ])
        }
        content.append(["type": "text", "text": request.prompt])
        var body: [String: Any] = [
            "model": model, "max_tokens": request.maxTokens, "temperature": request.temperature,
            "system": request.instructions, "messages": [["role": "user", "content": content]],
        ]
        if let schema = request.schema {
            body["tools"] = [
                [
                    "name": "antwort", "description": "Gibt die Antwort strukturiert zurück.",
                    "input_schema": schema.dictionary,
                ]
            ]
            body["tool_choice"] = ["type": "tool", "name": "antwort"]
        }
        let answer = try await http.send(baseURL.appending(path: "v1/messages"), headers: headers, body: body)
        let blocks = (answer["content"] as? [[String: Any]]) ?? []
        let text: String
        if let tool = blocks.first(where: { $0["type"] as? String == "tool_use" }), let input = tool["input"] {
            text = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        } else {
            text = blocks.compactMap { $0["text"] as? String }.joined()
        }
        return GenerationResult(
            text: text, model: (answer["model"] as? String) ?? model, seconds: elapsed(since: start))
    }

    public func models() async throws -> [String] {
        let answer = try await http.send(baseURL.appending(path: "v1/models"), method: "GET", headers: headers)
        return ((answer["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }

    public func testConnection() async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.notConfigured("Kein API-Schlüssel für Anthropic") }
        let names = try await models()
        return names.contains(model)
            ? "Verbunden, „\(model)“ verfügbar."
            : "Verbunden; „\(model)“ fehlt (verfügbar: \(names.prefix(4).joined(separator: ", ")))."
    }
}

/// Ohne Verbindung: Die App zeigt den Prompt zum Kopieren und prüft die eingefügte Antwort.
public struct ManualProvider: LanguageModelProvider {
    public init() {}

    public var kind: ProviderKind { .manual }
    public var modelName: String { "manuell" }
    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(vision: false, structuredOutput: false, contextTokens: 100_000, isCloud: false)
    }

    /// Vollständiger Text zum Kopieren in ein beliebiges Chatfenster.
    public static func transcript(_ request: GenerationRequest) -> String {
        request.instructions + "\n\n" + request.promptWithOutline
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        throw ProviderError.manual(prompt: Self.transcript(request))
    }

    public func testConnection() async throws -> String { "Keine Verbindung nötig." }
}
