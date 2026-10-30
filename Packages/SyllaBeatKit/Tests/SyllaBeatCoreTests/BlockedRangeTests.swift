import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct BlockedRangeTests {
    /// Ein Clip (15 s, 25 fps), Song 8 s, Schnitt aus zwei Shots; der erste zeigt Quelle 1–3 s.
    static func project(blocked: [SourceRange]) -> (Project, Cut) {
        var clip = StoryFixtures.clip("a.mp4", fps: Rational(25))
        clip.blocked = blocked
        let project = Project(clips: [clip], analysis: SongAnalysis(duration: 8))
        var first = StoryFixtures.shot(1, 2, 4, "a.mp4")
        first.start = CutPoint(time: 0, anchor: .songStart)
        first.end = CutPoint(time: 2, anchor: .free)
        first.sourceIn = Rational(1)
        var second = StoryFixtures.shot(2, 2, 8, "a.mp4")
        second.sourceIn = Rational(8)
        second.end = CutPoint(time: 8, anchor: .songEnd)
        return (project, Cut(id: "c", name: "c", seed: 1, origin: .manual, shots: [first, second]))
    }

    @Test func compilerRejectsShotInBlockedRange() {
        let (project, cut) = Self.project(blocked: [SourceRange(start: 2.5, end: 2.8)])
        #expect(throws: CompileError.blocked(shot: 1, clipName: "a.mp4")) {
            try CutCompiler.compile(project, cut: cut)
        }
        #expect(CutCompiler.brokenShots(project, cut: cut) == ["shot-1"])
        #expect(CutValidator.validate(project, cut: cut).contains { $0.hasPrefix("I8") })
    }

    @Test func touchingRangeIsAllowed() throws {
        let (project, cut) = Self.project(blocked: [SourceRange(start: 3.0, end: 3.5)])
        _ = try CutCompiler.compile(project, cut: cut)
        #expect(!CutValidator.validate(project, cut: cut).contains { $0.hasPrefix("I8") })
    }

    @Test func blockedRangesSplitUnits() {
        let intervals = CutEngine.usableIntervals(
            start: 0, end: 15, blocked: [SourceRange(start: 4, end: 5), SourceRange(start: 14, end: 15)],
            margin: 0.04, minimum: 0.6)
        #expect(intervals.count == 2)
        #expect(abs(intervals[0].lowerBound - 0) < 1e-9 && abs(intervals[0].upperBound - 3.96) < 1e-9)
        #expect(abs(intervals[1].lowerBound - 5.04) < 1e-9 && abs(intervals[1].upperBound - 13.96) < 1e-9)
    }

    @Test func storyProjectsCarryBlockedRanges() {
        let blocked = (0..<50).flatMap { SyntheticProject.make(seed: UInt64($0), story: true).clips }
            .filter { !$0.blocked.isEmpty }
        #expect(!blocked.isEmpty)
        #expect(SyntheticProject.make(seed: 3) == SyntheticProject.make(seed: 3, story: false))
    }
}
