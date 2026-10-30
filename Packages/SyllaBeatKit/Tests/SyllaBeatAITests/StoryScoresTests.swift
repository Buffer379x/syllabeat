import Testing

@testable import SyllaBeatAI
@testable import SyllaBeatCore

@Suite struct StoryScoresTests {
    @Test func chapterEvidenceAveragesZScores() {
        var a = Clip(
            id: "a", media: MediaRef(path: "/a.mp4"),
            meta: ClipMetadata(duration: 5, fps: Rational(25), width: 1, height: 1))
        a.scenes = [ClipScene(id: "a-s0", start: 0, end: 5)]
        a.chapterID = "k0"
        var b = a
        b = Clip(
            id: "b", media: MediaRef(path: "/b.mp4"), meta: a.meta, scenes: [ClipScene(id: "b-s0", start: 0, end: 5)])
        b.chapterID = "k1"
        var analysis = SongAnalysis(
            duration: 20, sections: [SongSection(id: "s0", kind: .verse, label: "S", start: 0, end: 10)])
        analysis.lines = [LyricLine(id: "l1", text: "Ziegen", start: 1, end: 4)]
        var project = Project(clips: [a, b], analysis: analysis)
        project.story.chapters = [Chapter(id: "k0", name: "A", color: 0), Chapter(id: "k1", name: "B", color: 1)]
        let evidence = StoryScores.chapterEvidence(project, rows: ["l1": ["a-s0": 0.3, "b-s0": 0.1]])
        let values = evidence["s0"] ?? []
        #expect(values.count == 2)
        #expect(abs(values[0] - 1) < 1e-6 && abs(values[1] + 1) < 1e-6)
    }
}
