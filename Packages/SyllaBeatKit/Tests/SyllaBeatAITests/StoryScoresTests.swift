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

@Suite struct LineRowsTests {
    @Test func pronounLineInheritsPreviousSubject() async throws {
        var analysis = SongAnalysis(duration: 20)
        analysis.lines = [
            LyricLine(id: "l1", text: "Die Pferde auf der Koppel", start: 1, end: 4),
            LyricLine(id: "l2", text: "Sie traben auf und ab", start: 5, end: 8),
        ]
        func row(best: String) -> [String: Float] {
            var row = Dictionary(
                uniqueKeysWithValues: (0..<40).map { ("s\($0)", Float(0.05 + Double($0 % 3) * 0.001)) })
            row["pferd"] = 0.05
            row[best] = 0.12
            return row
        }
        let rows = try await StoryScores.lineRows(analysis, descriptions: [:]) { text in
            // Zweite Zeile ohne klaren Treffer (Maximum kaum über dem Rest).
            text.hasPrefix("Die Pferde") ? row(best: "pferd") : row(best: "s7").mapValues { min($0, 0.055) }
        }
        let second = try #require(rows["l2"])
        #expect(second.max { $0.value < $1.value }?.key == "pferd")
    }

    @Test func namesFromFileNamesMatchLyrics() {
        let clip = Clip(
            id: "c", media: MediaRef(path: "/farm_emi_dancing_with_ducks_1080p_wan.mp4"),
            meta: ClipMetadata(duration: 5, fps: Rational(25), width: 1, height: 1),
            scenes: [ClipScene(id: "c-s0", start: 0, end: 5)])
        let descriptions = StoryScores.descriptions(of: Project(clips: [clip]))
        var row: [String: Float] = ["c-s0": 0]
        StoryScores.addBonus(
            to: &row, words: StoryScores.words("Emilia streichelt sanft ein Schaf"), descriptions: descriptions)
        #expect((row["c-s0"] ?? 0) > 0)
    }
}
