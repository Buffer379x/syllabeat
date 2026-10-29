import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Lokale Sprach- und Bildmodelle über MLX (z. B. Qwen3-VL-4B). Läuft im Inferenzdienst; ein Modell zur Zeit, nach
/// Leerlauf gibt der Dienst den Speicher frei, indem er sich beendet.
public actor MLXGenerator {
    private var container: ModelContainer?
    private var folder: URL?

    public init() {}

    /// Text (und optional Bilder) → Antworttext. `folder` enthält `config.json`, Gewichte und Tokenizer.
    public func generate(
        folder: URL, instructions: String, prompt: String, images: [URL], maxTokens: Int, temperature: Double
    ) async throws -> String {
        let model = try await load(folder)
        let session = ChatSession(
            model, instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: Float(temperature)))
        return try await session.respond(
            to: prompt, images: images.map { UserInput.Image.url($0) }, videos: [], audios: [])
    }

    public func unload() {
        container = nil
        folder = nil
        Memory.clearCache()
    }

    private func load(_ target: URL) async throws -> ModelContainer {
        if let container, folder == target { return container }
        unload()
        let loaded = try await VLMModelFactory.shared.loadContainer(from: target, using: TransformersTokenizerLoader())
        container = loaded
        folder = target
        return loaded
    }
}

/// Tokenizer aus swift-transformers für MLX (wie das Makro `#huggingFaceTokenizerLoader`, ohne Makro-Abhängigkeit).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
