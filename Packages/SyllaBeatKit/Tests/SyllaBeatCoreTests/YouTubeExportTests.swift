import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct YouTubeExportTests {
    @Test func chaptersStartAtZeroAndMergeShortParts() throws {
        let chapters = ["Aufbruch", "Hinfahrt", "Tiere", "Heimfahrt"]
        var project = Project(clips: chapters.map { StoryFixtures.clip("\($0).mp4", seconds: 200) })
        project.analysis = SongAnalysis(duration: 212)
        project.story.chapters = chapters.enumerated().map { Chapter(id: $1, name: $1, color: $0) }
        for index in project.clips.indices { project.clips[index].chapterID = chapters[index] }
        let bounds: [(Double, Double, String)] = [
            (0, 25, "Aufbruch"), (25, 31, "Hinfahrt"), (31, 150, "Tiere"), (150, 212, "Heimfahrt"),
        ]
        let cut = Cut(
            id: "c", name: "c", seed: 1, origin: .manual,
            shots: bounds.enumerated().map { StoryFixtures.shot($0 + 1, $1.0, $1.1, "\($1.2).mp4") })
        #expect(YouTubeExport.chapters(project, cut: cut) == "0:00 Aufbruch\n0:31 Tiere\n2:30 Heimfahrt\n")
    }

    @Test func fallsBackToSectionsWithoutStory() {
        var project = Project(clips: [StoryFixtures.clip("a.mp4", seconds: 200)])
        project.analysis = SongAnalysis(
            duration: 60,
            sections: [
                SongSection(id: "1", kind: .intro, label: "Intro", start: 0, end: 12),
                SongSection(id: "2", kind: .verse, label: "Strophe", start: 12, end: 40),
                SongSection(id: "3", kind: .chorus, label: "Refrain", start: 40, end: 60),
            ])
        let cut = Cut(id: "c", name: "c", seed: 1, origin: .manual, shots: [StoryFixtures.shot(1, 0, 60, "a.mp4")])
        #expect(YouTubeExport.chapters(project, cut: cut) == "0:00 Intro\n0:12 Strophe\n0:40 Refrain\n")
        project.analysis!.sections.removeLast()
        #expect(YouTubeExport.chapters(project, cut: cut) == nil)
    }

    @Test func thumbnailPrefersRatedAestheticScene() throws {
        var clips = ["a.mp4", "b.mp4", "c.mp4", "d.mp4"].map { StoryFixtures.clip($0) }
        let values: [(Double, Int?, Bool)] = [(0.2, nil, false), (0.6, 2, false), (0.5, 5, false), (0.9, nil, true)]
        for (index, value) in values.enumerated() {
            clips[index].scenes[0].features = SceneFeatures(aesthetics: value.0, isUtility: value.2)
            clips[index].rating = value.1
        }
        let project = Project(clips: clips, analysis: SongAnalysis(duration: 8))
        let cut = Cut(
            id: "c", name: "c", seed: 1, origin: .manual,
            shots: clips.enumerated().map { StoryFixtures.shot($0 + 1, Double($0) * 2, Double($0 + 1) * 2, $1.id) })
        let pick = try #require(YouTubeExport.thumbnailScene(project, cut: cut))
        #expect(pick.clipID == "c.mp4" && pick.sceneID == "c.mp4-s0")
    }
}
