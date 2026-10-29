import Foundation

/// KI-Regie, Stufe 1: Gesamtidee und je Abschnitt Stimmung, Bildidee, Suchbegriffe und Schnitttempo. Die
/// Suchbegriffe finden die Bilder über die Embeddings (kein Clip-Katalog nötig).
public struct Storyboard: Codable, Sendable, Equatable {
    public enum Pace: String, Codable, Sendable, CaseIterable {
        case calm, normal, fast

        public var title: String {
            switch self {
            case .calm: "ruhig"
            case .normal: "normal"
            case .fast: "schnell"
            }
        }

        /// Faktor auf die Beats je Einstellung.
        public var beatFactor: Double {
            switch self {
            case .calm: 2
            case .normal: 1
            case .fast: 0.5
            }
        }
    }

    public struct SectionPlan: Codable, Sendable, Equatable, Identifiable {
        public var sectionID: String
        public var mood: String
        public var imageIdea: String
        public var searchTerms: [String]
        public var pace: Pace

        public var id: String { sectionID }

        public init(sectionID: String, mood: String, imageIdea: String, searchTerms: [String], pace: Pace) {
            self.sectionID = sectionID
            self.mood = mood
            self.imageIdea = imageIdea
            self.searchTerms = searchTerms
            self.pace = pace
        }
    }

    public var idea: String
    public var sections: [SectionPlan]
    /// Wer es erstellt hat, z. B. „Apple Intelligence“ oder „claude-sonnet-5-5“.
    public var model: String
    /// Regieanweisung zum Zeitpunkt der Erstellung.
    public var brief: String

    public init(idea: String, sections: [SectionPlan], model: String, brief: String) {
        self.idea = idea
        self.sections = sections
        self.model = model
        self.brief = brief
    }

    public func plan(for sectionID: String?) -> SectionPlan? {
        sectionID.flatMap { id in sections.first { $0.sectionID == id } }
    }
}
