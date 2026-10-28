import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct MigrationTests {
    private func golden(_ name: String) throws -> (project: Project, raw: [String: Any]) {
        let url = Fixtures.golden.appendingPathComponent("\(name)/project.v1.json")
        let loaded = try ProjectFile.decode(Fixtures.data(url))
        #expect(loaded.migratedFrom == 1)
        return (loaded.project, try Fixtures.json(url))
    }

    @Test func keepsCatalogAndDescriptions() throws {
        let (project, _) = try golden("g1-basis-25p")
        #expect(project.version == 2)
        #expect(project.name == "Basis 25p")
        #expect(project.timeline.fps == Rational(25))
        #expect(project.song?.fileName == "Sommer Lied (Master).wav")
        #expect(project.clips.map(\.name) == ["strand_01.mov", "stadt_nacht.mp4", "wald.mov"])
        let beach = try #require(project.clip(withID: "clip-a"))
        #expect(beach.description == "Wellen am Strand")
        #expect(beach.tags == ["Strand", "Meer"])
        #expect(beach.scenes.map(\.id) == ["clip-a-s1", "clip-a-s2"])
        #expect(beach.scenes.map(\.end) == [4.0, 10.0])
        #expect(project.clip(withID: "clip-c")?.meta.fps == Rational(30000, 1001))
        #expect(project.clip(withID: "clip-c")?.meta.frameCount == 180)
        #expect(project.legacy?.videoFolder == "/Volumes/Material/Clips")
    }

    @Test func keepsSongStructure() throws {
        let (project, raw) = try golden("g1-basis-25p")
        let analysis = try #require(project.analysis)
        let rawBeats = (raw["audio"] as! [String: Any])["beats"] as! [Double]
        #expect(analysis.beats.map(\.time) == rawBeats)
        #expect(analysis.boundaries.first == 0 && analysis.boundaries.last == 12.4)
        #expect(analysis.sections.map(\.kind) == [.verse, .chorus, .verse, .chorus, .outro])
        #expect(analysis.sections[3].repeatOf == "s2")
    }

    @Test func mapsCutStyleToPresets() throws {
        #expect(try golden("g1-basis-25p").project.style.variation == .low)
        let wild = try golden("g3-hochformat-5994").project.style
        #expect(wild.variation == .high && wild.seed == 7 && wild.preset == .balanced)
        let style = try golden("g2-ntsc-umlaute").project.style
        #expect(style.verseBeats == 4 && style.chorusBeats == 2 && style.seed == 11)
    }

    @Test func planBecomesAnchoredCut() throws {
        let (project, raw) = try golden("g4-manueller-plan")
        let cut = try #require(project.cut)
        let shots = (raw["plan"] as! [String: Any])["shots"] as! [[String: Any]]
        #expect(cut.origin == .legacyPlan)
        #expect(cut.shots.count == shots.count)
        #expect(cut.shots.first?.start.anchor == .songStart)
        #expect(cut.shots.last?.end.anchor == .songEnd)
        // Beat-ID 2 in 0.2.0 ist der zweite erkannte Beat, also Index 1 in `beats`.
        #expect(cut.shots[1].start.anchor == .beat(1))
        #expect(cut.shots[1].start.time == 2.0)
        #expect(cut.shots[0].sourceIn == Rational(5, 4))
        #expect(cut.shots[0].sceneID == "m1-s1")
    }

    @Test func roundTripsAsVersion2() throws {
        for name in Fixtures.goldenNames {
            let (project, _) = try golden(name)
            let data = try ProjectFile.encode(project)
            let reloaded = try ProjectFile.decode(data)
            #expect(reloaded.migratedFrom == nil)
            #expect(reloaded.project == project, "\(name)")
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("\"version\" : 2"))
            #expect(!text.contains("fps_num"))
        }
    }

    @Test func emptyAutosaveFromVersion020() throws {
        let autosave = """
            {"version": 1, "name": "Neues Musikvideo", "video_dir": "", "audio_path": "", "lyrics": "",
             "timeline": {"fps_num": 25, "fps_den": 1, "width": 1920, "height": 1080}, "clips": [], "audio": {},
             "plan": null, "cut_style": {"variation": "abwechslungsreich", "verse_beats": 4, "chorus_beats": 2,
             "chorus_faster": true, "seed": 1}, "plan_draft": ""}
            """
        let project = try ProjectFile.decode(Data(autosave.utf8)).project
        #expect(project.clips.isEmpty && project.analysis == nil && project.cut == nil && project.song == nil)
        #expect(project.style == CutStyle())
        #expect(project.legacy?.planDraft == nil)
    }

    @Test func brokenPlanIsDroppedWithNote() throws {
        let text = """
            {"version": 1, "name": "X", "clips": [], "audio": {"duration": 4, "beats": [1, 2, 3]},
             "plan": {"version": 1, "shots": [{"clip_id": "fehlt", "start_beat": 0, "end_beat": 4, "source_in": 0}]}}
            """
        let project = try ProjectFile.decode(Data(text.utf8)).project
        #expect(project.cut == nil)
        #expect(project.legacy?.notes.first?.contains("„fehlt“") == true)
    }

    @Test func rejectsUnknownAndBrokenFiles() {
        #expect(throws: ProjectFileError.unsupportedVersion(3)) {
            try ProjectFile.decode(Data(#"{"version": 3}"#.utf8))
        }
        #expect(throws: ProjectFileError.notJSON) { try ProjectFile.decode(Data("kein json".utf8)) }
        #expect(throws: ProjectFileError.unsupportedVersion(nil)) { try ProjectFile.decode(Data("{}".utf8)) }
        #expect(throws: ProjectFileError.self) {
            try ProjectFile.decode(Data(#"{"version": 2, "name": "x", "timeline": {"fps": "1/0"}}"#.utf8))
        }
    }

    /// Spätere Meilensteine fügen Felder hinzu; Dateien aus M1 müssen weiter öffnen.
    @Test func toleratesMissingAndUnknownKeys() throws {
        let text = #"{"version": 2, "name": "Minimal", "zukunft": {"x": 1}}"#
        let project = try ProjectFile.decode(Data(text.utf8)).project
        #expect(project.name == "Minimal" && project.timeline == TimelineSettings() && project.clips.isEmpty)
    }

    @Test(arguments: [
        ("Refrain (Vorschlag)", SongSection.Kind.chorus), ("Pre-Chorus", .preChorus), ("Strophe 2", .verse),
        ("Bridge", .bridge), ("Intro", .intro), ("Outro", .outro), ("Instrumental", .instrumental),
        ("Abschnitt 3", .other),
    ])
    func sectionKinds(label: String, kind: SongSection.Kind) {
        #expect(SongSection.Kind(label: label) == kind)
    }

    @Test func anchorsAsText() {
        let anchors: [Anchor] = [.songStart, .songEnd, .beat(12), .word("w7"), .syllable("s1"), .section("x"), .free]
        for anchor in anchors { #expect(Anchor(anchor.description) == anchor) }
        #expect(Anchor("beat:-1") == nil)
        #expect(Anchor("word:") == nil)
        #expect(Anchor("unbekannt") == nil)
    }
}
