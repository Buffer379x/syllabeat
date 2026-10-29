import Foundation
import Testing

@testable import SyllaBeatAudio

/// Klicktrack: kurzer Ton auf jedem Beat, tiefer Schlag auf jedem Taktanfang.
enum ClickTrack {
    static func make(beats: [Double], duration: Double, sampleRate: Double = 22_050, meter: Int = 4) -> MonoAudio {
        var samples = [Float](repeating: 0, count: Int(duration * sampleRate))
        for (index, time) in beats.enumerated() {
            let start = Int(time * sampleRate)
            let downbeat = index % meter == 0
            for i in 0..<Int(0.06 * sampleRate) where start + i < samples.count {
                let t = Double(i) / sampleRate
                let envelope = exp(-t * 60)
                var value = 0.5 * sin(2 * .pi * 1200 * t) * envelope
                if downbeat { value += 0.8 * sin(2 * .pi * 70 * t) * exp(-t * 25) }
                samples[start + i] += Float(value)
            }
        }
        return MonoAudio(samples: samples, sampleRate: sampleRate)
    }

    static func steady(bpm: Double, offset: Double = 0.3, duration: Double = 30) -> [Double] {
        stride(from: offset, to: duration - 0.2, by: 60 / bpm).map { $0 }
    }

    /// Tempo wechselt linear von `from` auf `to` BPM.
    static func ramp(from: Double, to: Double, duration: Double = 40) -> [Double] {
        var beats: [Double] = []
        var time = 0.4
        while time < duration - 0.3 {
            beats.append(time)
            let bpm = from + (to - from) * time / duration
            time += 60 / bpm
        }
        return beats
    }
}

/// Mittlerer und größter Abstand zur nächsten Referenz, dazu Anteil getroffener Referenzen (±70 ms).
func compare(_ found: [Double], _ reference: [Double]) -> (recall: Double, mean: Double, max: Double) {
    var errors: [Double] = []
    var hits = 0
    for r in reference {
        guard let nearest = found.min(by: { abs($0 - r) < abs($1 - r) }) else { continue }
        if abs(nearest - r) <= 0.07 {
            hits += 1
            errors.append(abs(nearest - r))
        }
    }
    return (
        Double(hits) / Double(max(1, reference.count)), errors.reduce(0, +) / Double(max(1, errors.count)),
        errors.max() ?? 1
    )
}

@Suite struct BeatTrackerTests {
    @Test(arguments: [90.0, 120.0, 174.0])
    func clickTracksAreExact(bpm: Double) {
        let reference = ClickTrack.steady(bpm: bpm)
        let audio = ClickTrack.make(beats: reference, duration: 30)
        var result = BeatTracker.track(Spectrum(audio))
        result.beats = OnsetRefinement.calibrate(result.beats, in: audio)
        let score = compare(result.beats, reference)
        #expect(abs(result.tempo - bpm) <= 0.5, "Tempo \(result.tempo)")
        #expect(score.recall >= 0.95, "Trefferquote \(score.recall)")
        #expect(score.max <= 0.010, "größter Fehler \(score.max * 1000) ms")
        #expect(result.beats.count <= reference.count + 1, "\(result.beats.count) statt \(reference.count) Beats")
        // Der tiefe Schlag liegt auf jedem vierten Referenz-Beat ab dem ersten.
        let downbeat = result.beats.firstIndex { found in
            reference.enumerated().contains { $0.offset % 4 == 0 && abs($0.element - found) < 0.07 }
        }
        #expect(downbeat.map { $0 % 4 } == result.downbeatPhase, "Taktanfang \(result.downbeatPhase)")
    }

    @Test func followsTempoRamp() {
        let reference = ClickTrack.ramp(from: 110, to: 130)
        let audio = ClickTrack.make(beats: reference, duration: 40)
        let beats = OnsetRefinement.calibrate(BeatTracker.track(Spectrum(audio)).beats, in: audio)
        let score = compare(beats, reference)
        #expect(score.recall >= 0.9, "Trefferquote \(score.recall)")
        #expect(score.mean <= 0.010, "mittlerer Fehler \(score.mean * 1000) ms")
    }

    @Test func energyIsPercentile() {
        var audio = ClickTrack.make(beats: [0.5, 1, 1.5, 2], duration: 2.5)
        for i in Int(1.5 * audio.sampleRate)..<audio.samples.count { audio.samples[i] *= 4 }
        let energy = BeatEnergy.perBeat(audio, beats: [0.5, 1, 1.5, 2])
        #expect(energy.count == 4)
        #expect(energy.allSatisfy { (0...1).contains($0) })
        #expect(energy[3] > energy[0])
    }

    @Test func silenceGivesNoBeats() {
        let result = BeatTracker.track(
            Spectrum(MonoAudio(samples: [Float](repeating: 0, count: 22_050 * 5), sampleRate: 22_050)))
        #expect(result.beats.count < 3)
    }
}
