import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Das Systemmodell von Apple Intelligence (Foundation Models): kein Download, läuft auf dem Mac.
/// Text ab macOS 26, Bilder ab macOS 27. Das Schema wird über `DynamicGenerationSchema` erzwungen.
public struct AppleIntelligenceProvider: LanguageModelProvider {
    public init() {}

    public var kind: ProviderKind { .appleIntelligence }
    public var modelName: String { "Apple Intelligence" }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            vision: Self.supportsImages, structuredOutput: true, contextTokens: 8192, isCloud: false)
    }

    public static var supportsImages: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    /// Verfügbar heißt: macOS 26+, Apple Intelligence eingeschaltet und das Modell geladen.
    public static var availability: (available: Bool, reason: String) {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return (true, "Bereit")
                case .unavailable(.deviceNotEligible):
                    return (false, "Dieser Mac unterstützt Apple Intelligence nicht.")
                case .unavailable(.appleIntelligenceNotEnabled):
                    return (false, "Apple Intelligence ist ausgeschaltet (Systemeinstellungen).")
                case .unavailable(.modelNotReady): return (false, "Das Modell wird noch geladen.")
                case .unavailable: return (false, "Apple Intelligence ist nicht verfügbar.")
                }
            }
        #endif
        return (false, "Apple Intelligence braucht macOS 26 oder neuer.")
    }

    public func testConnection() async throws -> String {
        let state = Self.availability
        guard state.available else { throw ProviderError.unavailable(state.reason) }
        return Self.supportsImages ? "Bereit für Text und Bilder." : "Bereit für Text (Bilder ab macOS 27)."
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                let state = Self.availability
                guard state.available else { throw ProviderError.unavailable(state.reason) }
                let start = DispatchTime.now().uptimeNanoseconds
                let session = LanguageModelSession(instructions: request.instructions)
                let options = GenerationOptions(
                    temperature: request.temperature, maximumResponseTokens: request.maxTokens)
                let text: String
                if let schema = request.schema {
                    let generation = try GenerationSchema(root: Self.dynamic(schema), dependencies: [])
                    let content: GeneratedContent
                    if !request.images.isEmpty {
                        guard #available(macOS 27, *) else {
                            throw ProviderError.unavailable(
                                "Bildbeschreibungen mit Apple Intelligence brauchen macOS 27.")
                        }
                        content = try await session.respond(schema: generation, options: options) {
                            request.prompt
                            for (index, url) in request.images.enumerated() {
                                Attachment(imageURL: url).label("s\(index + 1)")
                            }
                        }.content
                    } else {
                        content = try await session.respond(to: request.prompt, schema: generation, options: options)
                            .content
                    }
                    text = content.jsonString
                } else {
                    text = try await session.respond(to: request.prompt, options: options).content
                }
                return GenerationResult(text: text, model: modelName, seconds: elapsed(since: start))
            }
        #endif
        throw ProviderError.unavailable(Self.availability.reason)
    }

    #if canImport(FoundationModels)
        @available(macOS 26, *)
        static func dynamic(_ schema: JSONSchema, name: String = "Antwort") -> DynamicGenerationSchema {
            switch schema {
            case .object(let objectName, let description, let properties):
                return DynamicGenerationSchema(
                    name: objectName, description: description,
                    properties: properties.map { property in
                        DynamicGenerationSchema.Property(
                            name: property.name, description: property.schema.description,
                            schema: dynamic(property.schema, name: property.name), isOptional: !property.required)
                    })
            case .array(_, let items, let minimum, let maximum):
                return DynamicGenerationSchema(
                    arrayOf: dynamic(items, name: name + "Eintrag"), minimumElements: minimum, maximumElements: maximum)
            case .string(let description, let choices):
                if let choices { return DynamicGenerationSchema(name: name, description: description, anyOf: choices) }
                return DynamicGenerationSchema(type: String.self)
            case .number:
                return DynamicGenerationSchema(type: Double.self)
            }
        }
    #endif
}
