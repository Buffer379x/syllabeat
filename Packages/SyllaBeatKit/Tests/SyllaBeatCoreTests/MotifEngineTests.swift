import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct MotifEngineTests {
    /// Song 40 s ohne Kapitel; Clips mit den angegebenen Namen (15 s, eine Szene).
    static func project(_ names: [String]) -> Project {
        var project = StoryEngineTests.project(clipsPerChapter: [names.count])
        project.story.chapters = []
        for (index, name) in names.enumerated() {
            var clip = StoryFixtures.clip(name, fps: Rational(25))
            clip.chapterID = nil
            project.clips[index] = clip
        }
        return project
    }

    static func row(_ favourites: [String: Float], scenes: [String]) -> [String: Float] {
        var row = Dictionary(uniqueKeysWithValues: scenes.map { ($0, Float(0.05)) })
        for (key, value) in favourites { row[key] = value }
        return row
    }

    @Test func motifIsHeldAcrossSlotsOfOneLine() throws {
        let names = ["farm_family_with_goats_wan.mp4"] + (0..<8).map { "farm_other_\($0)_wan.mp4" }
        var project = Self.project(names)
        project.analysis!.lines = [LyricLine(id: "l1", text: "Die Ziegen kauen", start: 0, end: 6)]
        let scenes = project.clips.map { $0.scenes[0].id }
        let scores = TextScores(["l1": Self.row(["farm_family_with_goats_wan.mp4-s0": 0.12], scenes: scenes)])
        for seed in UInt64(1)...5 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style, textScores: scores))
            let inLine = cut.shots.filter { $0.start.time < 5.5 && $0.end.time > 0.5 }
            #expect(inLine.count >= 2)
            #expect(inLine.allSatisfy { $0.clipID == names[0] }, "Seed \(seed): \(inLine.map(\.clipID))")
            for (a, b) in zip(inLine, inLine.dropFirst()) {
                #expect(abs(b.sourceIn.doubleValue - (a.sourceIn.doubleValue + a.duration)) < 0.002)
            }
        }
    }

    @Test func takesOfSameMotifAreNotAdjacent() throws {
        let names = [
            "farm_pigs_wan.mp4", "farm_pigs_wan (2).mp4", "farm_pigs_wan (3).mp4", "farm_goats_wan.mp4",
            "farm_cows_wan.mp4", "farm_sheep_wan.mp4",
        ]
        var project = Self.project(names)
        let motifs = project.motifs()
        for seed in UInt64(1)...10 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style))
            for (a, b) in zip(cut.shots, cut.shots.dropFirst()) where a.clipID != b.clipID {
                #expect(motifs[a.clipID]?.key != motifs[b.clipID]?.key, "Seed \(seed): \(a.clipID) → \(b.clipID)")
            }
        }
    }

    @Test func cameraFilesAreNotOneMotif() throws {
        var project = Self.project((1...4).map { "IMG_000\($0).MOV" })
        project.style.seed = 2
        let cut = try #require(CutEngine.generate(project, style: project.style))
        #expect(!cut.shots.contains { $0.reasons?.components["adjacent"] ?? 0 < 0 })
    }

    @Test func watermarkedTakeIsAvoidedWhenCleanTakeExists() throws {
        let names =
            [
                "general_family_with_pigs_veo_watermark.mp4", "general_family_with_pigs_wan_no_watermark.mp4",
            ] + (0..<6).map { "general_other_\($0)_wan.mp4" }
        var project = Self.project(names)
        project.analysis!.lines = [LyricLine(id: "l1", text: "Schweine", start: 0, end: 40)]
        let scenes = project.clips.map { $0.scenes[0].id }
        let scores = TextScores([
            "l1": Self.row([names[0] + "-s0": 0.12, names[1] + "-s0": 0.12], scenes: scenes)
        ])
        var clean = 0
        var marked = 0
        for seed in UInt64(1)...20 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style, textScores: scores))
            clean += cut.shots.filter { $0.clipID == names[1] }.count
            marked += cut.shots.filter { $0.clipID == names[0] }.count
        }
        // Bei nur zwei Takes holt der Wiederverwendungs-Abschlag den sauberen Take ein; er soll klar überwiegen.
        #expect(Double(clean) >= 1.2 * Double(marked), "sauber \(clean), mit Wasserzeichen \(marked)")
        let only = Self.project(["general_family_with_pigs_veo_watermark.mp4", "general_other_wan.mp4"])
        let cut = try #require(CutEngine.generate(only, style: only.style))
        #expect(!cut.shots.contains { ($0.reasons?.components["watermark"] ?? 0) != 0 })
    }

    /// Drei Motive ohne Text: Die Engine kehrt nicht nach einem fremden Bild zum Motiv davor zurück (A · B · A),
    /// solange ein drittes Motiv zur Wahl steht.
    @Test func noSandwichWhenThirdMotifAvailable() throws {
        let names = ["farm_goats_wan.mp4", "farm_cows_wan.mp4", "farm_sheep_wan.mp4"]
        var project = Self.project(names)
        var sandwiches = 0
        for seed in UInt64(1)...10 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style))
            for index in cut.shots.indices.dropFirst().dropLast()
            where cut.shots[index - 1].clipID == cut.shots[index + 1].clipID
                && cut.shots[index].clipID != cut.shots[index - 1].clipID
            {
                sandwiches += 1
            }
        }
        #expect(sandwiches <= 2, "\(sandwiches) Sandwiches in 10 Schnitten")
    }

    static func refrainProject(_ names: [String]) -> Project {
        var project = Self.project(names)
        project.analysis!.sections = [
            SongSection(id: "V", kind: .verse, label: "Strophe", start: 0, end: 8),
            SongSection(id: "A", kind: .chorus, label: "Refrain", start: 8, end: 24),
            SongSection(id: "B", kind: .chorus, label: "Refrain", start: 24, end: 40, repeatOf: "A"),
        ]
        project.style.refrainMode = .sameMotifs
        return project
    }

    @Test func sameMotifsUsesOtherTakes() throws {
        let names = [
            "farm_pigs_wan.mp4", "farm_pigs_wan (2).mp4", "farm_pigs_wan (3).mp4", "farm_goats_wan.mp4",
            "farm_cows_wan.mp4", "farm_sheep_wan.mp4",
        ]
        var project = Self.refrainProject(names)
        let motifs = project.motifs()
        var checked = 0
        for seed in UInt64(1)...10 {
            project.style.seed = seed
            let cut = try #require(CutEngine.generate(project, style: project.style))
            for copy in cut.shots {
                guard let source = copy.reasons?.copiedFrom, let template = cut.shots.first(where: { $0.id == source }),
                    motifs[template.clipID]?.key.contains("pigs") == true
                else { continue }
                #expect(copy.clipID != template.clipID, "Seed \(seed)")
                #expect(motifs[copy.clipID]?.key == motifs[template.clipID]?.key)
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    @Test func sameMotifsFallsBackToOtherRange() throws {
        var project = Self.refrainProject(["farm_goats_wan.mp4", "farm_cows_wan.mp4", "farm_sheep_wan.mp4"])
        project.style.seed = 3
        let cut = try #require(CutEngine.generate(project, style: project.style))
        let copies = cut.shots.filter { $0.reasons?.copiedFrom != nil }
        #expect(!copies.isEmpty)
        for copy in copies {
            let template = cut.shots.first { $0.id == copy.reasons?.copiedFrom }!
            #expect(copy.clipID == template.clipID)
        }
        #expect(CutValidator.validate(project, cut: cut).isEmpty)
    }

    @Test func refrainModesDecodeUnchanged() throws {
        for mode in ["identical", "sameClips", "free", "sameMotifs"] {
            let style = try JSONDecoder().decode(CutStyle.self, from: Data(#"{"refrainMode": "\#(mode)"}"#.utf8))
            #expect(style.refrainMode.rawValue == mode)
        }
        #expect(CutStyle.RefrainMode.sameMotifs.title == "Gleiche Motive, andere Takes")
    }
}
