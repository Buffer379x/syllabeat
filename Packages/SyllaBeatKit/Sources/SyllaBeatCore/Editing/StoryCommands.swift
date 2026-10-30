import Foundation

/// Sperrbereiche eines Clips ersetzen (KI-Fehler). Schnitte, die danach einen Sperrbereich berühren, werden neu
/// bestimmt – auch fixierte (deren Fixierung entfällt).
public struct SetBlockedRanges: EditCommand {
    public var clipID: String
    public var ranges: [SourceRange]

    public init(clipID: String, ranges: [SourceRange]) {
        self.clipID = clipID
        self.ranges = ranges
    }

    public var actionName: String { "Sperrbereiche ändern" }

    public func apply(to project: inout Project) throws {
        guard let index = project.clips.firstIndex(where: { $0.id == clipID }) else {
            throw EditError.unknownClip(clipID)
        }
        project.clips[index].blocked = ranges.normalized(length: project.clips[index].meta.availableSeconds.doubleValue)
        project.repairCut()
    }
}

/// Den Quellbereich, den eine Einstellung gerade zeigt, sperren und die Einstellung neu schneiden (Taste X).
public struct BlockShotSource: EditCommand {
    public var shotID: String
    public init(shotID: String) { self.shotID = shotID }

    public var actionName: String { "Ausschnitt sperren" }

    public func apply(to project: inout Project) throws {
        guard let shot = project.cut?.shots.first(where: { $0.id == shotID }),
            let clip = project.clip(withID: shot.clipID)
        else { throw EditError.invalidValue("Diese Einstellung gibt es nicht.") }
        let start = shot.sourceIn.doubleValue
        try SetBlockedRanges(
            clipID: clip.id, ranges: clip.blocked + [SourceRange(start: start, end: start + shot.duration)]
        ).apply(to: &project)
    }
}

extension Project {
    /// Nach einer Änderung der Geschichte neu schneiden (wie bei Stiländerungen); fixierte Shots bleiben.
    mutating func recutForStory(_ textScores: TextScores) throws {
        guard analysis != nil, cut != nil else { return }
        try regenerate(style: style, textScores: textScores, keep: lockedShots)
    }
}

/// Kapitel anlegen, umbenennen, ordnen oder entfernen. Entfernte Kapitel verschwinden aus Clips und Drehbuch.
public struct SetChapters: EditCommand {
    public var chapters: [Chapter]
    public var textScores: TextScores

    public init(chapters: [Chapter], textScores: TextScores = TextScores()) {
        self.chapters = chapters
        self.textScores = textScores
    }

    public var actionName: String { "Kapitel ändern" }

    public func apply(to project: inout Project) throws {
        let ids = Set(chapters.map(\.id))
        guard ids.count == chapters.count else { throw EditError.invalidValue("Kapitel-IDs sind nicht eindeutig.") }
        project.story.chapters = chapters
        for index in project.clips.indices where !(project.clips[index].chapterID.map(ids.contains) ?? true) {
            project.clips[index].chapterID = nil
        }
        project.story.plan = project.story.plan.mapValues { $0.filter { ids.contains($0.key) } }.filter {
            !$0.value.isEmpty
        }
        try project.recutForStory(textScores)
    }
}

/// Clips einem Kapitel zuordnen (`nil` = ohne Kapitel); mit `includeTakes` alle Takes desselben Motivs.
public struct AssignChapter: EditCommand {
    public var clipIDs: Set<String>
    public var chapterID: String?
    public var includeTakes: Bool
    public var textScores: TextScores

    public init(clipIDs: Set<String>, chapterID: String?, includeTakes: Bool, textScores: TextScores = TextScores()) {
        self.clipIDs = clipIDs
        self.chapterID = chapterID
        self.includeTakes = includeTakes
        self.textScores = textScores
    }

    public var actionName: String { "Kapitel zuweisen" }

    public func apply(to project: inout Project) throws {
        if let chapterID, project.story.chapter(withID: chapterID) == nil {
            throw EditError.invalidValue("Dieses Kapitel gibt es nicht.")
        }
        var targets = clipIDs
        if includeTakes {
            let motifs = project.motifs()
            let keys = Set(clipIDs.compactMap { motifs[$0]?.key })
            targets.formUnion(project.clips.filter { motifs[$0.id].map { keys.contains($0.key) } ?? false }.map(\.id))
        }
        for index in project.clips.indices where targets.contains(project.clips[index].id) {
            project.clips[index].chapterID = chapterID
        }
        try project.recutForStory(textScores)
    }
}

/// Ein Feld des Drehbuchs: Kapitel in einem Abschnitt als Hauptkapitel, Beimischung oder nicht (`nil`).
public struct SetChapterRole: EditCommand {
    public var sectionID: String
    public var chapterID: String
    public var role: ChapterRole?
    public var textScores: TextScores

    public init(sectionID: String, chapterID: String, role: ChapterRole?, textScores: TextScores = TextScores()) {
        self.sectionID = sectionID
        self.chapterID = chapterID
        self.role = role
        self.textScores = textScores
    }

    public var actionName: String { "Drehbuch ändern" }

    public func apply(to project: inout Project) throws {
        var entry = project.story.plan[sectionID] ?? [:]
        guard entry[chapterID] != role else { return }
        entry[chapterID] = role
        project.story.plan[sectionID] = entry.isEmpty ? nil : entry
        try project.recutForStory(textScores)
    }
}

/// Das ganze Drehbuch ersetzen (z. B. aus dem Vorschlag).
public struct ApplyDrehbuch: EditCommand {
    public var plan: [String: [String: ChapterRole]]
    public var textScores: TextScores

    public init(plan: [String: [String: ChapterRole]], textScores: TextScores = TextScores()) {
        self.plan = plan
        self.textScores = textScores
    }

    public var actionName: String { "Drehbuch übernehmen" }

    public func apply(to project: inout Project) throws {
        let cleaned = plan.filter { !$0.value.isEmpty }
        guard cleaned != project.story.plan else { return }
        project.story.plan = cleaned
        try project.recutForStory(textScores)
    }
}

/// Abschnitt als Montage (kommt in der Geschichte nicht voran) oder nicht.
public struct SetMontage: EditCommand {
    public var sectionID: String
    public var on: Bool
    public var textScores: TextScores

    public init(sectionID: String, on: Bool, textScores: TextScores = TextScores()) {
        self.sectionID = sectionID
        self.on = on
        self.textScores = textScores
    }

    public var actionName: String { "Montage ändern" }

    public func apply(to project: inout Project) throws {
        let sections = project.analysis?.sections ?? []
        var montage =
            project.story.montage
            ?? Set(sections.compactMap(\.repeatOf) + sections.filter { $0.repeatOf != nil }.map(\.id))
        if on { montage.insert(sectionID) } else { montage.remove(sectionID) }
        project.story.montage = montage
        try project.recutForStory(textScores)
    }
}

/// Banner „Kapitel anlegen“ zeigen oder nicht mehr fragen.
public struct SetAsksForChapters: EditCommand {
    public var asks: Bool
    public init(_ asks: Bool) { self.asks = asks }

    public var actionName: String { "Kapitel-Hinweis ausblenden" }

    public func apply(to project: inout Project) throws {
        project.story.asksForChapters = asks
    }
}

/// Merkmalswert für Clips setzen (Herkunft Nutzer) oder mit `nil` auf „automatisch“ zurück.
public struct SetTraitValue: EditCommand {
    public var clipIDs: Set<String>
    public var traitID: String
    public var value: String?
    public var textScores: TextScores

    public init(clipIDs: Set<String>, traitID: String, value: String?, textScores: TextScores = TextScores()) {
        self.clipIDs = clipIDs
        self.traitID = traitID
        self.value = value
        self.textScores = textScores
    }

    public var actionName: String { "Tageszeit ändern" }

    public func apply(to project: inout Project) throws {
        guard let trait = project.story.traits.first(where: { $0.id == traitID }) else {
            throw EditError.invalidValue("Dieses Merkmal gibt es nicht.")
        }
        if let value, !trait.values.contains(value) { throw EditError.invalidValue("Unbekannter Wert „\(value)“.") }
        for index in project.clips.indices where clipIDs.contains(project.clips[index].id) {
            project.clips[index].traits[traitID] = value.map { TraitValue(value: $0, source: .user) }
        }
        try project.recutForStory(textScores)
    }
}

/// Merkmal für einen Abschnitt festlegen (`nil` = automatisch).
public struct SetTraitPin: EditCommand {
    public var traitID: String
    public var sectionID: String
    public var value: String?
    public var textScores: TextScores

    public init(traitID: String, sectionID: String, value: String?, textScores: TextScores = TextScores()) {
        self.traitID = traitID
        self.sectionID = sectionID
        self.value = value
        self.textScores = textScores
    }

    public var actionName: String { "Tageszeit festlegen" }

    public func apply(to project: inout Project) throws {
        guard let index = project.story.traits.firstIndex(where: { $0.id == traitID }) else {
            throw EditError.invalidValue("Dieses Merkmal gibt es nicht.")
        }
        guard project.story.traits[index].pinned[sectionID] != value else { return }
        project.story.traits[index].pinned[sectionID] = value
        try project.recutForStory(textScores)
    }
}

/// Merkmal eines ganzen Kapitels vorgeben, z. B. „Heimfahrt: Abend“.
public struct SetChapterTrait: EditCommand {
    public var chapterID: String
    public var traitID: String
    public var value: String?
    public var textScores: TextScores

    public init(chapterID: String, traitID: String, value: String?, textScores: TextScores = TextScores()) {
        self.chapterID = chapterID
        self.traitID = traitID
        self.value = value
        self.textScores = textScores
    }

    public var actionName: String { "Kapitel-Vorgabe ändern" }

    public func apply(to project: inout Project) throws {
        guard let index = project.story.chapters.firstIndex(where: { $0.id == chapterID }) else {
            throw EditError.invalidValue("Dieses Kapitel gibt es nicht.")
        }
        project.story.chapters[index].traits[traitID] = value
        try project.recutForStory(textScores)
    }
}

/// Zeile als „braucht ein Bild“ (`true`) oder „Bild egal“ (`false`) markieren; `nil` hebt die Markierung auf.
public struct SetLineNeed: EditCommand {
    public var text: String
    public var need: Bool?

    public init(text: String, need: Bool?) {
        self.text = text
        self.need = need
    }

    public var actionName: String { "Zeile markieren" }

    public func apply(to project: inout Project) throws {
        project.story.lineNeeds[text.trimmingCharacters(in: .whitespacesAndNewlines)] = need
    }
}

/// Stil-Vorlage für die Prompts der Drehliste.
public struct SetPromptStyle: EditCommand {
    public var text: String
    public init(text: String) { self.text = text }

    public var actionName: String { "Stil-Vorlage ändern" }

    public func apply(to project: inout Project) throws {
        project.story.promptStyle = text
    }
}

/// Kapitel-Vorschläge für neue Clips übernehmen (Clip-ID → Kapitel-ID), ein Undo-Schritt.
public struct AcceptChapterSuggestions: EditCommand {
    public var assignments: [String: String]
    public var textScores: TextScores

    public init(assignments: [String: String], textScores: TextScores = TextScores()) {
        self.assignments = assignments
        self.textScores = textScores
    }

    public var actionName: String { "Kapitel-Vorschläge übernehmen" }

    public func apply(to project: inout Project) throws {
        for index in project.clips.indices {
            if let chapter = assignments[project.clips[index].id], project.story.chapter(withID: chapter) != nil {
                project.clips[index].chapterID = chapter
            }
        }
        try project.recutForStory(textScores)
    }
}
