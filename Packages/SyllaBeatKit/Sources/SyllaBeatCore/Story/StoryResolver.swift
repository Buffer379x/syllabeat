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

    /// Wert eines Merkmals mit Herkunft. Vorrang: Nutzer (Clip) > Dateiname > Kapitel-Vorgabe > Beschreibung; was der
    /// einzelne Clip sagt, schlägt die pauschale Vorgabe seines Kapitels.
    public static func traitValue(
        _ clip: Clip, trait: Trait, chapter: Chapter?, motif: FileNameMotif
    )
        -> (String, TraitValue.Source)?
    {
        if let value = clip.traits[trait.id], value.source == .user { return (value.value, .user) }
        if let value = clip.traits[trait.id], value.source == .fileName { return (value.value, .fileName) }
        if trait.id == Trait.timeOfDay.id, let value = motif.timeOfDay { return (value, .fileName) }
        if let value = chapter?.traits[trait.id] { return (value, .user) }
        if let value = clip.traits[trait.id], value.source == .description { return (value.value, .description) }
        // Nur beschriebene Clips: Ohne Abend- oder Nachtstichwort gelten sie als Tag.
        let described = ([clip.description] + clip.scenes.map(\.description)).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trait.id == Trait.timeOfDay.id, !described.isEmpty,
            let value = timeOfDay(fromDescription: described + " " + clip.tags.joined(separator: " "))
        {
            return (value, .description)
        }
        return nil
    }

    /// Tageszeit aus einer freien Bildbeschreibung: Stichwörter für Nacht und Abend, sonst Tag (Abendlicht wird in
    /// Beschreibungen genannt; im Spike 36/40 richtig). Leerer Text: unbekannt.
    public static func timeOfDay(fromDescription text: String) -> String? {
        let lower = text.lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if ["nacht", "dunkel", "sterne", "mond"].contains(where: lower.contains) { return "Nacht" }
        if ["abend", "sonnenuntergang", "dämmerung", "untergehend", "leuchtende fenster", "leuchtenden fenstern"]
            .contains(where: lower.contains)
        {
            return "Abend"
        }
        return "Tag"
    }
}
