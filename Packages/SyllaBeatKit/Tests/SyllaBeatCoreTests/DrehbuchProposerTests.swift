import Testing

@testable import SyllaBeatCore

@Suite struct DrehbuchProposerTests {
    static let chapters = (0..<3).map { Chapter(id: "k\($0)", name: "K\($0)", color: $0) }

    static func sections(_ count: Int) -> [SongSection] {
        (0..<count).map {
            SongSection(id: "s\($0)", kind: .verse, label: "S\($0)", start: Double($0) * 10, end: Double($0 + 1) * 10)
        }
    }

    static func mains(_ plan: [String: [String: ChapterRole]], _ count: Int) -> [String?] {
        (0..<count).map { plan["s\($0)"]?.first { $0.value == .main }?.key }
    }

    @Test func monotonePlanFollowsEvidence() {
        let evidence: [String: [Double]] = ["s0": [1, 0, 0], "s1": [0, 0, 2], "s2": [0, 1.5, 0], "s3": [0, 0, 1]]
        let plan = DrehbuchProposer.plan(
            sections: Self.sections(4), chapters: Self.chapters, evidence: evidence, montage: [])
        #expect(Self.mains(plan, 4) == ["k0", "k2", "k2", "k2"])
    }

    @Test func edgePriorsAnchorStartAndEnd() {
        let plan = DrehbuchProposer.plan(
            sections: Self.sections(3), chapters: Self.chapters, evidence: [:], montage: [])
        #expect(Self.mains(plan, 3) == ["k0", "k0", "k2"])
    }

    @Test func montageTakesBestChapter() {
        let evidence: [String: [Double]] = ["s1": [0, 3, 0], "s2": [0, 0, 1]]
        let plan = DrehbuchProposer.plan(
            sections: Self.sections(3), chapters: Self.chapters, evidence: evidence, montage: ["s1"])
        #expect(Self.mains(plan, 3) == ["k0", "k1", "k2"])
        #expect(plan["s1"]?.count == 1)
    }
}
