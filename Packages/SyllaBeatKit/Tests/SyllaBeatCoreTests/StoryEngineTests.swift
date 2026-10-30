import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct StoryEngineTests {
    /// Song 40 s (Beats alle 0,5 s), Abschnitte A 0–20 s und B 20–40 s; je 4 Clips (15 s) in den Kapiteln k0, k1, k2.
    static func project(clipsPerChapter: [Int] = [4, 4, 4], sections: [SongSection]? = nil) -> Project {
        let beats = (1..<80).map { Beat(time: Double($0) * 0.5, isDownbeat: $0 % 4 == 0) }
        let analysis = SongAnalysis(
            duration: 40, tempo: 120, beats: beats,
            sections: sections ?? [
                SongSection(id: "A", kind: .verse, label: "A", start: 0, end: 20),
                SongSection(id: "B", kind: .verse, label: "B", start: 20, end: 40),
            ], energy: beats.map { _ in 0.5 })
        var clips: [Clip] = []
        for (chapter, count) in clipsPerChapter.enumerated() {
            for index in 0..<count {
                var clip = StoryFixtures.clip("k\(chapter)_\(index).mp4", fps: Rational(25))
                clip.chapterID = "k\(chapter)"
                clips.append(clip)
            }
        }
        var project = Project(clips: clips, analysis: analysis)
        project.story.chapters = (0..<clipsPerChapter.count).map { Chapter(id: "k\($0)", name: "K\($0)", color: $0) }
        return project
    }

    static func chapter(of shot: Shot, in project: Project) -> String? {
        project.clip(withID: shot.clipID)?.chapterID
    }

    static func shots(in section: String, _ project: Project, _ cut: Cut) -> [Shot] {
        let range = project.analysis!.sections.first { $0.id == section }!
        return cut.shots.filter {
            ($0.start.time + $0.end.time) / 2 >= range.start && ($0.start.time + $0.end.time) / 2 < range.end
        }
    }

    @Test func sectionUsesOnlyPlannedChapters() throws {
        var project = Self.project()
        project.story.plan = ["A": ["k0": .main], "B": ["k2": .main]]
        for seed in UInt64(1)...10 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style))
            #expect(Self.shots(in: "A", project, cut).allSatisfy { Self.chapter(of: $0, in: project) == "k0" })
            #expect(Self.shots(in: "B", project, cut).allSatisfy { Self.chapter(of: $0, in: project) == "k2" })
            #expect(CutValidator.validate(project, cut: cut).isEmpty)
        }
    }

    @Test func chaptersProgressWithinSection() throws {
        var project = Self.project()
        project.story.plan = ["A": ["k0": .main, "k1": .main], "B": ["k1": .main, "k2": .main]]
        for seed in UInt64(1)...10 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style))
            for section in ["A", "B"] {
                let indices = Self.shots(in: section, project, cut).compactMap {
                    Self.chapter(of: $0, in: project).flatMap { id in project.story.chapters.firstIndex { $0.id == id }
                    }
                }
                #expect(indices == indices.sorted(), "Seed \(seed), \(section): \(indices)")
            }
        }
    }

    @Test func montageIgnoresProgress() throws {
        var project = Self.project()
        project.story.plan = ["A": ["k0": .main, "k1": .main], "B": ["k1": .main, "k2": .main]]
        project.story.montage = ["A", "B"]
        var fell = false
        for seed in UInt64(1)...20 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style))
            let indices = Self.shots(in: "A", project, cut).compactMap {
                Self.chapter(of: $0, in: project).flatMap { id in project.story.chapters.firstIndex { $0.id == id } }
            }
            if indices != indices.sorted() { fell = true }
        }
        #expect(fell)
    }

    @Test func missingChapterMaterialFallsBack() throws {
        var project = Self.project(clipsPerChapter: [4, 1, 4])
        // Der einzige Clip von k1 ist kürzer als jeder Slot: Die Engine muss ausweichen.
        project.clips[4].meta.duration = 1
        project.clips[4].meta.frameCount = 25
        project.clips[4].scenes[0].end = 1
        project.story.plan = ["A": ["k1": .main], "B": ["k2": .main]]
        let cut = try #require(CutEngine.generate(project, style: project.style))
        let relaxed = cut.shots.filter { $0.reasons?.relaxed.contains("kapitel") == true }
        #expect(!relaxed.isEmpty)
        #expect(CutValidator.validate(project, cut: cut).isEmpty)
    }

    @Test func repeatInheritsTemplatePlan() throws {
        var project = Self.project(
            sections: [
                SongSection(id: "A", kind: .chorus, label: "Refrain", start: 0, end: 20),
                SongSection(id: "B", kind: .chorus, label: "Refrain", start: 20, end: 40, repeatOf: "A"),
            ])
        project.style.refrainMode = .free
        project.story.plan = ["A": ["k2": .main]]
        let cut = try #require(CutEngine.generate(project, style: project.style))
        #expect(Self.shots(in: "B", project, cut).allSatisfy { Self.chapter(of: $0, in: project) == "k2" })
    }

    @Test func validatorReportsChapterOutsidePlan() throws {
        var project = Self.project()
        project.story.plan = ["A": ["k0": .main]]
        var cut = try #require(CutEngine.generate(project, style: project.style))
        cut.shots[0].clipID = "k2_0.mp4"
        cut.shots[0].sceneID = "k2_0.mp4-s0"
        #expect(CutValidator.validate(project, cut: cut).contains { $0.hasPrefix("I9") })
    }
}
