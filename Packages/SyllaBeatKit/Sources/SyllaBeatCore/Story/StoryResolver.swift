import Foundation

/// Was die Engine je Clip aus der Geschichte braucht: Kapitelindex, Merkmalsstufen mit Herkunft, Motiv und
/// Wasserzeichen.
public enum StoryResolver {
    public struct Resolved: Sendable, Equatable {
        public var chapter: Int?
        /// Merkmal-ID → Stufe (Index in `Trait.values`).
        public var traitLevels: [String: Int]
        public var traitSources: [String: TraitValue.Source]
        public var motif: String
        public var watermark: Bool
    }

    public static func resolve(_ project: Project) -> [String: Resolved] {
        let chapterIndex = Dictionary(
            project.story.chapters.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let motifs = project.motifs()
        var result: [String: Resolved] = [:]
        for clip in project.clips {
            let motif = motifs[clip.id] ?? FileNameMotif.parse(clip.name)
            let chapter = project.story.chapter(withID: clip.chapterID)
            var levels: [String: Int] = [:]
            var sources: [String: TraitValue.Source] = [:]
            for trait in project.story.traits where trait.rule != .off {
                if let (value, source) = traitValue(clip, trait: trait, chapter: chapter, motif: motif),
                    let level = trait.level(value)
                {
                    levels[trait.id] = level
                    sources[trait.id] = source
                }
            }
            result[clip.id] = Resolved(
                chapter: clip.chapterID.flatMap { chapterIndex[$0] }, traitLevels: levels, traitSources: sources,
                motif: motif.key, watermark: motif.watermark == true)
        }
        return result
    }

    /// Wert eines Merkmals mit Herkunft. Vorrang: Nutzer > Kapitel-Vorgabe > Dateiname > Beschreibung.
    public static func traitValue(
        _ clip: Clip, trait: Trait, chapter: Chapter?, motif: FileNameMotif
    )
        -> (String, TraitValue.Source)?
    {
        if let value = clip.traits[trait.id], value.source == .user { return (value.value, .user) }
        if let value = chapter?.traits[trait.id] { return (value, .user) }
        if let value = clip.traits[trait.id], value.source == .fileName { return (value.value, .fileName) }
        if trait.id == Trait.timeOfDay.id, let value = motif.timeOfDay { return (value, .fileName) }
        if let value = clip.traits[trait.id], value.source == .description { return (value.value, .description) }
        if trait.id == Trait.timeOfDay.id,
            let value = timeOfDay(
                fromDescription: ([clip.description] + clip.scenes.map(\.description) + clip.tags).joined(
                    separator: " "))
        {
            return (value, .description)
        }
        return nil
    }

    /// Tageszeit aus einer freien Bildbeschreibung (Stichwörter; im Spike 36/40 richtig).
    public static func timeOfDay(fromDescription text: String) -> String? {
        let lower = text.lowercased()
        if ["nacht", "dunkel", "sterne", "mond"].contains(where: lower.contains) { return "Nacht" }
        if ["abend", "sonnenuntergang", "dämmerung", "untergehend", "leuchtende fenster", "leuchtenden fenstern"]
            .contains(where: lower.contains)
        {
            return "Abend"
        }
        return nil
    }
}
