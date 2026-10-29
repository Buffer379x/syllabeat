import Accelerate
import Foundation

/// Nativer Beat-Tracker nach Ellis (2007), wie `librosa.beat.beat_track`, mit Subframe-Verfeinerung.
/// In M0 auf allen Testsongs mindestens so gut wie 0.2.0, mit 2–3× kleinerem Zeitfehler.
public enum BeatTracker {
    public struct Result: Sendable, Equatable {
        public var beats: [Double]
        public var tempo: Double
        /// Index des ersten Taktanfangs in `beats` (0…meter−1).
        public var downbeatPhase: Int
    }

    public static func track(
        _ spectrum: Spectrum, startBPM: Double = 120, tightness: Double = 100, meter: Int = 4
    ) -> Result {
        let frames = spectrum.frameCount
        let onset = spectrum.onset
        let frameRate = spectrum.frameRate
        guard frames > Int(frameRate * 2) else { return Result(beats: [], tempo: 0, downbeatPhase: 0) }
        let tempo = estimateTempo(onset, frameRate: frameRate, startBPM: startBPM)
        // Gleichanteil entfernen (wie librosa), auf Standardabweichung normieren, lokal glätten.
        var detrended = [Float](repeating: 0, count: frames)
        var previousIn: Float = 0
        var previousOut: Float = 0
        for t in 0..<frames {
            let y = onset[t] - previousIn + 0.99 * previousOut
            detrended[t] = y
            previousIn = onset[t]
            previousOut = y
        }
        let mean = Double(vDSP.mean(detrended))
        let std = max(1e-12, sqrt(Double(vDSP.meanSquare(detrended)) - mean * mean))
        let normalized = detrended.map { Double($0) / std }
        let framesPerBeat = (frameRate * 60 / tempo).rounded()
        let half = Int(framesPerBeat)
        let kernel = (-half...half).map { exp(-0.5 * pow(Double($0) * 32 / framesPerBeat, 2)) }
        var local = [Double](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum = 0.0
            for (k, weight) in kernel.enumerated() {
                let j = i + half - k
                if j >= 0, j < frames { sum += weight * normalized[j] }
            }
            local[i] = sum
        }
        // Dynamische Programmierung: Onset-Stärke plus Strafe für Abweichung vom Beat-Abstand.
        var score = [Double](repeating: 0, count: frames)
        var backlink = [Int](repeating: -1, count: frames)
        let threshold = 0.01 * (local.max() ?? 0)
        var firstBeat = true
        let logPeriod = log(framesPerBeat)
        for i in 0..<frames {
            var best = -Double.infinity
            var location = -1
            var candidate = i - Int((framesPerBeat / 2).rounded())
            let lowest = i - 2 * Int(framesPerBeat) - 1
            while candidate > lowest, candidate >= 0 {
                let value = score[candidate] - tightness * pow(log(Double(i - candidate)) - logPeriod, 2)
                if value > best {
                    best = value
                    location = candidate
                }
                candidate -= 1
            }
            score[i] = location >= 0 ? local[i] + best : local[i]
            if firstBeat, local[i] < threshold {
                backlink[i] = -1
            } else {
                backlink[i] = location
                firstBeat = false
            }
        }
        var maxima: [Int] = []
        for i in 0..<frames {
            let left = i == 0 ? -Double.infinity : score[i - 1]
            let right = i == frames - 1 ? -Double.infinity : score[i + 1]
            if score[i] > left, score[i] >= right { maxima.append(i) }
        }
        guard !maxima.isEmpty else { return Result(beats: [], tempo: tempo, downbeatPhase: 0) }
        let medianMaximum = maxima.map { score[$0] }.sorted()[maxima.count / 2]
        var tail = frames - 1
        for i in maxima.reversed() where score[i] >= 0.5 * medianMaximum {
            tail = i
            break
        }
        var beatFrames: [Int] = []
        var n = tail
        while n >= 0 {
            beatFrames.append(n)
            n = backlink[n]
        }
        beatFrames.reverse()
        // Schwache Beats am Anfang und Ende verwerfen.
        let strengths = beatFrames.map { local[$0] }
        let rms = sqrt(strengths.map { $0 * $0 }.reduce(0, +) / Double(max(1, strengths.count)))
        while let first = beatFrames.first, local[first] <= 0.5 * rms { beatFrames.removeFirst() }
        while let last = beatFrames.last, local[last] <= 0.5 * rms { beatFrames.removeLast() }
        // Subframe-Verfeinerung: Onset-Spitze im Fenster ±3 Frames, parabolisch interpoliert.
        let times = beatFrames.map { spectrum.time(ofFrame: refinedPeak(onset, near: $0, radius: 3)) }
        return Result(beats: times, tempo: tempo, downbeatPhase: downbeatPhase(spectrum, beatFrames, meter: meter))
    }

    /// Gemittelte, gefensterte Autokorrelation (≈ 8,9 s) mit log-normalem Prior um `startBPM`.
    static func estimateTempo(_ onset: [Float], frameRate: Double, startBPM: Double) -> Double {
        let window = min(onset.count, Int((8.9 * frameRate).rounded()))
        guard window > 8 else { return startBPM }
        let hann = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized, count: window, isHalfWindow: false)
        var average = [Double](repeating: 0, count: window)
        var windows = 0
        var segment = [Float](repeating: 0, count: window)
        var start = 0
        while start + window <= onset.count {
            onset.withUnsafeBufferPointer { source in
                vDSP.multiply(UnsafeBufferPointer(rebasing: source[start..<(start + window)]), hann, result: &segment)
            }
            let zero = Double(vDSP.dot(segment, segment))
            if zero > 0 {
                segment.withUnsafeBufferPointer { s in
                    for lag in 1..<window {
                        var value: Float = 0
                        vDSP_dotpr(s.baseAddress!, 1, s.baseAddress! + lag, 1, &value, vDSP_Length(window - lag))
                        average[lag] += Double(value) / zero
                    }
                }
                windows += 1
            }
            start += 64
        }
        var bestLag = 1
        var bestScore = -Double.infinity
        for lag in 1..<window {
            let bpm = 60 * frameRate / Double(lag)
            guard bpm >= 30, bpm <= 320 else { continue }
            let prior = -0.5 * pow(log2(bpm) - log2(startBPM), 2)
            let value = log1p(1e6 * average[lag] / Double(max(1, windows))) + prior
            if value > bestScore {
                bestScore = value
                bestLag = lag
            }
        }
        var period = Double(bestLag)
        if bestLag > 1, bestLag < window - 1 {
            let a = average[bestLag - 1]
            let b = average[bestLag]
            let c = average[bestLag + 1]
            let denominator = a - 2 * b + c
            if denominator != 0 { period += 0.5 * (a - c) / denominator }
        }
        return 60 * frameRate / period
    }

    static func refinedPeak(_ envelope: [Float], near frame: Int, radius: Int) -> Double {
        guard envelope.count > 2 else { return Double(frame) }
        var best = min(max(1, frame), envelope.count - 2)
        for j in max(1, frame - radius)...min(envelope.count - 2, frame + radius) where envelope[j] > envelope[best] {
            best = j
        }
        let a = Double(envelope[best - 1])
        let b = Double(envelope[best])
        let c = Double(envelope[best + 1])
        let d = a - 2 * b + c
        let offset = d != 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / d)) : 0
        return Double(best) + offset
    }

    /// Taktanfang: die Phase mit der stärksten Bass-Onset-Energie.
    static func downbeatPhase(_ spectrum: Spectrum, _ beatFrames: [Int], meter: Int) -> Int {
        guard meter > 1, !beatFrames.isEmpty else { return 0 }
        var scores = [Double](repeating: 0, count: meter)
        for (index, frame) in beatFrames.enumerated() {
            let range = max(0, frame - 2)...min(spectrum.frameCount - 1, frame + 2)
            scores[index % meter] += range.map { Double(spectrum.bass[$0]) }.max() ?? 0
        }
        return scores.indices.max { scores[$0] < scores[$1] } ?? 0
    }
}

/// Feinkorrektur im Zeitbereich: Das zentrierte FFT-Fenster erkennt Einsätze rund 30 ms zu früh. Jeder Zeitpunkt
/// rastet daher auf den steilsten Anstieg der Hüllkurve (Fenster 2,9 ms) im Umkreis von `radius` ein.
public enum OnsetRefinement {
    /// Verschiebt alle Zeitpunkte um den Median der Einzelkorrekturen: Der systematische Versatz verschwindet,
    /// die geringe Streuung des Spektralverfahrens bleibt (Einzelkorrekturen springen sonst auf Hi-Hats u. Ä.).
    public static func calibrate(_ times: [Double], in audio: MonoAudio) -> [Double] {
        guard times.count >= 4 else { return times }
        let deltas = zip(refine(times, in: audio), times).map { $0 - $1 }.sorted()
        let offset = min(0.05, max(-0.01, deltas[deltas.count / 2]))
        return times.map { $0 + offset }
    }

    public static func refine(_ times: [Double], in audio: MonoAudio, radius: Double = 0.05) -> [Double] {
        let rate = audio.sampleRate
        let window = max(8, Int(0.0029 * rate))
        let samples = audio.samples
        return times.map { time in
            let center = Int(time * rate)
            let lo = max(window, center - Int(radius * rate))
            let hi = min(samples.count - window - 1, center + Int(radius * rate))
            guard hi > lo else { return time }
            // Gleitende mittlere Amplitude, dann größter Anstieg über ein Fenster.
            var envelope = [Float](repeating: 0, count: hi - lo + window + 1)
            var sum: Float = 0
            for i in 0..<envelope.count {
                sum += abs(samples[lo - window + i])
                if i >= window { sum -= abs(samples[lo - 2 * window + i]) }
                envelope[i] = sum / Float(window)
            }
            var best = time
            var bestRise: Float = 0
            for i in window..<envelope.count {
                let rise = envelope[i] - envelope[i - window]
                if rise > bestRise {
                    bestRise = rise
                    // Der Einsatz beginnt am Anfang des Fensters, in dem die Hüllkurve am stärksten steigt.
                    best = Double(lo - window + i - window) / rate
                }
            }
            return bestRise > 0 ? best : time
        }
    }
}

/// Energie je Beat-Intervall (RMS), als Perzentil 0…1 normiert.
public enum BeatEnergy {
    public static func perBeat(_ audio: MonoAudio, beats: [Double]) -> [Float] {
        guard !beats.isEmpty else { return [] }
        let bounds = beats + [audio.duration]
        var values: [Float] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            let a = max(0, min(audio.samples.count, Int(start * audio.sampleRate)))
            let b = max(a, min(audio.samples.count, Int(end * audio.sampleRate)))
            values.append(
                b > a
                    ? audio.samples.withUnsafeBufferPointer {
                        vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: $0[a..<b]))
                    } : 0)
        }
        let sorted = values.sorted()
        return values.map { value in
            let rank = sorted.firstIndex { $0 >= value } ?? 0
            return Float(rank) / Float(max(1, sorted.count - 1))
        }
    }
}
