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

extension StoryResolver {
    /// Wert eines Merkmals für einen Clip im Projekt (Kapitel-Vorgabe und Dateiname eingerechnet), mit Herkunft.
    public static func value(
        _ trait: Trait, for clip: Clip, in project: Project
    ) -> (value: String, source: TraitValue.Source)? {
        let groups = FileNameMotif.groups(in: project.clips.map(\.name))
        return traitValue(
            clip, trait: trait, chapter: project.story.chapter(withID: clip.chapterID),
            motif: FileNameMotif.parse(clip.name, groups: groups)
        ).map { (value: $0.0, source: $0.1) }
    }
}

extension StoryResolver {
    /// Werte eines Merkmals für alle Clips in einem Durchgang (Gruppen der Dateinamen einmal berechnet).
    public static func values(
        _ trait: Trait, in project: Project
    ) -> [String: (value: String, source: TraitValue.Source)] {
        let groups = FileNameMotif.groups(in: project.clips.map(\.name))
        var result: [String: (value: String, source: TraitValue.Source)] = [:]
        for clip in project.clips {
            if let found = traitValue(
                clip, trait: trait, chapter: project.story.chapter(withID: clip.chapterID),
                motif: FileNameMotif.parse(clip.name, groups: groups))
            {
                result[clip.id] = (found.0, found.1)
            }
        }
        return result
    }
}
