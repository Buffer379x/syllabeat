import Foundation
import SyllaBeatCore

/// Bildbeschreibung eines Clips (F-12): die Vorschaubilder seiner Szenen gehen an ein Bildmodell, zurück kommen
/// Beschreibung, Stimmung, Schlagwörter, je Szene ein Satz und ein Dateinamen-Vorschlag.
public enum ClipDescriber {
    /// Clip ohne Vorschaubilder (z. B. Datei fehlt): wird übersprungen, die Aufgabe läuft weiter.
    public struct NoImages: Error, LocalizedError {
        public var clipName: String
        public var errorDescription: String? { "„\(clipName)“ hat noch keine Vorschaubilder." }
    }

    /// Mehr Bilder pro Anfrage kosten Zeit und Kontext; bei vielen Szenen werden sie gleichmäßig ausgewählt.
    public static let maximumImages = 6

    struct Answer: Decodable {
        struct Scene: Decodable {
            var id: String
            var inhalt: String
        }

        var beschreibung: String
        var stimmung: String
        var schlagwoerter: [String]
        var szenen: [Scene]
        var dateiname: String
    }

    /// Szenen, die ins Bild kommen (gleichmäßig verteilt).
    public static func selectedScenes(_ clip: Clip) -> [ClipScene] {
        guard clip.scenes.count > maximumImages else { return clip.scenes }
        return (0..<maximumImages).map { clip.scenes[$0 * (clip.scenes.count - 1) / (maximumImages - 1)] }
    }

    public static func schema(sceneCount: Int) -> JSONSchema {
        .object(
            name: "Clip", description: "Sachlicher Katalogeintrag",
            properties: [
                .init("beschreibung", .string("Ein eigener Satz über den ganzen Clip")),
                .init("stimmung", .string("Ein bis drei Wörter")),
                .init(
                    "schlagwoerter",
                    .array(
                        description: "Drei bis acht deutsche Suchbegriffe für sichtbare Dinge",
                        items: .string(description: nil, choices: nil), minimum: 3, maximum: 8)),
                .init(
                    "szenen",
                    .array(
                        description: "Pro Bild ein Eintrag, in derselben Reihenfolge",
                        items: .object(
                            name: "Szene", description: nil,
                            properties: [
                                .init("id", .string("Bild-ID", choices: (1...max(1, sceneCount)).map { "s\($0)" })),
                                .init("inhalt", .string("Ein eigener Satz nur zu diesem Bild")),
                            ]),
                        minimum: sceneCount, maximum: sceneCount)),
                .init(
                    "dateiname",
                    .string(
                        "Drei bis sechs Wörter zum Hauptmotiv, klein, mit Unterstrichen, ohne Endung und ohne Bild-IDs")
                ),
            ])
    }

    public static func request(for clip: Clip, images: [URL]) -> GenerationRequest {
        GenerationRequest(
            instructions: """
                Du erstellst einen sachlichen Clip-Katalog für den Schnitt eines Musikvideos. Beschreibe nur \
                Sichtbares, auf Deutsch, ohne Vermutungen über Personen.
                """,
            prompt: """
                Die \(images.count) Bilder stammen in zeitlicher Reihenfolge aus den Szenen s1 bis s\(images.count) \
                eines einzigen Clips. Erstelle den Katalogeintrag.
                """,
            images: images, schema: schema(sceneCount: images.count), maxTokens: 700, temperature: 0.2)
    }

    /// Antwort → aktualisierter Clip. Beschreibungen der gezeigten Szenen werden gesetzt, andere bleiben.
    public static func apply(_ data: Data, to clip: Clip, scenes: [ClipScene], model: String) throws -> Clip {
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        var updated = clip
        updated.description = answer.beschreibung.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.mood = answer.stimmung.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tags = Array(
            answer.schlagwoerter.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .prefix(8))
        let name = answer.dateiname.lowercased().replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        updated.filenameSuggestion = name.isEmpty ? nil : name
        for (index, scene) in scenes.enumerated() {
            guard let text = answer.szenen.first(where: { $0.id == "s\(index + 1)" })?.inhalt,
                let position = updated.scenes.firstIndex(where: { $0.id == scene.id })
            else { continue }
            updated.scenes[position].description = text
        }
        updated.visionModel = model
        return updated
    }

    /// Gesicherte Beschreibung im Zwischenspeicher (je Datei-Fingerprint, Szenen nach Startzeit).
    public struct Stored: Codable, Sendable, Equatable {
        public var description: String
        public var mood: String?
        public var tags: [String]
        public var filenameSuggestion: String?
        public var scenes: [String: String]
        public var model: String

        public init(_ clip: Clip) {
            description = clip.description
            mood = clip.mood
            tags = clip.tags
            filenameSuggestion = clip.filenameSuggestion
            scenes = Dictionary(
                clip.scenes.filter { !$0.description.isEmpty }.map {
                    (MediaCache.key(forSceneStart: $0.start), $0.description)
                },
                uniquingKeysWith: { first, _ in first })
            model = clip.visionModel ?? ""
        }

        public func apply(to clip: Clip) -> Clip {
            var updated = clip
            updated.description = description
            updated.mood = mood
            updated.tags = tags
            updated.filenameSuggestion = filenameSuggestion
            updated.visionModel = model
            for index in updated.scenes.indices {
                if let text = scenes[MediaCache.key(forSceneStart: updated.scenes[index].start)] {
                    updated.scenes[index].description = text
                }
            }
            return updated
        }
    }

    public static func stored(_ clip: Clip, cache: MediaCache = MediaCache()) -> Stored? {
        guard let fingerprint = clip.media.fingerprint,
            let data = try? Data(contentsOf: cache.description(fingerprint: fingerprint))
        else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    public static func store(_ clip: Clip, cache: MediaCache = MediaCache()) {
        guard let fingerprint = clip.media.fingerprint, let data = try? JSONEncoder().encode(Stored(clip)) else {
            return
        }
        _ = try? cache.prepare(fingerprint: fingerprint)
        try? data.write(to: cache.description(fingerprint: fingerprint), options: .atomic)
    }

    /// Beschreibt einen Clip mit dem gewählten Anbieter. `thumbnail` liefert das Vorschaubild einer Szene.
    public static func describe(
        _ clip: Clip, provider: any LanguageModelProvider, thumbnail: (ClipScene) -> URL?
    ) async throws -> (clip: Clip, seconds: Double) {
        let scenes = selectedScenes(clip).filter { thumbnail($0) != nil }
        guard !scenes.isEmpty else { throw NoImages(clipName: clip.name) }
        let outcome = try await StructuredGeneration.run(
            provider, request(for: clip, images: scenes.compactMap(thumbnail)))
        return (try apply(outcome.data, to: clip, scenes: scenes, model: outcome.result.model), outcome.result.seconds)
    }
}
