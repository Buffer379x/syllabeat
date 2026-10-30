import Foundation
import Testing

@testable import SyllaBeatCore

/// Bausteine für Tests rund um Geschichte, Kapitel und Kontinuität.
enum StoryFixtures {
    static func clip(_ name: String, seconds: Double = 15, fps: Rational = Rational(30)) -> Clip {
        Clip(
            id: name, media: MediaRef(path: "/tmp/\(name)"),
            meta: ClipMetadata(
                duration: seconds, fps: fps, frameCount: (Rational(seconds: seconds) * fps).roundedHalfUp(),
                width: 1920, height: 1080),
            scenes: [ClipScene(id: "\(name)-s0", start: 0, end: seconds, features: SceneFeatures())])
    }

    static func shot(_ number: Int, _ start: Double, _ end: Double, _ clipID: String) -> Shot {
        Shot(
            id: "shot-\(number)", start: CutPoint(time: start, anchor: .free), end: CutPoint(time: end, anchor: .free),
            clipID: clipID, sceneID: "\(clipID)-s0", sourceIn: .zero)
    }
}

@Suite struct StoryMetricsTests {
    @Test func measuresChapterLineAndSwitches() throws {
        let clips = ["farm_goats.mp4", "general_drive.mp4", "general_drive_sunset.mp4"].map {
            StoryFixtures.clip($0)
        }
        var analysis = SongAnalysis(
            duration: 8,
            sections: [
                SongSection(id: "a", kind: .verse, label: "A", start: 0, end: 4),
                SongSection(id: "b", kind: .verse, label: "B", start: 4, end: 8),
            ])
        analysis.lines = [LyricLine(id: "l1", text: "Die Ziegen", start: 0, end: 4)]
        let project = Project(clips: clips, analysis: analysis)
        let cut = Cut(
            id: "c", name: "c", seed: 1, origin: .manual,
            shots: [
                StoryFixtures.shot(1, 0, 1, "farm_goats.mp4"), StoryFixtures.shot(2, 1, 2, "general_drive.mp4"),
                StoryFixtures.shot(3, 2, 4, "farm_goats.mp4"), StoryFixtures.shot(4, 4, 6, "general_drive_sunset.mp4"),
                StoryFixtures.shot(5, 6, 8, "general_drive.mp4"),
            ])
        let truth = try JSONDecoder().decode(
            StoryTruth.self,
            from: Data(
                """
                {"kapitel": {"Hof": ["goats"], "Fahrt": ["drive"]}, "abschnitte": {"A": ["Hof"], "B": ["Fahrt"]},
                 "zeilen": [{"enthaelt": ["Ziegen"], "motive": ["goats"]}], "abend": ["sunset"]}
                """.utf8))
        let measurement = StoryMetrics.measure(project, cut: cut, truth: truth)
        #expect(measurement.chapterHits == 0.875)
        #expect(measurement.lineHits == 0.75)
        #expect(measurement.timeSwitches == 2)
        #expect(measurement.sandwiches == 1)
        #expect(measurement.shots == 5)
    }
}
