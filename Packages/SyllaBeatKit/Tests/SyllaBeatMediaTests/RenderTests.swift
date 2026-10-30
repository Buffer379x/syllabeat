import AVFoundation
import Foundation
import Testing

@testable import SyllaBeatCore
@testable import SyllaBeatMedia

/// Fertiges Video aus derselben Frame-Tabelle wie Vorschau und Exporte. Auf CI-VMs ohne Hardware-Encoder übersprungen.
@Suite(.timeLimit(.minutes(3)), .enabled(if: VideoRenderer.encoderAvailable(.h264))) @MainActor
struct RenderTests {
    static func table() async throws -> (FrameTable, [String: String], Project) {
        let project = try await PreviewTests.project(fit: .fill)
        let table = try CutCompiler.compile(project, cut: project.cut!)
        let paths = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0.media.path) })
        return (table, paths, project)
    }

    @Test func rendersDurationAndRateOfTable() async throws {
        let folder = try TestFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let song = folder.appendingPathComponent("song.wav")
        try PreviewTests.wav(seconds: 3).write(to: song)
        let (table, paths, _) = try await Self.table()
        let target = folder.appendingPathComponent("video.mp4")
        try await VideoRenderer.render(
            table: table, paths: paths, song: song.path, fit: .fill, settings: RenderSettings(codec: .h264),
            to: target, progress: { _ in })
        let asset = AVURLAsset(url: target)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(abs(try await video.load(.nominalFrameRate) - 25) < 0.01)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) <= 1.0 / 25 + 1e-6)
        #expect(try Self.countFrames(asset, track: video) == 75)
    }

    static func countFrames(_ asset: AVAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += CMSampleBufferGetNumSamples(sample) }
        }
        return count
    }

    @Test func missingFileFailsWithMessage() async throws {
        let folder = try TestFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        var (table, paths, _) = try await Self.table()
        paths["schnitte-25.mov"] = folder.appendingPathComponent("fehlt.mov").path
        let target = folder.appendingPathComponent("video.mp4")
        await #expect(throws: VideoRenderer.RenderError.self) {
            try await VideoRenderer.render(
                table: table, paths: paths, song: nil, fit: .fill, settings: RenderSettings(codec: .h264), to: target,
                progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func missingSongFails() async throws {
        let folder = try TestFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (table, paths, _) = try await Self.table()
        let target = folder.appendingPathComponent("video.mp4")
        await #expect(throws: VideoRenderer.RenderError.missingSong) {
            try await VideoRenderer.render(
                table: table, paths: paths, song: folder.appendingPathComponent("fehlt.wav").path, fit: .fill,
                settings: RenderSettings(codec: .h264), to: target, progress: { _ in })
        }
    }

    @Test func cancelRemovesPartialFile() async throws {
        let folder = try TestFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (table, paths, _) = try await Self.table()
        let target = folder.appendingPathComponent("video.mp4")
        let task = Task { @MainActor in
            try await VideoRenderer.render(
                table: table, paths: paths, song: nil, fit: .fill, settings: RenderSettings(codec: .h264), to: target,
                progress: { _ in })
        }
        task.cancel()
        _ = await task.result
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func stillIsWritten() async throws {
        let folder = try TestFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("vorschaubild.jpg")
        try await VideoRenderer.writeStill(
            clipPath: TestFolder.clip("schnitte-25.mov").path, at: 0.5, size: CGSize(width: 1280, height: 720),
            to: target)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}
