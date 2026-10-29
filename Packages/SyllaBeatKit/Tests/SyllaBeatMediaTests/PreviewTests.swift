import AVFoundation
import Foundation
import Testing

@testable import SyllaBeatCore
@testable import SyllaBeatMedia

/// Vorschau-Komposition aus der Frame-Tabelle: gemischte Raten, Drehung, Füllen/Einpassen, framegenaue Schnitte.
@Suite(.timeLimit(.minutes(2))) @MainActor struct PreviewTests {
    enum Color: Equatable { case blue, red, black, other }

    /// Drei Shots à 1 s bei 25 fps (320×180):
    /// 1. `schnitte-25.mov` ab Quellframe 30, Farbwechsel bei Quellframe 37 → Timelineframe 7.
    /// 2. `schnitte-5994.mov` ab Quellframe 55, Farbwechsel bei Quellframe 61 (+0,1001 s) → zwischen Frame 27 und 28.
    /// 3. `hoch-timecode.mov` (um 90° gedreht, Hochformat).
    static func project(fit: TimelineSettings.Fit) async throws -> Project {
        let names = ["schnitte-25.mov", "schnitte-5994.mov", "hoch-timecode.mov"]
        var clips: [Clip] = []
        for name in names {
            let url = TestFolder.clip(name)
            clips.append(Clip(id: name, media: MediaRef(path: url.path), meta: try await MediaProbe.read(url)))
        }
        let sourceIns = [Rational(30, 25), Rational(55 * 1001, 60000), Rational.zero]
        let shots = (0..<3).map { index in
            Shot(
                id: "shot-\(index + 1)",
                start: CutPoint(time: Double(index), anchor: index == 0 ? .songStart : .beat(index)),
                end: CutPoint(time: Double(index + 1), anchor: index == 2 ? .songEnd : .beat(index + 1)),
                clipID: names[index], sourceIn: sourceIns[index])
        }
        return Project(
            timeline: TimelineSettings(fps: Rational(25), width: 320, height: 180, fit: fit), clips: clips,
            analysis: SongAnalysis(duration: 3, beats: (0...3).map { Beat(time: Double($0)) }),
            cut: Cut(id: "test", name: "Test", seed: 1, origin: .engine, shots: shots))
    }

    static func preview(fit: TimelineSettings.Fit) async throws -> (PreviewBuilder.Preview, FrameTable) {
        let project = try await project(fit: fit)
        let table = try CutCompiler.compile(project, cut: project.cut!)
        let paths = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0.media.path) })
        let preview = try await PreviewBuilder().build(table: table, paths: paths, song: nil, fit: fit)
        return (preview, table)
    }

    @Test func lengthAndInstructionsMatchFrameTable() async throws {
        let (preview, table) = try await Self.preview(fit: .fill)
        #expect(preview.composition.duration == CMTime(value: table.durationFrames, timescale: 25))
        let ranges = preview.videoComposition.instructions.map(\.timeRange)
        #expect(ranges.count == table.entries.count)
        for (range, entry) in zip(ranges, table.entries) {
            #expect(range.start == CMTime(value: entry.startFrame, timescale: 25))
            #expect(range.end == CMTime(value: entry.endFrame, timescale: 25))
        }
        #expect(preview.missing.isEmpty)
    }

    @Test func cutsAreFrameAccurateAcrossRates() async throws {
        let (preview, _) = try await Self.preview(fit: .fill)
        let frames = try await Self.colors(preview, x: 0.5)
        #expect(frames[6] == .blue)
        #expect(frames[7] == .red)
        #expect(frames[27] == .blue)
        #expect(frames[28] == .red)
        // Gedrehter Clip füllt das Bild.
        #expect(frames[60] == .blue)
        #expect(try await Self.colors(preview, x: 0.05)[60] == .blue)
    }

    @Test func fitShowsPillarsForPortrait() async throws {
        let (preview, _) = try await Self.preview(fit: .fit)
        #expect(try await Self.colors(preview, x: 0.5)[60] == .blue)
        #expect(try await Self.colors(preview, x: 0.05)[60] == .black)
        // Querformat-Clips im gleichen Seitenverhältnis bleiben randlos.
        #expect(try await Self.colors(preview, x: 0.05)[3] == .blue)
    }

    /// Song als Tonspur, auch beim zweiten Aufbau aus dem Zwischenspeicher (die Spur braucht ihr lebendes Asset).
    @Test func songBecomesAudioTrack() async throws {
        let folder = try TestFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let song = folder.appendingPathComponent("song.wav")
        try Self.wav(seconds: 3).write(to: song)
        let project = try await Self.project(fit: .fill)
        let table = try CutCompiler.compile(project, cut: project.cut!)
        let paths = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0.media.path) })
        let builder = PreviewBuilder()
        for _ in 0..<2 {
            let preview = try await builder.build(table: table, paths: paths, song: song.path, fit: .fill)
            let audio = preview.composition.tracks(withMediaType: .audio)
            #expect(audio.count == 1)
            #expect(audio.first?.timeRange.duration == CMTime(value: 3, timescale: 1))
        }
    }

    /// Mono-WAV (16 Bit, 44,1 kHz) mit leisem Sinus, ohne AVFoundation geschrieben.
    static func wav(seconds: Int) -> Data {
        let rate = 44_100
        let count = rate * seconds
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(count * 2))
        for i in 0..<count { append(Int16(sin(Double(i) * 0.06) * 3000)) }
        return data
    }

    @Test func missingClipStaysBlack() async throws {
        let project = try await Self.project(fit: .fill)
        let table = try CutCompiler.compile(project, cut: project.cut!)
        var paths = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0.media.path) })
        paths["schnitte-5994.mov"] = "/nicht/vorhanden.mov"
        let preview = try await PreviewBuilder().build(table: table, paths: paths, song: nil, fit: .fill)
        #expect(preview.missing == ["schnitte-5994.mov"])
        let frames = try await Self.colors(preview, x: 0.5)
        #expect(frames[30] == .black)
        #expect(frames[60] == .blue)
    }

    /// Rendert die Komposition und klassifiziert je Timelineframe die Farbe in Bildhöhe ⅔ an der Stelle `x` (0…1).
    /// Der helle Balken der Testclips wird übersprungen, indem drei benachbarte Punkte abstimmen.
    static func colors(_ preview: PreviewBuilder.Preview, x: Double) async throws -> [Int: Color] {
        let reader = try AVAssetReader(asset: preview.composition)
        let tracks = preview.composition.tracks(withMediaType: .video)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = preview.videoComposition
        reader.add(output)
        let box = ReaderBox(reader: reader, output: output)
        return try await Blocking.run { _ in
            guard box.reader.startReading() else { throw box.reader.error ?? CocoaError(.fileReadUnknown) }
            var result: [Int: Color] = [:]
            while let sample = box.output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                result[Int((time * 25).rounded())] = Self.classify(buffer, x: x)
            }
            // Unveränderte Bilder (z. B. Schwarz) liefert der Compositor nur einmal: bis zum nächsten Bild fortschreiben.
            var last: Color?
            for frame in 0...(result.keys.max() ?? 0) {
                if let color = result[frame] { last = color } else { result[frame] = last }
            }
            return result
        }
    }

    nonisolated static func classify(_ buffer: CVPixelBuffer, x: Double) -> Color {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return .other }
        var votes: [Color: Int] = [:]
        for dx in [-12, 0, 12] {
            let px = min(width - 1, max(0, Int(Double(width) * x) + dx))
            let p = base + (height * 2 / 3) * row + px * 4
            let (b, g, r) = (Int(p[0]), Int(p[1]), Int(p[2]))
            let color: Color =
                r + g + b < 60 ? .black : b > r + 60 && b > g + 40 ? .blue : r > b + 60 && r > g + 60 ? .red : .other
            votes[color, default: 0] += 1
        }
        return votes.filter { $0.key != .other }.max { $0.value < $1.value }?.key ?? .other
    }
}

private final class ReaderBox: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderVideoCompositionOutput

    init(reader: AVAssetReader, output: AVAssetReaderVideoCompositionOutput) {
        self.reader = reader
        self.output = output
    }
}
