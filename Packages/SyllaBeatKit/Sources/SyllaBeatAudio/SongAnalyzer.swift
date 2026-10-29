import Foundation
import SyllaBeatCore

/// Songanalyse ohne Modell: Beats, Tempo, Takte, Energie, Abschnitte aus der Audio-Struktur, Wellenform.
public struct SongAnalyzer: Sendable {
    public var meter: Int
    public var refineOnsets: Bool

    public init(meter: Int = 4, refineOnsets: Bool = true) {
        self.meter = meter
        self.refineOnsets = refineOnsets
    }

    public struct Output: Sendable {
        public var analysis: SongAnalysis
        public var waveform: Waveform
        public var spectrum: Spectrum
        public var audio: MonoAudio
    }

    public func analyze(_ url: URL) async throws -> Output {
        let audio = try await AudioDecoder.decodeMono(url)
        return try await Blocking.run { _ in analyze(audio) }
    }

    public func analyze(_ audio: MonoAudio) -> Output {
        let spectrum = Spectrum(audio)
        let result = BeatTracker.track(spectrum, meter: meter)
        var times = refineOnsets ? OnsetRefinement.calibrate(result.beats, in: audio) : result.beats
        times = MigrationV1Compatible.interior(times, duration: audio.duration)
        let beats = times.enumerated().map { index, time in
            Beat(time: time, isDownbeat: meter > 1 && (index - result.downbeatPhase) % meter == 0)
        }
        var analysis = SongAnalysis(
            duration: audio.duration, sampleRate: audio.sourceSampleRate, channels: audio.sourceChannels,
            tempo: result.tempo, meter: meter, beats: beats, energy: BeatEnergy.perBeat(audio, beats: times))
        analysis.sections = SongStructure.sections(spectrum: spectrum, analysis: analysis)
        return Output(analysis: analysis, waveform: Waveform(audio), spectrum: spectrum, audio: audio)
    }
}

/// Beats streng innerhalb des Songs, aufsteigend, ohne Dubletten (gleiche Regel wie die Migration aus 0.2.0).
enum MigrationV1Compatible {
    static func interior(_ beats: [Double], duration: Double) -> [Double] {
        var result: [Double] = []
        for beat in beats.sorted() where beat > 0.000001 && duration - beat > 0.000001 {
            if let last = result.last, beat - last <= 0.000001 { continue }
            result.append(beat)
        }
        return result
    }
}

/// Minimum/Maximum je Zeitfenster (100 je Sekunde), für die Wellenform der Timeline.
public struct Waveform: Sendable, Equatable {
    public static let binsPerSecond = 100.0
    public var minimum: [Float]
    public var maximum: [Float]

    public init(minimum: [Float], maximum: [Float]) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public init(_ audio: MonoAudio) {
        let size = max(1, Int(audio.sampleRate / Self.binsPerSecond))
        let count = (audio.samples.count + size - 1) / size
        var low = [Float](repeating: 0, count: count)
        var high = [Float](repeating: 0, count: count)
        audio.samples.withUnsafeBufferPointer { samples in
            for bin in 0..<count {
                let range = (bin * size)..<min(samples.count, (bin + 1) * size)
                var lo: Float = 0
                var hi: Float = 0
                for i in range {
                    lo = min(lo, samples[i])
                    hi = max(hi, samples[i])
                }
                low[bin] = lo
                high[bin] = hi
            }
        }
        minimum = low
        maximum = high
    }

    public var duration: Double { Double(minimum.count) / Self.binsPerSecond }

    /// Kompakte Ablage im Zwischenspeicher (Float16, je Bin Minimum und Maximum).
    public func encoded() -> Data {
        var values: [Float16] = []
        values.reserveCapacity(minimum.count * 2)
        for (lo, hi) in zip(minimum, maximum) {
            values.append(Float16(lo))
            values.append(Float16(hi))
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public init?(encoded data: Data) {
        guard data.count % 4 == 0 else { return nil }
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        minimum = stride(from: 0, to: values.count, by: 2).map { Float(values[$0]) }
        maximum = stride(from: 1, to: values.count, by: 2).map { Float(values[$0]) }
    }
}
