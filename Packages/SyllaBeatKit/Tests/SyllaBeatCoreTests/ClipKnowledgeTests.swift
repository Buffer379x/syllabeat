import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct ClipKnowledgeTests {
    static func cache() throws -> MediaCache {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Wissen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MediaCache(root: root)
    }

    static func clip() -> Clip {
        var clip = StoryFixtures.clip("a.mp4")
        clip.media.fingerprint = "123-abc"
        return clip
    }

    @Test func knowledgeRoundTrips() throws {
        let cache = try Self.cache()
        var clip = Self.clip()
        clip.blocked = [SourceRange(start: 1, end: 2)]
        clip.rating = 4
        clip.excluded = true
        clip.traits["tageszeit"] = TraitValue(value: "Abend", source: .user)
        let knowledge = ClipKnowledge(clip)
        try knowledge.save(fingerprint: "123-abc", cache: cache)
        #expect(ClipKnowledge.load(fingerprint: "123-abc", cache: cache) == knowledge)
        #expect(!knowledge.isEmpty)
        #expect(ClipKnowledge(Self.clip()).isEmpty)
    }

    @Test func adoptingFillsOnlyEmptyFields() {
        var clip = Self.clip()
        clip.rating = 4
        var known = Self.clip()
        known.rating = 2
        known.blocked = [SourceRange(start: 3, end: 4)]
        let (adopted, count) = clip.adopting(ClipKnowledge(known))
        #expect(adopted.rating == 4)
        #expect(adopted.blocked == [SourceRange(start: 3, end: 4)])
        #expect(count == 1)
    }

    @Test func descriptionTraitsAreNotStored() {
        var clip = Self.clip()
        clip.traits["tageszeit"] = TraitValue(value: "Tag", source: .description)
        #expect(ClipKnowledge(clip).traits.isEmpty)
    }

    @Test func changesFindsEditedClips() {
        var a = Self.clip()
        var b = StoryFixtures.clip("b.mp4")
        b.media.fingerprint = "456-def"
        let old = Project(clips: [a, b])
        a.blocked = [SourceRange(start: 0, end: 1)]
        b.description = "Neu beschrieben"
        let new = Project(clips: [a, b])
        #expect(ClipKnowledge.changes(from: old, to: new).map(\.id) == ["a.mp4"])
    }
}
