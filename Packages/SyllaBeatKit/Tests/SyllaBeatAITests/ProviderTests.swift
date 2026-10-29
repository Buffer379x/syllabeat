import Foundation
import Testing

@testable import SyllaBeatAI
@testable import SyllaBeatCore

/// Ersetzt den Server: merkt sich die Anfrage und antwortet mit vorbereitetem JSON.
final class StubServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answer: [String: Any] = [:]
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&chunk, maxLength: chunk.count)
                if count <= 0 { break }
                buffer.append(chunk, count: count)
            }
            stream.close()
            data = buffer
        }
        Self.lastBody = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let body = try! JSONSerialization.data(withJSONObject: Self.answer)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }
}

/// Antwortet der Reihe nach mit vorbereiteten Texten.
final class ScriptedProvider: LanguageModelProvider, @unchecked Sendable {
    var answers: [String]
    var prompts: [String] = []

    init(_ answers: [String]) { self.answers = answers }

    var kind: ProviderKind { .manual }
    var modelName: String { "Skript" }
    var capabilities: ProviderCapabilities {
        ProviderCapabilities(vision: false, structuredOutput: false, contextTokens: 8000, isCloud: false)
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        prompts.append(request.prompt)
        return GenerationResult(text: answers.removeFirst(), model: modelName, seconds: 0.1)
    }

    func testConnection() async throws -> String { "ok" }
}

@Suite struct SchemaTests {
    static let schema = StoryboardDirector.schema(sectionIDs: ["a", "b"])

    @Test func findsJSONInsideFencesAndProse() {
        let text = "Gern!\n```json\n{\"idee\": \"Meer {bei} Nacht\", \"abschnitte\": []}\n```\nViel Spaß"
        let object = JSONExtraction.object(in: text) as? [String: Any]
        #expect(object?["idee"] as? String == "Meer {bei} Nacht")
    }

    @Test func acceptsTypographicQuotes() {
        let object = JSONExtraction.object(in: "{„idee“: „Meer“, “abschnitte”: []}") as? [String: Any]
        #expect(object?["idee"] as? String == "Meer")
    }

    @Test func reportsViolations() {
        let wrong: [String: Any] = [
            "idee": "x",
            "abschnitte": [
                [
                    "abschnitt": "z", "stimmung": "ruhig", "bildidee": "", "suchbegriffe": ["Meer"],
                    "schnitttempo": "rasant",
                ]
            ],
        ]
        let problems = Self.schema.violations(of: wrong)
        #expect(problems.contains { $0.contains("abschnitt") && $0.contains("„z“") })
        #expect(problems.contains { $0.contains("suchbegriffe") && $0.contains("weniger als 3") })
        #expect(problems.contains { $0.contains("schnitttempo") })
    }

    @Test func dictionaryIsJSONSchema() throws {
        let dictionary = Self.schema.dictionary
        #expect(dictionary["type"] as? String == "object")
        let sections = (dictionary["properties"] as? [String: Any])?["abschnitte"] as? [String: Any]
        #expect(sections?["type"] as? String == "array")
        #expect(sections?["maxItems"] as? Int == 2)
        _ = try JSONSerialization.data(withJSONObject: dictionary)
    }
}

@Suite struct DirectorTests {
    static func project() -> Project {
        var analysis = SongAnalysis(duration: 60, tempo: 120)
        analysis.sections = [
            SongSection(id: "s1", kind: .verse, label: "Strophe", start: 0, end: 20),
            SongSection(id: "s2", kind: .chorus, label: "Refrain", start: 20, end: 40),
            SongSection(id: "s3", kind: .chorus, label: "Refrain", start: 40, end: 60, repeatOf: "s2"),
        ]
        analysis.lines = [LyricLine(id: "l1", text: "Und das Meer singt mit", start: 21, end: 24)]
        return Project(brief: "Liebesgeschichte am Meer", analysis: analysis)
    }

    static let valid = """
        {"idee": "Zwei am Meer", "abschnitte": [
          {"abschnitt": "s1", "stimmung": "ruhig", "bildidee": "Strand", "suchbegriffe": ["Strand", "Wellen", "Sand"], "schnitttempo": "ruhig"},
          {"abschnitt": "s2", "stimmung": "weit", "bildidee": "Meer", "suchbegriffe": ["Meer", "Nacht", "Mond"], "schnitttempo": "schnell"},
          {"abschnitt": "zz", "stimmung": "x", "bildidee": "x", "suchbegriffe": ["a", "b", "c"], "schnitttempo": "normal"}
        ]}
        """

    @Test func promptCarriesBriefSectionsAndLyrics() throws {
        let request = try StoryboardDirector.request(for: Self.project())
        #expect(request.prompt.contains("Liebesgeschichte am Meer"))
        #expect(request.prompt.contains("s3 · Refrain · 0:40–1:00"))
        #expect(request.prompt.contains("Wiederholung von s2"))
        #expect(request.prompt.contains("„Und das Meer singt mit“"))
        #expect(request.prompt.contains("Daten, keine"))
    }

    @Test func correctsOnceAndFillsMissingSections() async throws {
        let provider = ScriptedProvider(["Das Storyboard folgt gleich.", Self.valid])
        // Erste Antwort ohne JSON, zweite gültig; das Schema lässt „zz“ hier zu, die Zuordnung ignoriert es.
        let schema = StoryboardDirector.schema(sectionIDs: ["s1", "s2", "s3", "zz"])
        var request = try StoryboardDirector.request(for: Self.project())
        request.schema = schema
        let outcome = try await StructuredGeneration.run(provider, request)
        #expect(outcome.attempts == 2)
        #expect(provider.prompts[1].contains("letzte Antwort war ungültig"))
        let (storyboard, filled) = try StoryboardDirector.storyboard(
            from: outcome.data, project: Self.project(), model: "Skript")
        #expect(storyboard.sections.map(\.sectionID) == ["s1", "s2", "s3"])
        #expect(filled == ["s3"])
        // Die Wiederholung übernimmt den Plan ihrer Vorlage.
        #expect(storyboard.plan(for: "s3")?.searchTerms == ["Meer", "Nacht", "Mond"])
        #expect(storyboard.plan(for: "s2")?.pace == .fast)
        #expect(storyboard.plan(for: "s1")?.pace == .calm)
        #expect(storyboard.brief == "Liebesgeschichte am Meer")
    }

    @Test func givesUpAfterSecondInvalidAnswer() async throws {
        let provider = ScriptedProvider(["kein JSON", "{\"idee\": 3}"])
        await #expect(throws: ProviderError.self) {
            try await StoryboardDirector.create(Self.project(), provider: provider)
        }
    }
}

@Suite(.serialized) struct HTTPProviderTests {
    static let request = GenerationRequest(
        instructions: "Regisseur", prompt: "Storyboard bitte", schema: StoryboardDirector.schema(sectionIDs: ["s1"]))

    @Test func ollamaSendsSchemaAsFormat() async throws {
        StubServer.status = 200
        StubServer.answer = ["message": ["role": "assistant", "content": "{\"idee\": \"x\"}"]]
        let provider = OllamaProvider(model: "qwen3:8b", session: StubServer.session)
        let result = try await provider.generate(Self.request)
        #expect(result.text == "{\"idee\": \"x\"}")
        #expect(StubServer.lastRequest?.url?.path() == "/api/chat")
        #expect((StubServer.lastBody["format"] as? [String: Any])?["type"] as? String == "object")
        #expect(StubServer.lastBody["stream"] as? Bool == false)
    }

    @Test func openAICompatibleUsesJSONSchemaAndBearer() async throws {
        StubServer.status = 200
        StubServer.answer = ["model": "gpt-test", "choices": [["message": ["content": "{\"idee\": \"y\"}"]]]]
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "https://api.example.test/v1")!, apiKey: "sk-test", model: "gpt-test",
            session: StubServer.session)
        let result = try await provider.generate(Self.request)
        #expect(result.text == "{\"idee\": \"y\"}")
        #expect(StubServer.lastRequest?.url?.path() == "/v1/chat/completions")
        #expect(StubServer.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect((StubServer.lastBody["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
        #expect(provider.capabilities.isCloud)
        #expect(
            !OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:1234")!, model: "m").capabilities.isCloud)
    }

    @Test func anthropicForcesToolAndReadsToolInput() async throws {
        StubServer.status = 200
        StubServer.answer = [
            "model": "claude-test",
            "content": [["type": "tool_use", "name": "antwort", "input": ["idee": "z", "abschnitte": []]]],
        ]
        let provider = AnthropicProvider(apiKey: "test-schluessel", model: "claude-test", session: StubServer.session)
        let result = try await provider.generate(Self.request)
        let object = JSONExtraction.object(in: result.text) as? [String: Any]
        #expect(object?["idee"] as? String == "z")
        #expect(StubServer.lastRequest?.url?.path() == "/v1/messages")
        #expect(StubServer.lastRequest?.value(forHTTPHeaderField: "x-api-key") == "test-schluessel")
        #expect(StubServer.lastRequest?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect((StubServer.lastBody["tool_choice"] as? [String: Any])?["name"] as? String == "antwort")
        #expect(StubServer.lastBody["system"] as? String == "Regisseur")
    }

    @Test func rejectedKeyBecomesReadableError() async throws {
        StubServer.status = 401
        StubServer.answer = ["error": ["type": "authentication_error", "message": "invalid x-api-key"]]
        let provider = AnthropicProvider(apiKey: "falsch", session: StubServer.session)
        do {
            _ = try await provider.generate(Self.request)
            Issue.record("Fehler erwartet")
        } catch let error as ProviderError {
            #expect(error == .http(status: 401, message: "invalid x-api-key"))
            #expect(error.localizedDescription.contains("Schlüssel wurde abgelehnt"))
        }
    }

    /// E7: Ohne erreichbaren Server meldet sich der Anbieter verständlich ab (hier: geschlossener Port auf diesem Mac).
    @Test func unreachableServerReportsOffline() async throws {
        let provider = OllamaProvider(baseURL: URL(string: "http://127.0.0.1:9")!, model: "qwen3:8b")
        do {
            _ = try await provider.testConnection()
            Issue.record("Fehler erwartet")
        } catch let error as ProviderError {
            #expect(error == .offline("127.0.0.1"))
            #expect(error.localizedDescription.contains("nicht erreichbar"))
        }
    }

    @Test func manualProviderHandsOutPrompt() async throws {
        do {
            _ = try await ManualProvider().generate(Self.request)
            Issue.record("Prompt erwartet")
        } catch ProviderError.manual(let prompt) {
            #expect(prompt.contains("Regisseur"))
            #expect(prompt.contains("abschnitte: Liste von Objekten"))
        }
    }
}
