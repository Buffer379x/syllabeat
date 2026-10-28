import AVFoundation
import CoreVideo
import Foundation

/// Schreibt kleine Testclips: Farbflächen mit harten Schnitten an bekannten Frames, optional Drehung, Timecode und VFR.
struct SyntheticClip {
    var rate: (Int32, Int32) = (25, 1)
    var size = (width: 192, height: 108)
    var frames = 75
    /// Erster Frame jeder neuen Einstellung.
    var cutFrames: [Int] = []
    var rotation = 0
    var startTimecodeFrames: Int32?
    var variableRate = false
    var codec: AVVideoCodecType = .h264

    static let colors: [(UInt8, UInt8, UInt8)] = [
        (30, 90, 200), (220, 60, 40), (40, 180, 90), (240, 200, 40), (150, 60, 190),
    ]

    func cutTimes() -> [Double] {
        cutFrames.map { Double($0) * Double(rate.1) / Double(rate.0) }
    }

    /// Wartet auf den Writer, bricht aber ab, wenn er scheitert (z. B. ohne Encoder auf einer VM), statt zu hängen.
    static func waitUntilReady(_ input: AVAssetWriterInput, _ writer: AVAssetWriter) throws {
        let deadline = Date().addingTimeInterval(20)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            if Date() > deadline {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSDebugDescriptionErrorKey: "Writer hängt"])
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func write(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        input.expectsMediaDataInRealTime = false
        if rotation != 0 { input.transform = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
            ])
        writer.add(input)
        var timecodeInput: AVAssetWriterInput?
        if let start = startTimecodeFrames {
            var format: CMTimeCodeFormatDescription?
            CMTimeCodeFormatDescriptionCreate(
                allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                frameDuration: CMTime(value: CMTimeValue(rate.1), timescale: rate.0),
                frameQuanta: UInt32(rate.0 / rate.1),
                flags: 0, extensions: nil, formatDescriptionOut: &format)
            let tc = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: format)
            input.addTrackAssociation(withTrackOf: tc, type: AVAssetTrack.AssociationType.timecode.rawValue)
            writer.add(tc)
            timecodeInput = tc
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            var value = start.bigEndian
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            CMBlockBufferReplaceDataBytes(with: &value, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 4)
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: CMTimeValue(frames) * CMTimeValue(rate.1), timescale: rate.0),
                presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sampleSize = 4
            var sample: CMSampleBuffer?
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
            try Self.waitUntilReady(tc, writer)
            tc.append(sample!)
            tc.markAsFinished()
        } else {
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
        }
        _ = timecodeInput
        var time = CMTime.zero
        for index in 0..<frames {
            try Self.waitUntilReady(input, writer)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            let segment = cutFrames.filter { $0 <= index }.count
            let (r, g, b) = Self.colors[segment % Self.colors.count]
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let value = UInt32(b) | UInt32(g) << 8 | UInt32(r) << 16 | 0xFF00_0000
            // Ein wandernder heller Balken sorgt für Bewegung innerhalb einer Einstellung.
            let bar = (index * 4) % size.width
            for y in 0..<size.height {
                let row = (base + y * stride).assumingMemoryBound(to: UInt32.self)
                row.update(repeating: value, count: size.width)
                (row + bar).update(repeating: 0xFFFF_FFFF, count: min(8, size.width - bar))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: time)
            var step = CMTimeValue(rate.1)
            if variableRate { step = index % 3 == 0 ? CMTimeValue(rate.1) * 2 : CMTimeValue(rate.1) }
            time = time + CMTime(value: step, timescale: rate.0)
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 30) == .success else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSDebugDescriptionErrorKey: "finishWriting hängt"])
        }
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

enum TestFolder {
    static func make(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SyllaBeatMediaTests-\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let repository: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static let mkv = repository.appendingPathComponent("tests/Fixtures/media/zwei-farben.mkv")
}
