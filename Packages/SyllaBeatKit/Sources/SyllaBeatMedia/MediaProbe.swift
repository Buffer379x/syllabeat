import AVFoundation
import Foundation
import SyllaBeatCore

public enum MediaError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case noVideo(String)
    case unreadable(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name): "„\(name)“ kann macOS nicht direkt lesen. Eine Arbeitskopie macht sie nutzbar."
        case .noVideo(let name): "„\(name)“ enthält keine Videospur."
        case .unreadable(let name, let reason): "„\(name)“ ist nicht lesbar: \(reason)"
        }
    }
}

/// Liest die technischen Daten eines Clips über AVFoundation.
public enum MediaProbe {
    /// Gängige Raten exakt; behebt F12 aus 0.2.0 (23,976p wurde dort als 23040/961 erkannt).
    static let standardRates: [Rational] = [
        Rational(24000, 1001), Rational(24), Rational(25), Rational(30000, 1001), Rational(30), Rational(48),
        Rational(50), Rational(60000, 1001), Rational(60), Rational(100), Rational(120000, 1001), Rational(120),
        Rational(240),
    ]

    /// Rationale Rate. Die mittlere Framedauer über viele Präsentationszeiten ist am verlässlichsten: Bei Zeitbasis 600
    /// (iPhone) sind einzelne Framedauern und die nominale Rate gerundet (z. B. 24 statt 23,976 oder 60 statt 59,94).
    public static func rationalRate(nominal: Double, minFrameDuration: CMTime, sampleTimes: [Double] = []) -> Rational {
        func standard(_ value: Double, tolerance: Double) -> Rational? {
            standardRates.min { abs($0.doubleValue - value) < abs($1.doubleValue - value) }
                .flatMap { abs($0.doubleValue - value) < tolerance ? $0 : nil }
        }
        if sampleTimes.count >= 10, let first = sampleTimes.first, let last = sampleTimes.last, last > first {
            let average = Double(sampleTimes.count - 1) / (last - first)
            if let match = standard(average, tolerance: 0.02) { return match }
        }
        if let match = standard(nominal, tolerance: 0.01) { return match }
        if minFrameDuration.isValid, minFrameDuration.value > 0 {
            let candidate = Rational(Int64(minFrameDuration.timescale), minFrameDuration.value)
            if let match = standard(candidate.doubleValue, tolerance: 0.01) { return match }
            if nominal <= 0 || abs(candidate.doubleValue - nominal) < 0.5 { return candidate }
        }
        guard nominal > 0 else { return Rational(25) }
        return Rational(Int64((nominal * 1000).rounded()), 1000)
    }

    /// Schrittprotokoll auf stderr, wenn `SYLLABEAT_TRACE` gesetzt ist (Fehlersuche auf fremden Maschinen).
    static func trace(_ step: String) {
        guard ProcessInfo.processInfo.environment["SYLLABEAT_TRACE"] != nil else { return }
        FileHandle.standardError.write(Data("[probe] \(step)\n".utf8))
    }

    public static func read(_ url: URL) async throws -> ClipMetadata {
        let name = url.lastPathComponent
        trace("start \(name)")
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable: Bool
        do {
            playable = try await asset.load(.isReadable)
        } catch {
            throw MediaError.unsupported(name)
        }
        guard playable else { throw MediaError.unsupported(name) }
        trace("isReadable ok")
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideo(name)
        }
        trace("videoTrack ok")
        let (nominal, minFrame, size, transform, formats) = try await track.load(
            .nominalFrameRate, .minFrameDuration, .naturalSize, .preferredTransform, .formatDescriptions)
        let timescale = try await track.load(.naturalTimeScale)
        trace("trackProperties ok")
        let angle = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        var rotation = ((angle % 360) + 360) % 360
        rotation = [0, 90, 180, 270].min { abs($0 - rotation) < abs($1 - rotation) } ?? 0
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        trace("audioTrack ok")
        let sampleTimes = try await presentationTimes(asset: asset, track: track, limit: 121)
        trace("presentationTimes ok")
        let rate = rationalRate(nominal: Double(nominal), minFrameDuration: minFrame, sampleTimes: sampleTimes)
        let isVFR = variableRate(sampleTimes, timescale: timescale)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        var warnings: [String] = []
        if isVFR == true {
            warnings.append("Variable Bildrate erkannt. Für framegenauen Schnitt eine CFR-Arbeitskopie verwenden.")
        }
        return ClipMetadata(
            duration: duration, fps: rate,
            frameCount: (Rational(seconds: duration) * rate).roundedHalfUp(),
            width: Int(size.width.rounded()), height: Int(size.height.rounded()), rotation: rotation,
            codec: codec?.trimmingCharacters(in: .whitespaces).lowercased(),
            startTimecode: try await tracedTimecode(asset), isVFR: isVFR,
            sizeBytes: attributes?[.size] as? Int64, hasAudio: hasAudio, warnings: warnings)
    }

    static func tracedTimecode(_ asset: AVURLAsset) async throws -> String? {
        let value = try await startTimecode(asset: asset)
        trace("timecode ok")
        return value
    }

    /// Ist die Abweichung einzelner Abstände größer als 8 % (mindestens 1,5 ms und 1,5 Schritte der Zeitbasis),
    /// gilt die Rate als variabel. Rundung auf die Zeitbasis (z. B. 10/600 und 11/600 s bei 59,94p) ist kein VFR.
    static func variableRate(_ times: [Double], timescale: Int32 = 0) -> Bool? {
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        guard gaps.count >= 5 else { return nil }
        let median = gaps.sorted()[gaps.count / 2]
        let tick = timescale > 0 ? 1.5 / Double(timescale) : 0
        return gaps.contains { abs($0 - median) > max(0.0015, median * 0.08, tick) }
    }

    /// Präsentationszeiten der ersten Samples, ohne zu dekodieren.
    static func presentationTimes(asset: AVURLAsset, track: AVAssetTrack, limit: Int) async throws -> [Double] {
        let objects = Unshared(value: (asset, track))
        return try await Blocking.run { cancellation in
            try readPresentationTimes(asset: objects.value.0, track: objects.value.1, limit: limit, cancellation)
        }
    }

    private static func readPresentationTimes(
        asset: AVURLAsset, track: AVAssetTrack, limit: Int, _ cancellation: Blocking.Cancellation
    ) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        var times: [Double] = []
        while times.count < limit, let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            if CMSampleBufferGetNumSamples(sample) > 0 {
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
        }
        return times.sorted()
    }

    /// Start-Timecode aus der Timecode-Spur (behebt F2 aus 0.2.0), z. B. `10:00:00:00`.
    static func startTimecode(asset: AVURLAsset) async throws -> String? {
        guard let track = try await asset.loadTracks(withMediaType: .timecode).first else { return nil }
        let objects = Unshared(value: (asset, track))
        return try await Blocking.run { _ in try readTimecode(asset: objects.value.0, track: objects.value.1) }
    }

    private static func readTimecode(asset: AVURLAsset, track: AVAssetTrack) throws -> String? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        // Das erste Sample kann ein leerer Marker sein.
        for _ in 0..<8 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sample),
                let format = CMSampleBufferGetFormatDescription(sample)
            else { continue }
            let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(format))
            guard quanta > 0 else { return nil }
            let frames: Int
            if CMFormatDescriptionGetMediaSubType(format) == kCMTimeCodeFormatType_TimeCode64 {
                var raw: Int64 = 0
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 8, destination: &raw)
                frames = Int(Int64(bigEndian: raw))
            } else {
                var raw: Int32 = 0
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &raw)
                frames = Int(Int32(bigEndian: raw))
            }
            let dropFrame = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format) & kCMTimeCodeFlag_DropFrame != 0
            return Timecode.string(frames: frames, quanta: quanta, dropFrame: dropFrame)
        }
        return nil
    }

    static func fourCC(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
    }
}

public enum Timecode {
    /// Frames seit Mitternacht als `HH:MM:SS:FF` (bzw. `HH:MM:SS;FF` bei Drop-Frame).
    public static func string(frames: Int, quanta: Int, dropFrame: Bool = false) -> String {
        var count = frames
        if dropFrame, quanta == 30 || quanta == 60 {
            let drop = quanta / 15
            let perTenMinutes = quanta * 600 - drop * 9
            let perMinute = quanta * 60 - drop
            let tens = count / perTenMinutes
            let rest = count % perTenMinutes
            count += drop * 9 * tens + (rest > drop ? drop * ((rest - drop) / perMinute) : 0)
        }
        let f = count % quanta
        let s = count / quanta
        let separator = dropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", s / 3600 % 24, s / 60 % 60, s % 60, separator, f)
    }
}
