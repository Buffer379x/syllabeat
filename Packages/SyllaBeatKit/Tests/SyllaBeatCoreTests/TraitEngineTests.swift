import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct TraitEngineTests {
    /// 12 Clips ohne Kapitel; die ersten `evening` Clips sind „Abend“ (Nutzerwert), der Rest „Tag“ oder unbekannt.
    static func project(evening: Int = 6, unknownRest: Bool = false) -> Project {
        var project = StoryEngineTests.project()
        project.story.chapters = []
        for index in project.clips.indices {
            project.clips[index].chapterID = nil
            if index < evening {
                project.clips[index].traits["tageszeit"] = TraitValue(value: "Abend", source: .user)
            } else if !unknownRest {
                project.clips[index].traits["tageszeit"] = TraitValue(value: "Tag", source: .user)
            }
        }
        return project
    }

    static func levels(_ project: Project, _ cut: Cut) -> [Int] {
        cut.shots.compactMap { shot in
            project.clip(withID: shot.clipID)?.traits["tageszeit"].flatMap { Trait.timeOfDay.level($0.value) }
        }
    }

    @Test func timeOfDayNeverGoesBack() throws {
        var project = Self.project()
        for seed in UInt64(1)...10 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style))
            let levels = Self.levels(project, cut)
            #expect(levels == levels.sorted(), "Seed \(seed): \(levels)")
            #expect(CutValidator.validate(project, cut: cut).isEmpty)
        }
    }

    @Test func pinnedSectionOverridesTimeOfDay() throws {
        var project = Self.project()
        project.story.traits[0].pinned = ["A": "Abend", "B": "Tag"]
        let cut = try #require(CutEngine.generate(project, style: project.style))
        let a = StoryEngineTests.shots(in: "A", project, cut)
        let b = StoryEngineTests.shots(in: "B", project, cut)
        #expect(Self.levels(project, Cut(id: "", name: "", seed: 0, origin: .engine, shots: a)).allSatisfy { $0 == 1 })
        #expect(Self.levels(project, Cut(id: "", name: "", seed: 0, origin: .engine, shots: b)).allSatisfy { $0 == 0 })
        #expect(CutValidator.validate(project, cut: cut).isEmpty)
    }

    @Test func unknownTimeOfDayIsNeutral() throws {
        var project = Self.project(evening: 1, unknownRest: true)
        project.style.seed = 3
        let cut = try #require(CutEngine.generate(project, style: project.style))
        #expect(!cut.shots.contains { $0.reasons?.relaxed.isEmpty == false })
        #expect(CutValidator.validate(project, cut: cut).isEmpty)
    }

    @Test func validatorReportsTimeGoingBack() throws {
        let project = Self.project()
        var cut = try #require(CutEngine.generate(project, style: project.style))
        cut.shots[0].clipID = project.clips[6].id
        cut.shots[0].sceneID = project.clips[6].scenes[0].id
        cut.shots[1].clipID = project.clips[0].id
        cut.shots[1].sceneID = project.clips[0].scenes[0].id
        cut.shots[2].clipID = project.clips[7].id
        cut.shots[2].sceneID = project.clips[7].scenes[0].id
        #expect(CutValidator.validate(project, cut: cut).contains { $0.hasPrefix("I10") })
    }

    @Test func sourcePriority() {
        var clip = StoryFixtures.clip("drive_sunset.mp4")
        let motif = FileNameMotif.parse(clip.name)
        #expect(StoryResolver.traitValue(clip, trait: .timeOfDay, chapter: nil, motif: motif)?.0 == "Abend")
        clip.traits["tageszeit"] = TraitValue(value: "Tag", source: .user)
        #expect(StoryResolver.traitValue(clip, trait: .timeOfDay, chapter: nil, motif: motif)?.0 == "Tag")
        // Der Dateiname eines Clips schlägt die pauschale Kapitel-Vorgabe.
        let day = Chapter(id: "d", name: "Aufbruch", color: 0, traits: ["tageszeit": "Tag"])
        let sunset = StoryFixtures.clip("walks_down_the_street_during_sunset.mp4")
        #expect(
            StoryResolver.traitValue(sunset, trait: .timeOfDay, chapter: day, motif: FileNameMotif.parse(sunset.name))?
                .0 == "Abend")
        var plain = StoryFixtures.clip("wiese.mp4")
        plain.description = "Kinder auf der Wiese bei hellem Tageslicht"
        let evening = Chapter(id: "k", name: "Heimfahrt", color: 0, traits: ["tageszeit": "Abend"])
        #expect(
            StoryResolver.traitValue(
                plain, trait: .timeOfDay, chapter: evening, motif: FileNameMotif.parse(plain.name))?
                .0 == "Abend")
    }

    @Test func descriptionKeywords() {
        #expect(StoryResolver.timeOfDay(fromDescription: "Kinder gehen zum Haus bei Sonnenuntergang") == "Abend")
        #expect(StoryResolver.timeOfDay(fromDescription: "Kühe auf einer grünen Wiese") == "Tag")
        #expect(StoryResolver.timeOfDay(fromDescription: "") == nil)
        #expect(StoryResolver.timeOfDay(fromDescription: "Sterne über dem Hof") == "Nacht")
    }

    @Test func traitCommandsSetValuesAndPins() throws {
        var project = Self.project(evening: 0, unknownRest: true)
        try SetTraitValue(clipIDs: [project.clips[0].id], traitID: "tageszeit", value: "Nacht").apply(to: &project)
        #expect(project.clips[0].traits["tageszeit"] == TraitValue(value: "Nacht", source: .user))
        try SetTraitValue(clipIDs: [project.clips[0].id], traitID: "tageszeit", value: nil).apply(to: &project)
        #expect(project.clips[0].traits["tageszeit"] == nil)
        try SetTraitPin(traitID: "tageszeit", sectionID: "B", value: "Abend").apply(to: &project)
        #expect(project.story.traits[0].pinned == ["B": "Abend"])
        project.story.chapters = [Chapter(id: "k", name: "K", color: 0)]
        try SetChapterTrait(chapterID: "k", traitID: "tageszeit", value: "Abend").apply(to: &project)
        #expect(project.story.chapters[0].traits == ["tageszeit": "Abend"])
    }
}

@Suite struct TraitPacingTests {
    /// Ein Abend-Clip unter sonst gleichen Tag-Clips: Die Tageszeit rückt nicht ohne Not vor.
    @Test func eveningIsNotChosenEarlyWithoutNeed() throws {
        var project = TraitEngineTests.project(evening: 1)
        // Der Abend-Clip ist verlockend (5 Sterne, beste Ästhetik), so wie ein Text-Treffer im ersten Abschnitt.
        project.clips[0].rating = 5
        project.clips[0].scenes[0].features?.aesthetics = 1
        var early = 0
        for seed in UInt64(1)...20 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style))
            let first = cut.shots.prefix(cut.shots.count / 2)
            if first.contains(where: { $0.clipID == project.clips[0].id }) { early += 1 }
        }
        #expect(early <= 2, "Abend-Clip in der ersten Hälfte bei \(early) von 20 Seeds")
    }

    /// Wie im Bauernhof: Kapitel k0 (Abschnitt A) hat einen verlockenden Abend-Clip, Abschnitt B zeigt nur Tag-Material
    /// aus k1. Der Abend-Clip darf in A nicht vorkommen, sonst müsste B zurückspringen.
    @Test func eveningIsNotChosenWhenLaterSectionsNeedDay() throws {
        var project = StoryEngineTests.project(clipsPerChapter: [4, 4])
        for index in project.clips.indices {
            project.clips[index].traits["tageszeit"] = TraitValue(value: index == 0 ? "Abend" : "Tag", source: .user)
        }
        project.clips[0].rating = 5
        project.clips[0].scenes[0].features?.aesthetics = 1
        project.story.plan = ["A": ["k0": .main], "B": ["k1": .main]]
        for seed in UInt64(1)...20 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style))
            #expect(!cut.shots.contains { $0.clipID == project.clips[0].id }, "Seed \(seed)")
            #expect(!cut.shots.contains { $0.reasons?.relaxed.isEmpty == false }, "Seed \(seed)")
        }
    }
}
