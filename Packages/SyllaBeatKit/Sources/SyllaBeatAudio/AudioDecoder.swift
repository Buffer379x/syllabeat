import AVFoundation
import Foundation
import SyllaBeatCore

public enum AudioError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Die Audiodatei „\(name)“ ist nicht lesbar."
        case .empty(let name): "„\(name)“ enthält keinen Ton."
        }
    }
}

/// Mono-Audio mit fester Abtastrate.
public struct MonoAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    /// Abtastrate und Kanäle der Originaldatei.
    public var sourceSampleRate: Int
    public var sourceChannels: Int

    public var duration: Double { Double(samples.count) / sampleRate }

    public init(samples: [Float], sampleRate: Double, sourceSampleRate: Int = 0, sourceChannels: Int = 1) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.sourceSampleRate = sourceSampleRate
        self.sourceChannels = sourceChannels
    }
}

public enum AudioDecoder {
    /// Dekodiert blockweise (1 s) und wandelt hochwertig nach Mono mit `sampleRate`.
    public static func decodeMono(_ url: URL, sampleRate: Double = 22_050) async throws -> MonoAudio {
        try await Blocking.run { cancellation in try decode(url, sampleRate: sampleRate, cancellation) }
    }

    static func decode(_ url: URL, sampleRate: Double, _ cancellation: Blocking.Cancellation) throws -> MonoAudio {
        let name = url.lastPathComponent
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioError.unreadable(name)
        }
        let input = file.processingFormat
        guard file.length > 0 else { throw AudioError.empty(name) }
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: target)
        else { throw AudioError.unreadable(name) }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.downmix = true
        let chunk = AVAudioFrameCount(max(1024, input.sampleRate))
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else {
            throw AudioError.unreadable(name)
        }
        let outCapacity = AVAudioFrameCount(Double(chunk) * sampleRate / input.sampleRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            throw AudioError.unreadable(name)
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / input.sampleRate) + 1024)
        var finished = false
        var readError: (any Error)?
        while true {
            try cancellation.check()
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, state in
                if finished {
                    state.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: chunk)
                } catch {
                    readError = error
                    finished = true
                    state.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    finished = true
                    state.pointee = .endOfStream
                    return nil
                }
                state.pointee = .haveData
                return inBuffer
            }
            if let conversionError { throw conversionError }
            if let channel = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        if readError != nil, samples.isEmpty { throw AudioError.unreadable(name) }
        guard !samples.isEmpty else { throw AudioError.empty(name) }
        return MonoAudio(
            samples: samples, sampleRate: sampleRate, sourceSampleRate: Int(input.sampleRate),
            sourceChannels: Int(input.channelCount))
    }
}
