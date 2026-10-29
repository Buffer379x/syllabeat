import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct CutEngineTests {
    /// I1–I6 für zufällige Projekte (1.000, zur Abnahme `SYLLABEAT_SEEDS=10000`): Erzeugen, Prüfen, gleiches Ergebnis
    /// bei gleichem Seed, fixierte Shots bleiben.
    @Test func invariantsHoldForRandomProjects() async {
        let total = ProcessInfo.processInfo.environment["SYLLABEAT_SEEDS"].flatMap(Int.init) ?? 1000
        let chunks = 8
        let failures = await withTaskGroup(of: [String].self) { group in
            for chunk in 0..<chunks {
                group.addTask {
                    var failures: [String] = []
                    for seed in stride(from: UInt64(chunk), to: UInt64(total), by: chunks) {
                        failures += Self.check(seed: seed)
                        if failures.count > 5 { break }
                    }
                    return failures
                }
            }
            var all: [String] = []
            for await part in group { all += part }
            return all
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    /// Zufällige Ähnlichkeiten für Zeilen und (bei Storyboard) Abschnitte.
    static func scores(_ project: Project, seed: UInt64) -> TextScores {
        var random = SeededRandom([seed, 0x5C0])
        let scenes = project.clips.flatMap { $0.scenes.map(\.id) }
        func row() -> [String: Float] {
            Dictionary(uniqueKeysWithValues: scenes.map { ($0, Float(random.unit()) * 0.2) })
        }
        let lines = Dictionary(uniqueKeysWithValues: (project.analysis?.lines ?? []).map { ($0.id, row()) })
        let sections = Dictionary(
            uniqueKeysWithValues: (project.storyboard?.sections ?? []).map { ($0.sectionID, row()) })
        return TextScores(lines, sections: sections)
    }

    static func check(seed: UInt64) -> [String] {
        let project = SyntheticProject.make(seed: seed)
        let scores = Self.scores(project, seed: seed)
        guard let cut = CutEngine.generate(project, style: project.style, textScores: scores) else {
            return ["Seed \(seed): kein Schnitt"]
        }
        var issues = CutValidator.validate(project, cut: cut).map { "Seed \(seed): \($0)" }
        // Abschnittsgrenzen sind Pflichtschnitte (außer direkt vor dem Songende, das dann verschmilzt); ein Wortanfang
        // darf sie um höchstens 80 ms verschieben.
        if let analysis = project.analysis {
            let beats = analysis.beats.map(\.time)
            for section in SlotPlanner.normalizedSections(analysis).dropFirst()
            where section.start < analysis.duration - project.style.minimumDuration {
                let time = SlotPlanner.boundaryPoint(section, beats: beats).time
                if !cut.shots.contains(where: { abs($0.start.time - time) <= 0.081 }) {
                    issues.append("Seed \(seed): Abschnittsgrenze \(time) fehlt")
                }
            }
        }
        // I6: Determinismus.
        if CutEngine.generate(project, style: project.style, textScores: scores) != cut {
            issues.append("Seed \(seed): I6 nicht deterministisch")
        }
        // I5: zwei Shots fixieren, neu würfeln.
        var locked = project
        var withLocks = cut
        for index in [0, withLocks.shots.count / 2] where index < withLocks.shots.count {
            withLocks.shots[index].locked = true
        }
        locked.cut = withLocks
        var style = project.style
        style.seed &+= 1
        if let rerolled = CutEngine.generate(
            locked, style: style, textScores: scores, keep: withLocks.shots.filter(\.locked))
        {
            issues += CutValidator.validate(locked, cut: rerolled, previous: withLocks).map {
                "Seed \(seed) neu: \($0)"
            }
        } else {
            issues.append("Seed \(seed): Neu würfeln mit fixierten Shots ohne Ergebnis")
        }
        return issues
    }
}

@Suite struct CutCommandTests {
    /// Projekt mit Refrains (identisch) und genug Clips; erster Schnitt bereits erzeugt.
    static func project(refrain: CutStyle.RefrainMode = .identical) throws -> Project {
        var seed: UInt64 = 0
        while true {
            var project = SyntheticProject.make(seed: seed, clips: 20...30, duration: 90...120)
            project.style.refrainMode = refrain
            try GenerateCut().apply(to: &project)
            if project.cut!.shots.contains(where: { $0.reasons?.copiedFrom != nil }) { return project }
            seed += 1
        }
    }

    @Test func recutChangesOnlySelection() throws {
        var project = try Self.project()
        let before = project.cut!
        let selected = Set(before.shots.filter { $0.reasons?.copiedFrom == nil }.prefix(3).map(\.id))
        try RecutShots(shotIDs: selected).apply(to: &project)
        let after = project.cut!
        #expect(CutValidator.validate(project, cut: after).isEmpty)
        for shot in before.shots where !selected.contains(shot.id) {
            #expect(
                after.shots.contains {
                    $0.start == shot.start && $0.end == shot.end && $0.clipID == shot.clipID
                        && $0.sourceIn == shot.sourceIn
                })
        }
        #expect(after.shots != before.shots)
    }

    @Test func variantsAreDistinctAndSelectable() throws {
        var project = try Self.project()
        try CreateVariants().apply(to: &project)
        #expect(project.variants.count == 3)
        let v = project.variants
        #expect(v[0].shots != v[1].shots && v[1].shots != v[2].shots && v[0].shots != v[2].shots)
        for variant in project.variants { #expect(CutValidator.validate(project, cut: variant).isEmpty) }
        try SelectVariant(variantID: "variant-2").apply(to: &project)
        #expect(project.cut?.id == "variant-2")
        #expect(project.style.seed == project.variants[1].seed)
    }

    @Test func replacingTemplateUpdatesIdenticalCopies() throws {
        var project = try Self.project()
        let cut = project.cut!
        let copy = cut.shots.first { $0.reasons?.copiedFrom != nil }!
        let templateID = copy.reasons!.copiedFrom!
        let template = cut.shots.first { $0.id == templateID }!
        let other = project.clips.first { clip in
            !clip.excluded && clip.id != template.clipID
                && clip.meta.availableSeconds.doubleValue > max(template.duration, copy.duration) + 1
        }!
        try ReplaceShot(shotID: templateID, clipID: other.id, sceneID: other.scenes.first?.id, sourceIn: .zero)
            .apply(to: &project)
        let updated = project.cut!.shots.first { $0.id == copy.id }!
        #expect(updated.clipID == other.id)
        #expect(updated.sourceIn == .zero)
        let replaced = project.cut!.shots.first { $0.id == templateID }!
        #expect(replaced.locked)
        #expect(replaced.reasons?.components.isEmpty == true)
        #expect(replaced.reasons?.alternatives.isEmpty == false)
        #expect(CutValidator.validate(project, cut: project.cut!).isEmpty)
    }

    @Test func nudgeMovesByWholeSourceFrames() throws {
        var project = try Self.project()
        let shot = project.cut!.shots.first { $0.reasons?.copiedFrom == nil && !$0.locked }!
        let fps = project.clip(withID: shot.clipID)!.meta.fps
        let moved = (try? NudgeSourceIn(shotID: shot.id, frames: 1).apply(to: &project)) != nil
        if moved {
            let after = project.cut!.shots.first { $0.id == shot.id }!
            #expect(after.sourceIn == shot.sourceIn + Rational(1) / fps)
            #expect(after.locked)
        }
        #expect(CutValidator.validate(project, cut: project.cut!).isEmpty)
    }

    @Test func lockingSeveralShots() throws {
        var project = try Self.project()
        let ids = Set(project.cut!.shots.prefix(4).map(\.id))
        try SetShotsLocked(shotIDs: ids, locked: true).apply(to: &project)
        #expect(project.cut!.shots.filter(\.locked).map(\.id).sorted() == ids.sorted())
        let before = project.cut!
        try Reroll().apply(to: &project)
        #expect(CutValidator.validate(project, cut: project.cut!, previous: before).isEmpty)
    }
}

/// E2 im Kern: Rasterkorrekturen bei vorhandenem Schnitt lassen ihn gültig (Reparatur im selben Befehl).
@Suite struct GridRepairTests {
    @Test func gridEditsKeepCutValid() throws {
        var failures: [String] = []
        // 100 Seeds, zur Abnahme ein Zehntel von `SYLLABEAT_SEEDS`.
        let total = (ProcessInfo.processInfo.environment["SYLLABEAT_SEEDS"].flatMap(Int.init) ?? 1000) / 10
        for seed in UInt64(0)..<UInt64(total) {
            var project = SyntheticProject.make(seed: seed)
            try GenerateCut().apply(to: &project)
            let steps: [(String, any EditCommand)] = [
                ("Tempo ÷2", ScaleTempo(factor: .half)), ("Taktanfang", SetDownbeat(beatIndex: 1)),
                ("+30 ms", ShiftBeats(milliseconds: 30)), ("Tempo ×2", ScaleTempo(factor: .double)),
                ("×4⁄3", ScaleTempo(factor: .fourThirds)),
            ]
            for (name, command) in steps {
                do {
                    try command.apply(to: &project)
                } catch {
                    continue
                }
                guard let cut = project.cut else { continue }
                let issues = CutValidator.validate(project, cut: cut, minimumFactor: 0.5)
                if !issues.isEmpty { failures.append("Seed \(seed) nach \(name): \(issues.prefix(2))") }
            }
            if failures.count > 5 { break }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }
}
