import Foundation
import SyllaBeatCore
import WhisperKit

/// Transkription mit Wortzeiten über WhisperKit (Core ML). Standard laut M0: large-v3 turbo (632 MB),
/// 87–99 % der deutschen Wörter, ≈ 30× Echtzeit. Kein Songtext als Prompt (behebt F3 aus 0.2.0).
public final class WhisperTranscriber: @unchecked Sendable {
    public static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    public static let downloadBytes: Int64 = 632_000_000

    /// Ablage im WhisperKit-Format: `models/argmaxinc/whisperkit-coreml/<Variante>` und der Tokenizer daneben.
    public static var base: URL {
        Locations.models.appendingPathComponent("transcription/whisperkit", isDirectory: true)
    }

    static var modelFolder: URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    static var tokenizerFolder: URL {
        base.appendingPathComponent("models/openai/whisper-large-v3", isDirectory: true)
    }

    public static var isInstalled: Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: modelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)
            && manager.fileExists(atPath: tokenizerFolder.appendingPathComponent("tokenizer.json").path)
    }

    /// Lädt Modell und Tokenizer und kompiliert einmal für die Neural Engine (erster Start ≈ 2 min).
    public static func install() async throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Downloader.ensureSpace(downloadBytes, at: base)
        _ = try await WhisperKit.download(variant: variant, downloadBase: base)
        _ = try await WhisperTranscriber(allowDownload: true)
    }

    public static func uninstall() throws {
        if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
    }

    private let pipe: WhisperKit

    public init(allowDownload: Bool = false) async throws {
        guard allowDownload || Self.isInstalled else { throw EmbeddingError.notInstalled }
        let config = WhisperKitConfig(
            model: Self.variant, downloadBase: Self.base, modelFolder: Self.modelFolder.path, verbose: false,
            logLevel: .error, prewarm: true, load: true, download: allowDownload)
        pipe = try await WhisperKit(config)
    }

    /// Wörter mit Zeiten; `language` nil erkennt die Sprache selbst.
    public func transcribe(path: String, language: String?) async throws -> [RecognizedWord] {
        let options = DecodingOptions(
            language: language, temperatureFallbackCount: 3, usePrefillPrompt: language != nil,
            detectLanguage: language == nil, skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
        let results = try await pipe.transcribe(audioPath: path, decodeOptions: options)
        return results.flatMap(\.segments).flatMap { $0.words ?? [] }.map { word in
            RecognizedWord(
                text: word.word.trimmingCharacters(in: .whitespaces), start: Double(word.start), end: Double(word.end),
                probability: Double(word.probability))
        }.filter { !$0.text.isEmpty }
    }
}
