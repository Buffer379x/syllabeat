import CoreGraphics
import Foundation
import SyllaBeatCore
import Vision

/// Merkmale über Apple Vision, eingebaut und ohne Download.
public enum VisionFeatures {
    public struct Result: Sendable {
        public var aesthetics: Double?
        public var isUtility: Bool
        public var labels: [String]
        public var faceCount: Int
        public var largestFaceArea: Double
    }

    public static func analyze(_ image: CGImage) async -> Result {
        var result = Result(aesthetics: nil, isUtility: false, labels: [], faceCount: 0, largestFaceArea: 0)
        if let scores = try? await CalculateImageAestheticsScoresRequest().perform(on: image) {
            result.aesthetics = Double(scores.overallScore)
            result.isUtility = scores.isUtility
        }
        if let classes = try? await ClassifyImageRequest().perform(on: image) {
            result.labels = classes.filter { $0.confidence > 0.3 }.sorted { $0.confidence > $1.confidence }
                .prefix(6).map(\.identifier)
        }
        if let faces = try? await DetectFaceRectanglesRequest().perform(on: image) {
            result.faceCount = faces.count
            result.largestFaceArea = faces.map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
        }
        return result
    }
}
