import Foundation
import SyllaBeatCore

/// Lokales MLX-Modell (Qwen3-VL) im Inferenzdienst. Kein erzwungenes Schema: Der Prompt beschreibt die Felder,
/// die App prüft die Antwort und fragt bei Bedarf einmal nach.
public struct MLXProvider: LanguageModelProvider {
    public var package: ModelPackage
    var client: InferenceClient

    /// `client`: am besten die gemeinsame Verbindung der App, nicht für jede Anfrage eine neue.
    public init(package: ModelPackage = ModelCatalog.recommendedVision(), client: InferenceClient) {
        self.package = package
        self.client = client
    }

    public var kind: ProviderKind { .mlx }
    public var modelName: String { package.title }
    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(vision: true, structuredOutput: false, contextTokens: 32_000, isCloud: false)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        guard package.isInstalled else {
            throw ProviderError.notConfigured("„\(package.title)“ ist nicht geladen (Einstellungen → Modelle).")
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let text = try await client.generate(
            GenerateParameters(
                folder: package.folder.path, instructions: request.instructions, prompt: request.promptWithOutline,
                images: request.images.map(\.path), maxTokens: request.maxTokens, temperature: request.temperature))
        return GenerationResult(text: text, model: package.id, seconds: elapsed(since: start))
    }

    public func testConnection() async throws -> String {
        guard package.isInstalled else {
            throw ProviderError.notConfigured("„\(package.title)“ ist nicht geladen (Einstellungen → Modelle).")
        }
        _ = try await client.status()
        return "„\(package.title)“ ist geladen; der Inferenzdienst antwortet."
    }
}
