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
