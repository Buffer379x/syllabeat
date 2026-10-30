import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct StoryCommandTests {
    /// Quellbereich eines Shots in Sekunden.
    static func source(_ shot: Shot) -> SourceRange {
        SourceRange(start: shot.sourceIn.doubleValue, end: shot.sourceIn.doubleValue + shot.duration)
    }

    @Test func rangesAreClampedAndMerged() throws {
        var project = Project(clips: [StoryFixtures.clip("a.mp4", seconds: 15)])
        try SetBlockedRanges(
            clipID: "a.mp4",
            ranges: [
                SourceRange(start: -1, end: 2), SourceRange(start: 1, end: 3), SourceRange(start: 14, end: 20),
                SourceRange(start: 5, end: 5),
            ]
        ).apply(to: &project)
        #expect(project.clips[0].blocked == [SourceRange(start: 0, end: 3), SourceRange(start: 14, end: 15)])
    }

    @Test func blockingUsedSourceRecutsOnlyThatShot() throws {
        var project = try CutCommandTests.project()
        let shots = project.cut!.shots
        let copied = Set(shots.compactMap { $0.reasons?.copiedFrom })
        let target = try #require(shots.dropFirst(2).first { $0.reasons?.copiedFrom == nil && !copied.contains($0.id) })
        try BlockShotSource(shotID: target.id).apply(to: &project)
        let after = project.cut!.shots
        #expect(after.count == shots.count)
        for (old, new) in zip(shots, after) where old.id != target.id {
            #expect(old.clipID == new.clipID && old.sourceIn == new.sourceIn && old.start == new.start)
        }
        let recut = try #require(after.first { $0.id == target.id })
        #expect(recut.clipID != target.clipID || recut.sourceIn != target.sourceIn)
        #expect(project.clip(withID: target.clipID)!.blocked.contains(Self.source(target)))
        #expect(CutValidator.validate(project, cut: project.cut!).isEmpty)
    }

    @Test func blockingLockedTemplateRecutsCopies() throws {
        var project = try CutCommandTests.project(refrain: .identical)
        let templates = project.cut!.shots.compactMap { $0.reasons?.copiedFrom }
        let templateID = try #require(templates.first)
        let index = project.cut!.shots.firstIndex { $0.id == templateID }!
        project.cut!.shots[index].locked = true
        let template = project.cut!.shots[index]
        try BlockShotSource(shotID: templateID).apply(to: &project)
        let after = project.cut!.shots
        let new = after.first { $0.start == template.start }!
        #expect(!new.locked)
        #expect(new.clipID != template.clipID || new.sourceIn != template.sourceIn)
        #expect(CutValidator.validate(project, cut: project.cut!).isEmpty)
        #expect(!after.contains { $0.clipID == template.clipID && $0.sourceIn == template.sourceIn })
    }

    @MainActor
    @Test func undoRestoresRangesAndCut() throws {
        let project = try CutCommandTests.project()
        let owner = EditingOwner(project)
        let undo = UndoManager()
        try owner.perform(BlockShotSource(shotID: project.cut!.shots[3].id), undoManager: undo)
        #expect(owner.project != project)
        undo.undo()
        #expect(owner.project == project)
    }
}

@Suite struct ChapterCommandTests {
    static func project() throws -> Project {
        var project = StoryEngineTests.project()
        for index in project.clips.indices { project.clips[index].chapterID = nil }
        project.story.chapters = []
        try GenerateCut().apply(to: &project)
        return project
    }

    @Test func assignWithTakesCoversAllTakes() throws {
        var project = Project(
            clips: ["farm_pigs_wan.mp4", "farm_pigs_wan (2).mp4", "farm_pigs_wan (3).mp4", "farm_goats.mp4"].map {
                StoryFixtures.clip($0)
            })
        project.story.chapters = [Chapter(id: "k", name: "Tiere", color: 0)]
        try AssignChapter(clipIDs: ["farm_pigs_wan (2).mp4"], chapterID: "k", includeTakes: true).apply(to: &project)
        #expect(project.clips.map(\.chapterID) == ["k", "k", "k", nil])
    }

    @Test func removingChapterCleansClipsAndPlan() throws {
        var project = try Self.project()
        project.story.chapters = [Chapter(id: "a", name: "A", color: 0), Chapter(id: "b", name: "B", color: 1)]
        project.clips[0].chapterID = "b"
        project.story.plan = ["A": ["a": .main, "b": .mix], "B": ["b": .main]]
        try SetChapters(chapters: [Chapter(id: "a", name: "A", color: 0)]).apply(to: &project)
        #expect(project.clips[0].chapterID == nil)
        #expect(project.story.plan == ["A": ["a": .main]])
    }

    @Test func planChangeRecutsButKeepsLocked() throws {
        var project = try Self.project()
        project.cut!.shots[2].locked = true
        let locked = project.cut!.shots[2]
        try SetChapters(chapters: [Chapter(id: "a", name: "A", color: 0)]).apply(to: &project)
        try AssignChapter(clipIDs: Set(project.clips.prefix(3).map(\.id)), chapterID: "a", includeTakes: false)
            .apply(to: &project)
        try SetChapterRole(sectionID: "B", chapterID: "a", role: .main).apply(to: &project)
        let shots = project.cut!.shots
        #expect(shots.contains { $0.locked && $0.clipID == locked.clipID && $0.start == locked.start })
        let inB = StoryEngineTests.shots(in: "B", project, project.cut!).filter { !$0.locked }
        #expect(inB.allSatisfy { project.clip(withID: $0.clipID)?.chapterID == "a" })
    }

    @MainActor
    @Test func unchangedPlanCreatesNoUndoStep() throws {
        var project = try Self.project()
        project.story.chapters = [Chapter(id: "a", name: "A", color: 0)]
        project.story.plan = ["A": ["a": .main]]
        let owner = EditingOwner(project)
        let undo = UndoManager()
        try owner.perform(SetChapterRole(sectionID: "A", chapterID: "a", role: .main), undoManager: undo)
        #expect(!undo.canUndo)
    }

    @Test func montageAndChapterPromptToggle() throws {
        var project = try Self.project()
        try SetMontage(sectionID: "A", on: true).apply(to: &project)
        #expect(project.story.montage == ["A"])
        try SetAsksForChapters(false).apply(to: &project)
        #expect(!project.story.asksForChapters)
    }
}
