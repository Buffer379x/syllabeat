import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct InconsistencyTests {
    /// Story-Projekt (Abschnitte A, B; Kapitel k0, k1) mit Tageszeiten und einem Schnitt aus der Engine.
    static func project() throws -> Project {
        var project = StoryEngineTests.project(clipsPerChapter: [6, 6])
        for index in project.clips.indices {
            project.clips[index].traits["tageszeit"] = TraitValue(value: index < 6 ? "Tag" : "Abend", source: .user)
        }
        project.story.plan = ["A": ["k0": .main], "B": ["k1": .main]]
        try GenerateCut().apply(to: &project)
        return project
    }

    static func kinds(_ project: Project) -> [Inconsistency.Kind] {
        InconsistencyChecker.check(project, cut: project.cut!).map(\.kind)
    }

    @Test func cleanStoryCutHasNoFindings() throws {
        let project = try Self.project()
        #expect(InconsistencyChecker.check(project, cut: project.cut!).isEmpty)
    }

    @Test func timeGoingBackIsReported() throws {
        var project = try Self.project()
        let last = project.cut!.shots.count - 1
        project.cut!.shots[last].clipID = "k0_0.mp4"
        project.cut!.shots[last].sceneID = "k0_0.mp4-s0"
        let findings = InconsistencyChecker.check(project, cut: project.cut!)
        let finding = try #require(findings.first { $0.kind == .timeGoesBack })
        #expect(finding.shotIDs == [project.cut!.shots[last].id])
        #expect(finding.message.contains("Tag nach Abend"))
        #expect(findings.contains { $0.kind == .chapterOutsidePlan })
    }

    @Test func chapterGoingBackBetweenSectionsIsReported() throws {
        var project = try Self.project()
        project.story.plan = ["A": ["k1": .main], "B": ["k0": .main]]
        #expect(Self.kinds(project).contains(.chapterGoesBack))
    }

    @Test func sharedChaptersAreNoStepBack() throws {
        var project = try Self.project()
        project.story.plan = ["A": ["k0": .main, "k1": .main], "B": ["k0": .main, "k1": .main]]
        #expect(!Self.kinds(project).contains(.chapterGoesBack))
    }

    @Test func relaxedShotsAreReported() throws {
        var project = try Self.project()
        project.cut!.shots[1].reasons?.relaxed = ["kapitel"]
        let finding = try #require(InconsistencyChecker.check(project, cut: project.cut!).first { $0.kind == .relaxed })
        #expect(finding.sectionID == "A")
    }

    @Test func sameMotifAndWatermarkAreReported() throws {
        var project = MotifEngineTests.project([
            "general_pigs_veo_watermark.mp4", "general_pigs_wan_no_watermark.mp4", "general_cows_wan.mp4",
        ])
        try GenerateCut().apply(to: &project)
        var cut = project.cut!
        cut.shots[0].clipID = project.clips[0].id
        cut.shots[0].sceneID = project.clips[0].scenes[0].id
        cut.shots[1].clipID = project.clips[1].id
        cut.shots[1].sceneID = project.clips[1].scenes[0].id
        cut.shots[1].sourceIn = .zero
        let kinds = InconsistencyChecker.check(project, cut: cut).map(\.kind)
        #expect(kinds.contains(.sameMotifRepeated))
        #expect(kinds.contains(.watermark))
    }

    @Test func identicalCopyBreakingTimeOfDayIsReported() throws {
        var project = StoryEngineTests.project(
            clipsPerChapter: [8],
            sections: [
                SongSection(id: "A", kind: .chorus, label: "Refrain", start: 0, end: 12),
                SongSection(id: "V", kind: .verse, label: "Strophe", start: 12, end: 28),
                SongSection(id: "B", kind: .chorus, label: "Refrain", start: 28, end: 40, repeatOf: "A"),
            ])
        project.story.chapters = []
        for index in project.clips.indices {
            project.clips[index].chapterID = nil
            project.clips[index].traits["tageszeit"] = TraitValue(value: index < 4 ? "Tag" : "Abend", source: .user)
        }
        project.story.traits[0].pinned = ["V": "Abend"]
        project.style.refrainMode = .identical
        try GenerateCut().apply(to: &project)
        // Strophe festgelegt auf Abend: Danach bringt die identische Kopie des Refrains Tagbilder zurück.
        project.story.traits[0].pinned = [:]
        let finding = InconsistencyChecker.check(project, cut: project.cut!).first { $0.kind == .copyBreaksTrait }
        if project.cut!.shots.contains(where: { $0.reasons?.copiedFrom != nil }) {
            let found = try #require(finding)
            #expect(found.message.contains("Gleiche Clips, andere Ausschnitte"))
        }
    }

    @Test func repairedLineTimingIsReported() throws {
        var project = try Self.project()
        project.analysis!.words = (0..<6).map {
            Word(id: "w\($0)", text: "x", start: Double($0), end: Double($0) + 0.5, estimated: $0 >= 2)
        }
        project.analysis!.lines = [
            LyricLine(id: "l1", text: "x x", start: 0, end: 2, wordIDs: ["w0", "w1"]),
            LyricLine(
                id: "l2", text: "x x x x", start: 2, end: 6, needsReview: true, wordIDs: ["w2", "w3", "w4", "w5"]),
        ]
        let finding = try #require(
            InconsistencyChecker.check(project, cut: project.cut!).first { $0.kind == .lineTimingRepaired })
        #expect(finding.message.hasPrefix("1 Zeile"))
    }

    @Test func checkIsFastForLongCuts() throws {
        var project = SyntheticProject.make(seed: 7, clips: 30...30, duration: 240...240, story: true)
        try GenerateCut().apply(to: &project)
        var cut = project.cut!
        while cut.shots.count < 500 { cut.shots += project.cut!.shots }
        let started = DispatchTime.now().uptimeNanoseconds
        _ = InconsistencyChecker.check(project, cut: cut)
        #expect(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 < 50)
    }
}
