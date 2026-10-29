import Accelerate
import Foundation

/// Ein STFT-Durchlauf (FFT 2048, Hop 256 ≙ 11,6 ms bei 22,05 kHz) mit allem, was Beat-Tracking, Takte,
/// Struktur und das Einrasten von Wortzeiten brauchen.
public struct Spectrum: Sendable {
    public let sampleRate: Double
    public let hop: Int
    public let frameCount: Int
    /// Mel-Spektrum in dB (−80…0), 128 Bänder, zeilenweise je Frame.
    public let mel: [Float]
    public let melBands: Int
    /// Mittlerer positiver Spektralfluss je Frame (Onset-Hüllkurve).
    public let onset: [Float]
    /// Spektralfluss der untersten Mel-Bänder (Bass, für Taktanfänge).
    public let bass: [Float]
    /// Spektralfluss oberhalb von ca. 1 kHz (Gesang und Konsonanten, für Wortanfänge).
    public let high: [Float]
    /// Spektralfluss im Stimmband (300 Hz–3,5 kHz), für Wortanfänge.
    public let vocal: [Float]
    /// Chroma (12 Tonklassen) je Frame, normiert.
    public let chroma: [Float]

    public var frameRate: Double { sampleRate / Double(hop) }

    public func time(ofFrame frame: Double) -> Double { frame * Double(hop) / sampleRate }

    public init(_ audio: MonoAudio, fftSize: Int = 2048, hop: Int = 256, melBands: Int = 128) {
        let samples = audio.samples
        let sampleRate = audio.sampleRate
        self.sampleRate = sampleRate
        self.hop = hop
        self.melBands = melBands
        let pad = fftSize / 2
        var padded = [Float](repeating: 0, count: samples.count + 2 * pad)
        padded.replaceSubrange(pad..<(pad + samples.count), with: samples)
        if samples.count > 1 {
            for i in 0..<pad {
                padded[pad - 1 - i] = samples[min(samples.count - 1, i + 1)]
                padded[pad + samples.count + i] = samples[max(0, samples.count - 2 - i)]
            }
        }
        let frames = max(1, 1 + (padded.count - fftSize) / hop)
        frameCount = frames
        let bins = fftSize / 2 + 1
        let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)!
        let window = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        let filters = Self.melFilters(bands: melBands, bins: bins, fftSize: fftSize, sampleRate: sampleRate)
        let pitchClass = (0..<bins).map { bin -> Int in
            let frequency = Double(bin) * sampleRate / Double(fftSize)
            guard frequency >= 55, frequency <= 5000 else { return -1 }
            let midi = 69 + 12 * log2(frequency / 440)
            return ((Int(midi.rounded()) % 12) + 12) % 12
        }
        var mel = [Float](repeating: 0, count: frames * melBands)
        var chroma = [Float](repeating: 0, count: frames * 12)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var frame = [Float](repeating: 0, count: fftSize)
        var power = [Float](repeating: 0, count: bins)
        for t in 0..<frames {
            padded.withUnsafeBufferPointer { source in
                vDSP.multiply(
                    UnsafeBufferPointer(rebasing: source[(t * hop)..<(t * hop + fftSize)]), window, result: &frame)
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(
                            raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    fft.forward(input: split, output: &split)
                    power[0] = split.realp[0] * split.realp[0]
                    power[bins - 1] = split.imagp[0] * split.imagp[0]
                    for k in 1..<(bins - 1) {
                        power[k] = split.realp[k] * split.realp[k] + split.imagp[k] * split.imagp[k]
                    }
                }
            }
            for m in 0..<melBands { mel[t * melBands + m] = vDSP.dot(filters[m], power) }
            var classes = [Float](repeating: 0, count: 12)
            for k in 1..<bins where pitchClass[k] >= 0 { classes[pitchClass[k]] += power[k] }
            let total = max(1e-12, classes.max() ?? 0)
            for c in 0..<12 { chroma[t * 12 + c] = classes[c] / total }
        }
        let maxPower = max(1e-10, mel.max() ?? 1)
        for i in mel.indices { mel[i] = max(-80, 10 * log10(max(1e-10, mel[i]) / maxPower)) }
        let highStart = Self.band(forHz: 1000, bands: melBands, sampleRate: sampleRate)
        let vocalBands =
            Self.band(
                forHz: 300, bands: melBands, sampleRate: sampleRate)..<Self.band(
                forHz: 3500, bands: melBands, sampleRate: sampleRate)
        var vocal = [Float](repeating: 0, count: frames)
        var onset = [Float](repeating: 0, count: frames)
        var bass = [Float](repeating: 0, count: frames)
        var high = [Float](repeating: 0, count: frames)
        for t in 1..<max(1, frames) {
            var sum: Float = 0
            var low: Float = 0
            var top: Float = 0
            var voice: Float = 0
            for m in 0..<melBands {
                let d = max(0, mel[t * melBands + m] - mel[(t - 1) * melBands + m])
                sum += d
                if m < 10 { low += d }
                if m >= highStart { top += d }
                if vocalBands.contains(m) { voice += d }
            }
            vocal[t] = voice / Float(max(1, vocalBands.count))
            onset[t] = sum / Float(melBands)
            bass[t] = low / 10
            high[t] = top / Float(max(1, melBands - highStart))
        }
        self.mel = mel
        self.chroma = chroma
        self.onset = onset
        self.bass = bass
        self.high = high
        self.vocal = vocal
    }

    static func hzToMel(_ f: Double) -> Double { f < 1000 ? f / (200.0 / 3) : 15 + log(f / 1000) / (log(6.4) / 27) }
    static func melToHz(_ m: Double) -> Double { m < 15 ? m * 200.0 / 3 : 1000 * exp((m - 15) * log(6.4) / 27) }

    static func band(forHz hz: Double, bands: Int, sampleRate: Double) -> Int {
        Int((hzToMel(hz) / hzToMel(sampleRate / 2) * Double(bands + 1)).rounded())
    }

    /// Slaney-Filterbank wie der librosa-Standard.
    static func melFilters(bands: Int, bins: Int, fftSize: Int, sampleRate: Double) -> [[Float]] {
        let top = hzToMel(sampleRate / 2)
        let points = (0...(bands + 1)).map { melToHz(top * Double($0) / Double(bands + 1)) }
        var filters = [[Float]](repeating: [Float](repeating: 0, count: bins), count: bands)
        for m in 0..<bands {
            let lo = points[m]
            let center = points[m + 1]
            let hi = points[m + 2]
            let norm = 2 / (hi - lo)
            for k in 0..<bins {
                let f = Double(k) * sampleRate / Double(fftSize)
                filters[m][k] = Float(max(0, min((f - lo) / (center - lo), (hi - f) / (hi - center))) * norm)
            }
        }
        return filters
    }
}
