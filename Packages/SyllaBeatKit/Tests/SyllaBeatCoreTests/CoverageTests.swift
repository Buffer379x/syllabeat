import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct CoverageTests {
    static func project(sections: [SongSection], clips: [Clip]) -> Project {
        var project = Project(
            clips: clips, analysis: SongAnalysis(duration: sections.map(\.end).max() ?? 0, sections: sections))
        project.story.chapters = [
            Chapter(id: "X", name: "X", color: 0), Chapter(id: "Y", name: "Y", color: 1),
            Chapter(id: "Z", name: "Z", color: 2),
        ]
        return project
    }

    static func clip(_ name: String, seconds: Double, chapter: String, blocked: [SourceRange] = []) -> Clip {
        var clip = StoryFixtures.clip(name, seconds: seconds)
        clip.chapterID = chapter
        clip.blocked = blocked
        return clip
    }

    static func need(_ report: CoverageReport, _ id: String) -> ChapterNeed? {
        report.chapters.first { $0.chapterID == id }
    }

    @Test func chapterNeedCountsSharesAndBlocked() throws {
        var project = Self.project(
            sections: [SongSection(id: "A", kind: .verse, label: "A", start: 0, end: 20)],
            clips: [Self.clip("x.mp4", seconds: 15, chapter: "X", blocked: [SourceRange(start: 2, end: 5)])])
        project.story.plan = ["A": ["X": .main, "Y": .mix]]
        let report = CoverageAnalyzer.analyze(project, lineConfidence: [:])
        let x = try #require(Self.need(report, "X"))
        #expect(abs(x.needed - 16) < 1e-9 && abs(x.available - 12) < 1e-9)
        #expect(x.status == .missing && x.suggestedClips == 2)
        let y = try #require(Self.need(report, "Y"))
        #expect(abs(y.needed - 4) < 1e-9 && y.available == 0 && y.status == .missing && y.suggestedClips == 1)
    }

    @Test func shortChapterNeedsReserve() throws {
        let section = SongSection(id: "A", kind: .verse, label: "A", start: 0, end: 15)
        var tight = Self.project(sections: [section], clips: [Self.clip("x.mp4", seconds: 15, chapter: "X")])
        tight.story.plan = ["A": ["X": .main]]
        let short = try #require(Self.need(CoverageAnalyzer.analyze(tight, lineConfidence: [:]), "X"))
        #expect(short.status == .short && short.suggestedClips == 1)
        var plenty = Self.project(sections: [section], clips: [Self.clip("x.mp4", seconds: 23, chapter: "X")])
        plenty.story.plan = ["A": ["X": .main]]
        let ok = try #require(Self.need(CoverageAnalyzer.analyze(plenty, lineConfidence: [:]), "X"))
        #expect(ok.status == .ok && ok.suggestedClips == 0)
    }

    @Test func identicalCopiesDoNotCount() throws {
        var project = Self.project(
            sections: [
                SongSection(id: "R1", kind: .chorus, label: "Refrain", start: 0, end: 10),
                SongSection(id: "R2", kind: .chorus, label: "Refrain", start: 10, end: 20, repeatOf: "R1"),
                SongSection(id: "R3", kind: .chorus, label: "Refrain", start: 20, end: 30, repeatOf: "R1"),
            ], clips: [Self.clip("z.mp4", seconds: 40, chapter: "Z")])
        project.story.plan = ["R1": ["Z": .main]]
        project.style.refrainMode = .identical
        #expect(Self.need(CoverageAnalyzer.analyze(project, lineConfidence: [:]), "Z")?.needed == 10)
    }

    @Test func lineGapsListUnclearAndMarkedLines() {
        var project = Self.project(sections: [], clips: [])
        project.analysis = SongAnalysis(duration: 20)
        project.analysis!.lines = [
            LyricLine(id: "1", text: "Die Ziegen kauen", start: 0, end: 4),
            LyricLine(id: "2", text: "Gucken, Streicheln, Füttern", start: 4, end: 8),
            LyricLine(id: "3", text: "Mäh, muh, oink", start: 8, end: 12),
        ]
        project.story.lineNeeds = ["Die Ziegen kauen": true, "Mäh, muh, oink": false]
        let report = CoverageAnalyzer.analyze(
            project,
            lineConfidence: ["Die Ziegen kauen": 1, "Gucken, Streicheln, Füttern": 0.42, "Mäh, muh, oink": 0.3])
        #expect(Set(report.lines.map(\.text)) == ["Die Ziegen kauen", "Gucken, Streicheln, Füttern"])
        #expect(report.lines.first { $0.text == "Die Ziegen kauen" }?.marked == true)
    }

    @Test func watermarkOnlyMotifsAreListed() {
        let project = Self.project(
            sections: [],
            clips: [
                StoryFixtures.clip("general_sun_sky_veo_watermark.mp4"),
                StoryFixtures.clip("general_drive_road_veo_watermark.mp4"),
                StoryFixtures.clip("general_drive_road_wan_no_watermark.mp4"),
            ])
        #expect(CoverageAnalyzer.analyze(project, lineConfidence: [:]).watermarkOnly == ["general sun sky"])
    }

    @Test func sameMotifTakeIsSureSuggestion() {
        var project = Self.project(
            sections: [],
            clips: [
                StoryFixtures.clip("farm_family_with_pigs_1080p_wan (2).mp4"),
                StoryFixtures.clip("farm_family_with_pigs_1080p_wan (4).mp4"),
            ])
        project.story.chapters = [Chapter(id: "tiere", name: "Tiere", color: 0)]
        project.clips[0].chapterID = "tiere"
        let suggestion = ChapterSuggester.suggest(for: project.clips[1], in: project, vectors: [:])
        #expect(suggestion?.chapterID == "tiere" && suggestion?.sure == true)
    }

    @Test func centroidSuggestionIsUnsure() {
        var project = Self.project(
            sections: [], clips: ["a.mp4", "b.mp4", "c.mp4", "neu.mp4"].map { StoryFixtures.clip($0) })
        project.story.chapters = [
            Chapter(id: "tag", name: "Tag", color: 0), Chapter(id: "heim", name: "Heimfahrt", color: 1),
        ]
        project.clips[0].chapterID = "tag"
        project.clips[1].chapterID = "heim"
        project.clips[2].chapterID = "heim"
        let vectors: [String: [Float]] = [
            "a.mp4": [1, 0], "b.mp4": [0, 1], "c.mp4": [0.2, 0.98], "neu.mp4": [0.1, 0.99],
        ]
        let suggestion = ChapterSuggester.suggest(for: project.clips[3], in: project, vectors: vectors)
        #expect(suggestion?.chapterID == "heim" && suggestion?.sure == false)
        project.story.chapters = []
        #expect(ChapterSuggester.suggest(for: project.clips[3], in: project, vectors: vectors) == nil)
    }

    @Test func lineNeedAndPromptStyleCommands() throws {
        var project = Project()
        try SetLineNeed(text: "Die Ziegen", need: true).apply(to: &project)
        try SetPromptStyle(text: "Strickpuppen").apply(to: &project)
        #expect(project.story.lineNeeds == ["Die Ziegen": true] && project.story.promptStyle == "Strickpuppen")
        try SetLineNeed(text: "Die Ziegen", need: nil).apply(to: &project)
        #expect(project.story.lineNeeds.isEmpty)
    }
}

@Suite struct SceneIndexVectorTests {
    @Test func clipVectorsAreNormalizedMeans() {
        let index = SceneIndex(entries: [
            SceneIndex.Entry(clipID: "a", sceneID: "a1", sceneStart: 0, vector: [1, 0]),
            SceneIndex.Entry(clipID: "a", sceneID: "a2", sceneStart: 4, vector: [0, 1]),
        ])
        let vector = index.clipVectors()["a"] ?? []
        #expect(vector.count == 2 && abs(vector[0] - 0.7071) < 1e-3 && abs(vector[1] - 0.7071) < 1e-3)
    }
}

@Suite struct BatchLookupTests {
    @Test func suggestAllMatchesSingleSuggestions() {
        var project = Project(
            clips: ["farm_pigs_wan.mp4", "farm_pigs_wan (2).mp4", "x.mp4"].map { StoryFixtures.clip($0) })
        project.story.chapters = [Chapter(id: "k", name: "Tiere", color: 0)]
        project.clips[0].chapterID = "k"
        let vectors: [String: [Float]] = ["farm_pigs_wan.mp4": [1, 0], "x.mp4": [0.9, 0.1]]
        let all = ChapterSuggester.suggestAll(in: project, vectors: vectors)
        for clip in project.clips where clip.chapterID == nil {
            let single = ChapterSuggester.suggest(for: clip, in: project, vectors: vectors)
            #expect(all[clip.id]?.chapterID == single?.chapterID && all[clip.id]?.sure == single?.sure)
        }
        #expect(all["farm_pigs_wan (2).mp4"]?.sure == true)
    }

    @Test func traitValuesMatchSingleLookups() {
        var project = Project(clips: [StoryFixtures.clip("drive_sunset.mp4"), StoryFixtures.clip("wiese.mp4")])
        project.clips[1].traits["tageszeit"] = TraitValue(value: "Nacht", source: .user)
        let all = StoryResolver.values(.timeOfDay, in: project)
        #expect(all["drive_sunset.mp4"]?.value == "Abend" && all["wiese.mp4"]?.value == "Nacht")
    }
}
