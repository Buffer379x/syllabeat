import CoreGraphics
import CoreML
import Foundation
import ImageIO
import SyllaBeatCore
import Tokenizers
import Vision

public enum EmbeddingError: Error, LocalizedError, Equatable {
    case notInstalled
    case unreadableImage(String)
    case unexpectedModel(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Das Modell für die Bildsuche (SigLIP 2) ist nicht geladen."
        case .unreadableImage(let name): "Das Bild „\(name)“ ist nicht lesbar."
        case .unexpectedModel(let reason): "Das Modell hat ein unerwartetes Format: \(reason)"
        }
    }
}

/// SigLIP 2 B/16-256 als Core ML: Bild- und Text-Encoder, 768-d, L2-normalisiert; Ähnlichkeit = Skalarprodukt.
/// Bild-Encoder auf CPU+GPU (laut M0 schneller und stabiler als die Neural Engine).
public final class SiglipEmbedder: @unchecked Sendable {
    public let package: ModelPackage
    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: any Tokenizer
    private let imageInput: (name: String, constraint: MLImageConstraint)
    private let textInput: String
    private let lock = NSLock()
    static let contextLength = 64

    public init(package: ModelPackage = ModelCatalog.siglip2) async throws {
        guard package.isInstalled else { throw EmbeddingError.notInstalled }
        self.package = package
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        imageModel = try await Self.load(package.folder.appendingPathComponent("ImageEncoder.mlpackage"), configuration)
        textModel = try await Self.load(package.folder.appendingPathComponent("TextEncoder.mlpackage"), configuration)
        tokenizer = try await AutoTokenizer.from(modelFolder: package.folder.appendingPathComponent("tokenizer"))
        guard let image = imageModel.modelDescription.inputDescriptionsByName.first,
            let constraint = image.value.imageConstraint,
            let text = textModel.modelDescription.inputDescriptionsByName.first?.key
        else { throw EmbeddingError.unexpectedModel("Eingänge fehlen") }
        imageInput = (image.key, constraint)
        textInput = text
    }

    /// Kompiliert das Modell einmal und legt die kompilierte Fassung neben das Paket.
    private static func load(_ url: URL, _ configuration: MLModelConfiguration) async throws -> MLModel {
        let compiled = url.deletingPathExtension().appendingPathExtension("mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let temporary = try await MLModel.compileModel(at: url)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: temporary, to: compiled)
        }
        return try await MLModel.load(contentsOf: compiled, configuration: configuration)
    }

    public func embed(image: CGImage) throws -> [Float] {
        let value = try MLFeatureValue(
            cgImage: image, constraint: imageInput.constraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        return try lock.withLock {
            try Self.vector(
                imageModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [imageInput.name: value])))
        }
    }

    public func embed(imageAt url: URL) throws -> [Float] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw EmbeddingError.unreadableImage(url.lastPathComponent) }
        return try embed(image: image)
    }

    /// Text kleingeschrieben, mit dem Gemma-Tokenizer, auf 64 Tokens mit 0 aufgefüllt (ohne Maske, wie trainiert).
    public func embed(text: String) throws -> [Float] {
        var ids = tokenizer.encode(text: text.lowercased())
        ids = Array(ids.prefix(Self.contextLength))
        ids += Array(repeating: 0, count: Self.contextLength - ids.count)
        let array = try MLMultiArray(shape: [1, NSNumber(value: Self.contextLength)], dataType: .int32)
        for (index, id) in ids.enumerated() { array[index] = NSNumber(value: id) }
        return try lock.withLock {
            try Self.vector(textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [textInput: array])))
        }
    }

    private static func vector(_ output: any MLFeatureProvider) throws -> [Float] {
        let name = output.featureNames.first { $0.contains("embed") } ?? output.featureNames.first
        guard let name, let array = output.featureValue(for: name)?.multiArrayValue else {
            throw EmbeddingError.unexpectedModel("kein Embedding-Ausgang")
        }
        return (0..<array.count).map { array[$0].floatValue }
    }
}

/// Semantische Suche über Szenen-Embeddings: Skalarprodukt normierter Vektoren.
public enum EmbeddingSearch {
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var total: Float = 0
        for i in a.indices { total += a[i] * b[i] }
        return total
    }
}
