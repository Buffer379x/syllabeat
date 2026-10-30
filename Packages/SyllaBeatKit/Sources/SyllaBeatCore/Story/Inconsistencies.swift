import Foundation

/// Etwas im Schnitt passt nicht zur Geschichte: Ort (Einstellungen, Abschnitt), Grund und Abhilfe im Text.
public struct Inconsistency: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case timeGoesBack, chapterOutsidePlan, chapterGoesBack, relaxed, sameMotifRepeated, watermark,
            copyBreaksTrait, lineTimingRepaired, traitUnknown
    }

    public var kind: Kind
    public var shotIDs: [String]
    public var sectionID: String?
    public var message: String

    public var id: String { "\(kind.rawValue):\(sectionID ?? ""):\(shotIDs.joined(separator: ","))" }
}

/// Prüft einen Schnitt auf Ungereimtheiten. Die Engine vermeidet sie; übrig bleiben Handbearbeitungen, fixierte
/// Shots, Refrain-Kopien und Ausweichen bei Materialmangel.
public enum InconsistencyChecker {
    public static func check(_ project: Project, cut: Cut) -> [Inconsistency] {
        guard let analysis = project.analysis else { return [] }
        var findings: [Inconsistency] = []
        let sections = SlotPlanner.normalizedSections(analysis)
        let numbers = Dictionary(cut.shots.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        let clips = Dictionary(project.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let resolved = StoryResolver.resolve(project)
        func section(of shot: Shot) -> SongSection? {
            let middle = (shot.start.time + shot.end.time) / 2
            return sections.first { $0.start <= middle && middle < $0.end }
        }
        func plan(of section: SongSection?) -> [String: ChapterRole]? {
            guard let section else { return nil }
            let entry = project.story.plan[section.id] ?? section.repeatOf.flatMap { project.story.plan[$0] }
            return entry?.isEmpty == false ? entry : nil
        }

        // Tageszeit (fortlaufende Merkmale): Rücksprünge und Refrain-Kopien, die zurückspringen.
        for trait in project.story.traits where trait.rule == .progressive {
            var floor = -1
            var copies: [String: [String]] = [:]
            for shot in cut.shots {
                let current = section(of: shot)
                if let current, trait.pinned[current.id] != nil { continue }
                guard let level = resolved[shot.clipID]?.traitLevels[trait.id] else { continue }
                if shot.reasons?.relaxed.contains(trait.id) == true { continue }
                if level < floor {
                    if shot.reasons?.copiedFrom != nil {
                        copies[current?.id ?? "", default: []].append(shot.id)
                    } else {
                        findings.append(
                            Inconsistency(
                                kind: .timeGoesBack, shotIDs: [shot.id], sectionID: current?.id,
                                message:
                                    "Einstellung \(numbers[shot.id] ?? 0) zeigt \(trait.values[level]) nach \(trait.values[floor])."
                            ))
                    }
                    continue
                }
                floor = max(floor, level)
            }
            for (sectionID, ids) in copies.sorted(by: { $0.key < $1.key }) {
                let label = sections.first { $0.id == sectionID }?.label ?? "Refrain"
                findings.append(
                    Inconsistency(
                        kind: .copyBreaksTrait, shotIDs: ids, sectionID: sectionID,
                        message:
                            "„\(label)“ kopiert Bilder mit früherer \(trait.name) in einen späteren Teil. Abhilfe: "
                            + "Refrain-Modus „Gleiche Clips, andere Ausschnitte“."))
            }
        }

        // Kapitel außerhalb des Drehbuchs (Handbearbeitung, fixierte Shots).
        let chapterNames = Dictionary(project.story.chapters.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for shot in cut.shots where shot.reasons?.relaxed.isEmpty != false {
            let current = section(of: shot)
            guard let entry = plan(of: current) else { continue }
            let chapter = clips[shot.clipID]?.chapterID
            guard !(chapter.map { entry[$0] != nil } ?? false) else { continue }
            findings.append(
                Inconsistency(
                    kind: .chapterOutsidePlan, shotIDs: [shot.id], sectionID: current?.id,
                    message:
                        "Einstellung \(numbers[shot.id] ?? 0) (\(chapter.flatMap { chapterNames[$0] } ?? "ohne Kapitel")) "
                        + "liegt in „\(current?.label ?? "")“."))
        }

        // Drehbuch läuft rückwärts (zwischen Abschnitten, die keine Montage sind).
        let montage =
            project.story.montage
            ?? Set(sections.compactMap(\.repeatOf) + sections.filter { $0.repeatOf != nil }.map(\.id))
        let order = Dictionary(project.story.chapters.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Rückschritt, wenn unteres oder oberes Ende des Kapitelbereichs gegenüber dem vorigen Abschnitt fällt.
        var previous: (section: SongSection, lowest: Int, highest: Int)?
        for current in sections where !montage.contains(current.id) {
            guard let entry = plan(of: current) else { continue }
            let mains = entry.filter { $0.value == .main }.keys
            let indices = (mains.isEmpty ? Array(entry.keys) : Array(mains)).compactMap { order[$0] }
            guard let lowest = indices.min(), let highest = indices.max() else { continue }
            if let previous, lowest < previous.lowest || highest < previous.highest {
                findings.append(
                    Inconsistency(
                        kind: .chapterGoesBack, shotIDs: [], sectionID: current.id,
                        message:
                            "„\(current.label)“ (\(project.story.chapters[lowest].name)) folgt auf „\(previous.section.label)“ "
                            + "(\(project.story.chapters[previous.highest].name))."))
            }
            previous = (current, lowest, highest)
        }

        // Ausgewichen: passendes Material fehlte.
        var relaxed: [String: [Shot]] = [:]
        for shot in cut.shots where shot.reasons?.relaxed.isEmpty == false {
            relaxed[section(of: shot)?.id ?? "", default: []].append(shot)
        }
        for current in sections {
            guard let shots = relaxed[current.id] else { continue }
            let rules = Set(shots.flatMap { $0.reasons?.relaxed ?? [] }).map {
                $0 == "kapitel" ? "Kapitel" : "Tageszeit"
            }
            findings.append(
                Inconsistency(
                    kind: .relaxed, shotIDs: shots.map(\.id), sectionID: current.id,
                    message:
                        "In „\(current.label)“ musste die Engine bei \(shots.count) Einstellung(en) ausweichen "
                        + "(\(rules.sorted().joined(separator: ", "))): passendes Material fehlte."))
        }

        // Takes desselben Motivs direkt hintereinander; Wasserzeichen, obwohl es saubere Takes gibt.
        let motifs = project.motifs().filter {
            $0.value.words.count >= 2 || $0.value.generator != nil || $0.value.copy > 1
        }
        for (a, b) in zip(cut.shots, cut.shots.dropFirst())
        where a.clipID != b.clipID && motifs[a.clipID] != nil && motifs[a.clipID]?.key == motifs[b.clipID]?.key {
            findings.append(
                Inconsistency(
                    kind: .sameMotifRepeated, shotIDs: [a.id, b.id], sectionID: section(of: b)?.id,
                    message:
                        "Einstellungen \(numbers[a.id] ?? 0) und \(numbers[b.id] ?? 0) zeigen dasselbe Motiv (zwei Takes)."
                ))
        }
        let clean = Set(motifs.values.filter { $0.watermark != true }.map(\.key))
        let marked = cut.shots.filter { shot in
            motifs[shot.clipID].map { $0.watermark == true && clean.contains($0.key) } ?? false
        }
        if !marked.isEmpty {
            findings.append(
                Inconsistency(
                    kind: .watermark, shotIDs: marked.map(\.id), sectionID: nil,
                    message:
                        "\(marked.count) Einstellung(en) mit Wasserzeichen, obwohl es wasserzeichenfreie Takes gibt."))
        }

        // Neu verteilte Wortzeiten.
        let estimated = Set(analysis.words.filter(\.estimated).map(\.id))
        let repaired = analysis.lines.filter { line in
            line.needsReview && !line.wordIDs.isEmpty
                && Double(line.wordIDs.filter(estimated.contains).count) >= 0.5 * Double(line.wordIDs.count)
        }
        if !repaired.isEmpty {
            findings.append(
                Inconsistency(
                    kind: .lineTimingRepaired, shotIDs: [], sectionID: nil,
                    message:
                        "\(repaired.count) Zeile\(repaired.count == 1 ? "" : "n") mit neu verteilten Wortzeiten – bitte "
                        + "in der Textspur prüfen."))
        }

        // Tageszeit offen, obwohl sie für andere Clips bekannt ist.
        let used = Set(cut.shots.map(\.clipID))
        let known = used.filter { resolved[$0]?.traitLevels[Trait.timeOfDay.id] != nil }
        if !known.isEmpty, known.count < used.count {
            findings.append(
                Inconsistency(
                    kind: .traitUnknown, shotIDs: [], sectionID: nil,
                    message:
                        "\(used.count - known.count) verwendete Clips ohne Tageszeit (Bibliothek: Filter „Tageszeit offen“)."
                ))
        }
        return findings
    }
}
