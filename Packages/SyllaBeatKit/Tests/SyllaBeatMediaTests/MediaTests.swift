import AVFoundation
import Foundation
import Testing

@testable import SyllaBeatCore
@testable import SyllaBeatMedia

@Suite struct MetadataTests {
    @Test(arguments: [(Int32(24000), Int32(1001)), (25, 1), (50, 1), (60000, 1001)])
    func ratesAreExact(num: Int32, den: Int32) async throws {
        let folder = try TestFolder.make()
        let url = folder.appendingPathComponent("rate.mov")
        // Zeitbasis 600 (wie beim iPhone): 59,94 und 60 fps sind erst über ~120 Frames unterscheidbar.
        try SyntheticClip(rate: (num, den), frames: 150).write(to: url)
        let meta = try await MediaProbe.read(url)
        #expect(meta.fps == Rational(Int64(num), Int64(den)))
        #expect(meta.isVFR == false)
        #expect(meta.width == 192 && meta.height == 108)
        #expect(meta.frameCount == 150)
        #expect(meta.hasAudio == false)
        #expect(meta.codec == "avc1")
    }

    @Test func rotationAndTimecode() async throws {
        let folder = try TestFolder.make()
        let url = folder.appendingPathComponent("hoch.mov")
        try SyntheticClip(rate: (25, 1), frames: 50, rotation: 90, startTimecodeFrames: 10 * 3600 * 25).write(to: url)
        let meta = try await MediaProbe.read(url)
        #expect(meta.rotation == 90)
        #expect(meta.displaySize.width == 108 && meta.displaySize.height == 192)
        #expect(meta.startTimecode == "10:00:00:00")
    }

    @Test func variableRateIsFlagged() async throws {
        let folder = try TestFolder.make()
        let url = folder.appendingPathComponent("vfr.mov")
        try SyntheticClip(rate: (30, 1), frames: 60, variableRate: true).write(to: url)
        let meta = try await MediaProbe.read(url)
        #expect(meta.isVFR == true)
        #expect(meta.warnings.contains { $0.contains("Variable Bildrate") })
    }

    /// F12 aus 0.2.0: 23,976p wurde als 23040/961 erkannt.
    @Test func snapsNearStandardRates() {
        #expect(MediaProbe.rationalRate(nominal: 23.975, minFrameDuration: .invalid) == Rational(24000, 1001))
        #expect(MediaProbe.rationalRate(nominal: 29.97, minFrameDuration: .invalid) == Rational(30000, 1001))
        #expect(
            MediaProbe.rationalRate(nominal: 12.5, minFrameDuration: CMTime(value: 2, timescale: 25)) == Rational(25, 2)
        )
    }

    @Test func timecodes() {
        #expect(Timecode.string(frames: 900_000, quanta: 25) == "10:00:00:00")
        #expect(Timecode.string(frames: 1799, quanta: 30, dropFrame: true) == "00:00:59;29")
        #expect(Timecode.string(frames: 1800, quanta: 30, dropFrame: true) == "00:01:00;02")
        #expect(Timecode.string(frames: 17982, quanta: 30, dropFrame: true) == "00:10:00;00")
    }

    @Test func mkvNeedsWorkingCopy() async throws {
        #expect(FileScanner.isVideo(TestFolder.mkv))
        await #expect(throws: MediaError.unsupported("zwei-farben.mkv")) { try await MediaProbe.read(TestFolder.mkv) }
        let clip = try await ClipAnalyzer(cache: MediaCache(root: try TestFolder.make())).probe(TestFolder.mkv)
        #expect(clip.meta.needsConversion)
        #expect(clip.name == "zwei-farben.mkv")
        #expect(clip.hasWarningsForTest)
    }
}

extension Clip {
    var hasWarningsForTest: Bool { !meta.warnings.isEmpty }
}

@Suite struct SceneTests {
    /// Schnitte werden framegenau gefunden, auch bei NTSC-Raten und mitten zwischen zwei Stichproben.
    @Test(arguments: [
        (Int32(25), Int32(1), [37, 80]), (24000, 1001, [50, 101]), (50, 1, [77]), (60000, 1001, [61, 143]),
    ])
    func cutsAreFrameAccurate(num: Int32, den: Int32, cuts: [Int]) async throws {
        let folder = try TestFolder.make()
        let url = folder.appendingPathComponent("schnitte.mov")
        let recipe = SyntheticClip(rate: (num, den), frames: 180, cutFrames: cuts)
        try recipe.write(to: url)
        let scan = try await SceneDetector.scan(url)
        let frame = Double(den) / Double(num)
        #expect(scan.cuts.count == cuts.count)
        for (found, expected) in zip(scan.cuts, recipe.cutTimes()) {
            #expect(abs(found - expected) < frame / 2, "gefunden \(found), erwartet \(expected)")
        }
        #expect(scan.filmstrip.count == 10)
        #expect(scan.samples.contains { $0.motion > 0 })
    }

    @Test func splitsLongAndMergesShortScenes() {
        let scenes = SceneDetector.scenes(cuts: [0.5, 2.0, 2.3], duration: 14, clipID: "c")
        // 0–0,5 und 2,0–2,3 sind zu kurz und gehen im Nachbarn auf; 2,0–14 wird in drei Teile ≤ 5 s zerlegt.
        #expect(scenes.map(\.start) == [0, 2, 6, 10])
        #expect(scenes.map(\.id) == ["c-s1", "c-s2", "c-s3", "c-s4"])
        #expect(scenes.last?.end == 14)
        #expect(SceneDetector.scenes(cuts: [], duration: 3, clipID: "x").count == 1)
        #expect(SceneDetector.scenes(cuts: [], duration: 0.5, clipID: "x").count == 1)
    }

    @Test func fullAnalysisWritesCacheAndFeatures() async throws {
        let folder = try TestFolder.make()
        let url = folder.appendingPathComponent("analyse.mov")
        try SyntheticClip(rate: (25, 1), frames: 150, cutFrames: [60]).write(to: url)
        let cache = MediaCache(root: folder.appendingPathComponent("cache"))
        let analyzer = ClipAnalyzer(cache: cache)
        var clip = try await analyzer.probe(url)
        clip.description = "von Hand"
        let analyzed = try await analyzer.analyze(clip)
        #expect(analyzed.scenes.count == 2)
        #expect(analyzed.scenes[1].start == 2.4)
        #expect(analyzed.description == "von Hand")
        #expect(analyzed.scenes.allSatisfy { $0.features != nil && $0.keyframeTime != nil })
        let fingerprint = try #require(analyzed.media.fingerprint)
        for scene in analyzed.scenes {
            #expect(
                FileManager.default.fileExists(
                    atPath: cache.thumbnail(fingerprint: fingerprint, sceneStart: scene.start).path))
        }
        #expect(FileManager.default.fileExists(atPath: cache.filmstrip(fingerprint: fingerprint).path))
        #expect(analyzed.id == ClipAnalyzer.clipID(fingerprint: fingerprint))
    }
}

@Suite struct FileTests {
    /// Gleiche Werte wie `_fingerprint` in 0.2.0 (mit Python berechnet).
    @Test(arguments: [
        (300_000, "3967971546e03377dc1d0a57273c8b9a5a31c555ab3cd8ece38b86922af6756c"),
        (200_000, "e24bc62381f1224fbbb74688663f8f9743b9680b193edd666835e97b06e730eb"),
    ])
    func fingerprintMatchesVersion020(size: Int, digest: String) throws {
        let url = try TestFolder.make().appendingPathComponent("muster.bin")
        try Data((0..<size).map { UInt8($0 % 251) }).write(to: url)
        #expect(try Fingerprint.compute(url) == "\(size):\(digest)")
        #expect(
            try Fingerprint.compute(TestFolder.mkv)
                == "2345:7f38d46a7c7e3fac7365879f583a1fd5a2276dad4a6fc3de70214a011eeddb6c")
    }

    @Test func scannerFindsVideosOnly() throws {
        let folder = try TestFolder.make()
        let sub = folder.appendingPathComponent("Unterordner")
        let copies = folder.appendingPathComponent(FFmpeg.workingCopyFolderName)
        for dir in [sub, copies] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for file in [
            "b.mov", "a.MP4", "notiz.txt", ".versteckt.mov", "Unterordner/c.mkv",
            "\(FFmpeg.workingCopyFolderName)/a.mov",
        ] {
            try Data().write(to: folder.appendingPathComponent(file))
        }
        #expect(FileScanner.videos(in: [folder]).map(\.lastPathComponent) == ["a.MP4", "b.mov", "c.mkv"])
        #expect(
            FileScanner.videos(in: [folder], includeSubfolders: false).map(\.lastPathComponent) == ["a.MP4", "b.mov"])
    }

    @Test func relinksMovedFilesByFingerprint() throws {
        let folder = try TestFolder.make()
        let original = folder.appendingPathComponent("alt/clip.mov")
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<5000).map { UInt8($0 % 7) }).write(to: original)
        let media = MediaRef(path: original.path, fingerprint: try Fingerprint.compute(original))
        let clip = Clip(id: "c", media: media, meta: ClipMetadata(duration: 1, fps: Rational(25), width: 1, height: 1))
        let moved = folder.appendingPathComponent("neu/umbenannt.mov")
        try FileManager.default.createDirectory(
            at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        let found = MediaResolver.relink([clip], in: folder)
        #expect(found["c"]?.path == moved.path)
    }

    @Test func bookmarksFollowRenames() throws {
        let folder = try TestFolder.make()
        let url = folder.appendingPathComponent("clip.mov")
        try Data([1, 2, 3]).write(to: url)
        let media = try ClipAnalyzer.mediaRef(for: url)
        let renamed = folder.appendingPathComponent("neu.mov")
        try FileManager.default.moveItem(at: url, to: renamed)
        let resolved = try #require(MediaResolver.resolveBookmark(media))
        #expect(URL(fileURLWithPath: resolved.path).resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
    }

    @Test func cacheTrimsOldestFirst() throws {
        let cache = MediaCache(root: try TestFolder.make())
        for (index, name) in ["alt", "mittel", "neu"].enumerated() {
            let folder = try cache.prepare(fingerprint: name)
            try Data(count: 40_000).write(to: folder.appendingPathComponent("daten"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(index * 100 - 1000))], ofItemAtPath: folder.path)
        }
        #expect(try cache.trim(toBytes: 100_000) == 1)
        #expect(!FileManager.default.fileExists(atPath: cache.folder(for: "alt").path))
        #expect(FileManager.default.fileExists(atPath: cache.folder(for: "neu").path))
        try cache.clear()
        #expect(cache.size() == 0)
    }
}

/// Wandlung mit ffmpeg; läuft nur, wenn ffmpeg verfügbar ist (`SYLLABEAT_FFMPEG` oder installierte Komponente).
@Suite(.enabled(if: FFmpeg.locate() != nil)) struct ConversionTests {
    @Test func mkvBecomesUsableWorkingCopy() async throws {
        let folder = try TestFolder.make()
        let source = folder.appendingPathComponent("zwei-farben.mkv")
        try FileManager.default.copyItem(at: TestFolder.mkv, to: source)
        let output = FFmpeg.workingCopyURL(for: source)
        try await FFmpeg.locate()!.convert(source, to: output, preset: .proResLT)
        let meta = try await MediaProbe.read(output)
        #expect(meta.fps == Rational(25))
        #expect(abs(meta.duration - 2) < 0.05)
        #expect(meta.codec == "apcs")
        let scan = try await SceneDetector.scan(output)
        #expect(scan.cuts.count == 1 && abs(scan.cuts[0] - 1) < 0.02)
    }

    @Test func variableRateBecomesConstant() async throws {
        let folder = try TestFolder.make()
        let source = folder.appendingPathComponent("vfr.mov")
        try SyntheticClip(rate: (30, 1), frames: 60, variableRate: true).write(to: source)
        let output = folder.appendingPathComponent("cfr.mov")
        try await FFmpeg.locate()!.convert(source, to: output, preset: .hevc, constantRate: Rational(30))
        let meta = try await MediaProbe.read(output)
        #expect(meta.isVFR == false)
        #expect(meta.fps == Rational(30))
    }
}
