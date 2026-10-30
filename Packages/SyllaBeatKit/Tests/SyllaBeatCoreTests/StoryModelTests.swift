import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct StoryModelTests {
    /// Projekt mit Clip und Analyse, wie es 0.3.0 gesichert hätte (Format 2, ohne neue Schlüssel).
    static func version2Data() throws -> Data {
        var project = Project(name: "Alt", clips: [StoryFixtures.clip("a.mp4")])
        project.version = 2
        var object = try JSONSerialization.jsonObject(with: ProjectFile.encode(project)) as! [String: Any]
        object["version"] = 2
        object["story"] = nil
        var clips = object["clips"] as! [[String: Any]]
        for index in clips.indices {
            for key in ["chapterID", "traits", "blocked"] { clips[index][key] = nil }
        }
        object["clips"] = clips
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func version2ProjectOpensWithEmptyStory() throws {
        let text = String(decoding: try Self.version2Data(), as: UTF8.self)
        #expect(!text.contains("story") && !text.contains("blocked"))
        let loaded = try ProjectFile.decode(Self.version2Data())
        #expect(loaded.project.story.chapters.isEmpty)
        #expect(loaded.project.story.traits == [.timeOfDay])
        #expect(loaded.project.clips.allSatisfy { $0.blocked.isEmpty && $0.chapterID == nil && $0.traits.isEmpty })
    }

    @Test func storyRoundTrips() throws {
        var project = Project(name: "Bauernhof", clips: [StoryFixtures.clip("farm_goats.mp4")])
        project.story.chapters = [
            Chapter(id: "k1", name: "Aufbruch", color: 0),
            Chapter(id: "k2", name: "Heimfahrt", color: 1, traits: ["tageszeit": "Abend"]),
        ]
        project.story.plan = ["sec-1": ["k1": .main, "k2": .mix]]
        project.story.traits[0].pinned = ["sec-2": "Nacht"]
        project.story.lineNeeds = ["Die Ziegen": true]
        project.story.promptStyle = "Strickpuppen"
        project.clips[0].chapterID = "k1"
        project.clips[0].blocked = [SourceRange(start: 2, end: 3.5)]
        project.clips[0].traits = ["tageszeit": TraitValue(value: "Tag", source: .user)]
        let data = try ProjectFile.encode(project)
        let reloaded = try ProjectFile.decode(data).project
        #expect(reloaded == project)
        #expect(reloaded.version == 3)
        #expect(String(decoding: data, as: UTF8.self).contains("\"version\" : 3"))
    }

    @Test func version4IsRejected() {
        #expect(throws: ProjectFileError.unsupportedVersion(4)) {
            try ProjectFile.decode(Data(#"{"version": 4}"#.utf8))
        }
    }

    @Test func mergingAnalysisKeepsStoryFields() {
        var clip = StoryFixtures.clip("a.mp4")
        clip.chapterID = "k1"
        clip.blocked = [SourceRange(start: 1, end: 2)]
        clip.traits = [
            "tageszeit": TraitValue(value: "Abend", source: .user),
            "wetter": TraitValue(value: "Regen", source: .fileName),
        ]
        let merged = clip.mergingAnalysis(StoryFixtures.clip("a.mp4"))
        #expect(merged.chapterID == "k1")
        #expect(merged.blocked == clip.blocked)
        #expect(merged.traits == ["tageszeit": TraitValue(value: "Abend", source: .user)])
    }

    @Test func relaxedRulesDefaultToEmpty() throws {
        let reasons = try JSONDecoder().decode(
            ShotReasons.self, from: Data(#"{"components": {}, "total": 0, "alternatives": []}"#.utf8))
        #expect(reasons.relaxed.isEmpty)
    }
}
