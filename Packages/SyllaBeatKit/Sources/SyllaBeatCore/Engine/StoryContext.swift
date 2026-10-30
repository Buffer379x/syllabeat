import Foundation

/// Regeln der Geschichte je Slot: erlaubte Kapitel (Drehbuch), Montage, Abschnittswechsel, festgelegte Merkmale.
struct StoryContext {
    /// Kapitelindex → Rolle; `nil` = frei.
    var allowed: [[Int: ChapterRole]?]
    var montage: [Bool]
    /// Slot beginnt einen neuen Abschnitt.
    var sectionStart: [Bool]
    /// Merkmal-ID → Stufe, je Slot (festgelegte Abschnitte).
    var pinned: [[String: Int]]

    var isEmpty: Bool { allowed.allSatisfy { $0 == nil } }

    static func make(_ project: Project, slots: [Slot]) -> StoryContext {
        let story = project.story
        let sections = project.analysis?.sections ?? []
        let chapterIndex = Dictionary(
            story.chapters.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let montage =
            story.montage
            ?? Set(sections.compactMap(\.repeatOf) + sections.filter { $0.repeatOf != nil }.map(\.id))
        var allowed: [[Int: ChapterRole]?] = []
        var isMontage: [Bool] = []
        var starts: [Bool] = []
        var pinned: [[String: Int]] = []
        var previous: String?
        for slot in slots {
            let section = slot.sectionID.flatMap { id in sections.first { $0.id == id } }
            let entry = slot.sectionID.flatMap { story.plan[$0] } ?? section?.repeatOf.flatMap { story.plan[$0] }
            var roles: [Int: ChapterRole] = [:]
            for (id, role) in entry ?? [:] {
                if let index = chapterIndex[id] { roles[index] = role }
            }
            allowed.append(roles.isEmpty ? nil : roles)
            isMontage.append(slot.sectionID.map(montage.contains) ?? false)
            starts.append(slot.sectionID != previous)
            previous = slot.sectionID
            var levels: [String: Int] = [:]
            for trait in story.traits where trait.rule != .off {
                if let id = slot.sectionID, let level = trait.level(trait.pinned[id]) { levels[trait.id] = level }
            }
            pinned.append(levels)
        }
        return StoryContext(allowed: allowed, montage: isMontage, sectionStart: starts, pinned: pinned)
    }
}
