import Foundation
import Testing

@testable import SyllaBeatCore

/// Migrierte 0.2.0-Projekte müssen exakt dieselbe Frame-Tabelle ergeben wie `compile_timeline` in 0.2.0.
@Suite struct GoldenCompileTests {
    private func expectSameTable(projectURL: URL, compiledURL: URL) throws {
        let project = try ProjectFile.decode(Fixtures.data(projectURL)).project
        let expected = try Fixtures.json(compiledURL)
        let table = try CutCompiler.compile(project, cut: try #require(project.cut))
        let frames = expected["boundaries_frames"] as! [Int64]
        let shots = expected["shots"] as! [[String: Any]]
        #expect(table.fps == Rational(Int64(expected["fps_num"] as! Int), Int64(expected["fps_den"] as! Int)))
        #expect(table.durationFrames == expected["duration_frames"] as! Int64)
        #expect(table.entries.count == shots.count)
        for (entry, shot) in zip(table.entries, shots) {
            let name = "\(projectURL.deletingLastPathComponent().lastPathComponent) \(entry.shotID)"
            #expect(entry.clipID == shot["clip_id"] as! String, "\(name)")
            #expect(entry.startFrame == frames[shot["start_beat"] as! Int], "\(name)")
            #expect(entry.endFrame == frames[shot["end_beat"] as! Int], "\(name)")
            #expect(entry.durationFrames == shot["duration_frames"] as! Int64, "\(name)")
            #expect(entry.sourceInFrame == shot["source_in_frame"] as! Int64, "\(name)")
            #expect(entry.sourceOutFrame == shot["source_out_frame"] as! Int64, "\(name)")
            #expect(entry.sourceFPS.numerator == Int64(shot["source_fps_num"] as! Int), "\(name)")
            #expect(entry.sourceFPS.denominator == Int64(shot["source_fps_den"] as! Int), "\(name)")
        }
    }

    @Test(arguments: Fixtures.goldenNames)
    func matchesVersion020(name: String) throws {
        let folder = Fixtures.golden.appendingPathComponent(name)
        try expectSameTable(
            projectURL: folder.appendingPathComponent("project.v1.json"),
            compiledURL: folder.appendingPathComponent("compiled.json"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Fixtures.localLegacyProject.path)))
    func matchesRealPipelineProject() throws {
        try expectSameTable(
            projectURL: Fixtures.localLegacyProject,
            compiledURL: Fixtures.localLegacyProject.deletingPathExtension().appendingPathExtension("compiled.json"))
    }

    @Test func rejectsGapsAndShortSources() throws {
        var project = try ProjectFile.decode(
            Fixtures.data(Fixtures.golden.appendingPathComponent("g4-manueller-plan/project.v1.json"))
        ).project
        var cut = try #require(project.cut)
        cut.shots[1].start = cut.shots[2].start
        #expect(throws: CompileError.gap(shot: 2)) { try CutCompiler.compile(project, cut: cut) }
        cut = try #require(project.cut)
        cut.shots[0].sourceIn = Rational(29)
        #expect(throws: CompileError.sourceTooShort(shot: 1, clipName: "eins.mov")) {
            try CutCompiler.compile(project, cut: cut)
        }
        project.analysis = nil
        #expect(throws: CompileError.noAnalysis) { try CutCompiler.compile(project, cut: cut) }
    }
}
