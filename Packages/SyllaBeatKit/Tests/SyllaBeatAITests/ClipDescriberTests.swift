import Foundation
import Testing

@testable import SyllaBeatAI
@testable import SyllaBeatCore

@Suite struct ClipDescriberTests {
    static func clip() -> Clip {
        Clip(
            id: "c", media: MediaRef(path: "/c.mp4"),
            meta: ClipMetadata(duration: 8, fps: Rational(25), width: 1920, height: 1080),
            scenes: [ClipScene(id: "c-s0", start: 0, end: 4), ClipScene(id: "c-s1", start: 4, end: 8)])
    }

    static func answer(_ timeOfDay: String) -> Data {
        Data(
            """
            {"beschreibung": "Familie vor dem Haus", "stimmung": "ruhig", "schlagwoerter": ["Haus", "Familie", "Garten"],
             "szenen": [{"id": "s1", "inhalt": "Haus"}, {"id": "s2", "inhalt": "Garten"}], "dateiname": "haus",
             "tageszeit": "\(timeOfDay)"}
            """.utf8)
    }

    @Test func describerStoresTimeOfDay() throws {
        let clip = Self.clip()
        let updated = try ClipDescriber.apply(Self.answer("Abend"), to: clip, scenes: clip.scenes, model: "test")
        #expect(updated.traits["tageszeit"] == TraitValue(value: "Abend", source: .description))
        #expect(ClipDescriber.Stored(updated).timeOfDay == "Abend")
        #expect(ClipDescriber.Stored(updated).apply(to: clip).traits["tageszeit"]?.value == "Abend")
    }

    @Test func userValueWinsAndUnclearSetsNothing() throws {
        var clip = Self.clip()
        clip.traits["tageszeit"] = TraitValue(value: "Tag", source: .user)
        let kept = try ClipDescriber.apply(Self.answer("Nacht"), to: clip, scenes: clip.scenes, model: "test")
        #expect(kept.traits["tageszeit"] == TraitValue(value: "Tag", source: .user))
        let unclear = try ClipDescriber.apply(
            Self.answer("unklar"), to: Self.clip(), scenes: clip.scenes, model: "test")
        #expect(unclear.traits["tageszeit"] == nil)
    }

    @Test func schemaAsksForTimeOfDay() {
        let schema = ClipDescriber.schema(sceneCount: 2)
        let object: [String: Any] = [
            "beschreibung": "x", "stimmung": "y", "schlagwoerter": ["a", "b", "c"],
            "szenen": [["id": "s1", "inhalt": "a"], ["id": "s2", "inhalt": "b"]], "dateiname": "x",
        ]
        #expect(!schema.violations(of: object).isEmpty, "tageszeit muss Pflicht sein")
    }
}
