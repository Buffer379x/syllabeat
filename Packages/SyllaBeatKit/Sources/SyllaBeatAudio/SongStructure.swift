import Accelerate
import Foundation
import SyllaBeatCore

/// Abschnitte aus der Audio-Struktur: Merkmale je Takt (Chroma und Klangfarbe), Selbstähnlichkeit, Foote-Novelty
/// für Grenzen, Vergleich entlang der Diagonale für Wiederholungen. Die energiereichste wiederholte Familie ist der
/// Refrain. Grenzen liegen immer auf Taktanfängen.
public enum SongStructure {
    public static func sections(spectrum: Spectrum, analysis: SongAnalysis) -> [SongSection] {
        let bars = barStarts(analysis)
        guard bars.count >= 6 else {
            return [SongSection(id: "sec-1", kind: .other, label: "Song", start: 0, end: analysis.duration)]
        }
        let features = barFeatures(spectrum, bars: bars, end: analysis.duration)
        let ssm = similarity(features)
        var boundaries = novelBoundaries(ssm, kernelBars: 4, minimumBars: 4)
        // Auftakt vor dem ersten Takt und Ausklang nach dem letzten gehören zum ersten bzw. letzten Abschnitt.
        boundaries = boundaries.filter { $0 > 0 && $0 < bars.count }
        let starts = [0] + boundaries
        let ends = boundaries + [bars.count]
        let segments = zip(starts, ends).map { $0..<$1 }
        let families = repeatFamilies(segments, ssm: ssm)
        let energy = barEnergy(analysis, bars: bars)
        return label(segments, families: families, energy: energy, bars: bars, duration: analysis.duration)
    }

    /// Taktanfänge (Zeitpunkte) aus Beats und Takt-Phase.
    static func barStarts(_ analysis: SongAnalysis) -> [Double] {
        let downbeats = analysis.beats.filter(\.isDownbeat).map(\.time)
        if downbeats.count >= 2 { return downbeats }
        return stride(from: 0, to: analysis.beats.count, by: max(1, analysis.meter)).map { analysis.beats[$0].time }
    }

    /// Je Takt: Chroma (12) und 20 gemittelte Mel-Bänder, je Dimension standardisiert, dann L2-normiert.
    static func barFeatures(_ spectrum: Spectrum, bars: [Double], end: Double) -> [[Float]] {
        let bounds = bars + [end]
        let groups = 20
        let perGroup = spectrum.melBands / groups
        var rows: [[Float]] = []
        for (start, stop) in zip(bounds, bounds.dropFirst()) {
            let a = max(0, min(spectrum.frameCount - 1, Int(start * spectrum.frameRate)))
            let b = max(a + 1, min(spectrum.frameCount, Int(stop * spectrum.frameRate)))
            var row = [Float](repeating: 0, count: 12 + groups)
            for t in a..<b {
                for c in 0..<12 { row[c] += spectrum.chroma[t * 12 + c] }
                for g in 0..<groups {
                    var sum: Float = 0
                    for m in (g * perGroup)..<((g + 1) * perGroup) { sum += spectrum.mel[t * spectrum.melBands + m] }
                    row[12 + g] += sum / Float(perGroup)
                }
            }
            rows.append(row.map { $0 / Float(b - a) })
        }
        let dims = rows.first?.count ?? 0
        for d in 0..<dims {
            let column = rows.map { $0[d] }
            let mean = vDSP.mean(column)
            let std = max(1e-6, sqrt(vDSP.meanSquare(column) - mean * mean))
            for i in rows.indices { rows[i][d] = (rows[i][d] - mean) / std }
        }
        return rows.map { row in
            let norm = max(1e-6, sqrt(vDSP.sumOfSquares(row)))
            return row.map { $0 / norm }
        }
    }

    static func similarity(_ features: [[Float]]) -> [[Float]] {
        features.map { a in features.map { b in vDSP.dot(a, b) } }
    }

    /// Foote-Novelty mit Gauß-gewichtetem Schachbrettkern; Spitzen über Mittel + ½ σ, Mindestabstand in Takten.
    static func novelBoundaries(_ ssm: [[Float]], kernelBars: Int, minimumBars: Int) -> [Int] {
        let n = ssm.count
        var novelty = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Float = 0
            for u in -kernelBars..<kernelBars {
                for v in -kernelBars..<kernelBars {
                    let a = i + u
                    let b = i + v
                    guard a >= 0, b >= 0, a < n, b < n else { continue }
                    let sign: Float = (u < 0) == (v < 0) ? 1 : -1
                    let du = Float(u) + 0.5
                    let dv = Float(v) + 0.5
                    let weight = exp(-(du * du + dv * dv) / Float(2 * kernelBars * kernelBars) * 2)
                    sum += sign * weight * ssm[a][b]
                }
            }
            novelty[i] = max(0, sum)
        }
        let mean = vDSP.mean(novelty)
        let std = sqrt(max(0, vDSP.meanSquare(novelty) - mean * mean))
        let threshold = mean + 0.5 * std
        let peaks = (1..<max(1, n - 1)).filter { i in
            novelty[i] > threshold && novelty[i] >= novelty[i - 1] && novelty[i] >= novelty[i + 1]
        }
        var chosen: [Int] = []
        for peak in peaks.sorted(by: { novelty[$0] > novelty[$1] }) {
            if chosen.allSatisfy({ abs($0 - peak) >= minimumBars }), peak >= 2, peak <= n - 2 { chosen.append(peak) }
        }
        return chosen.sorted()
    }

    /// Abschnitte, deren Takte entlang der Diagonale ähnlich verlaufen, bilden eine Familie.
    static func repeatFamilies(_ segments: [Range<Int>], ssm: [[Float]]) -> [Int] {
        var family = Array(segments.indices)
        func root(_ i: Int) -> Int { family[i] == i ? i : root(family[i]) }
        let offDiagonal = ssm.indices.flatMap { i in ssm.indices.filter { $0 != i }.map { ssm[i][$0] } }
        let mean = offDiagonal.isEmpty ? 0 : vDSP.mean(offDiagonal)
        let std = offDiagonal.isEmpty ? 1 : sqrt(max(0, vDSP.meanSquare(offDiagonal) - mean * mean))
        for i in segments.indices {
            for j in segments.indices where j > i {
                let a = segments[i]
                let b = segments[j]
                let length = min(a.count, b.count)
                guard length >= 2, Double(length) / Double(max(a.count, b.count)) >= 0.7 else { continue }
                var sum: Float = 0
                for k in 0..<length { sum += ssm[a.lowerBound + k][b.lowerBound + k] }
                if sum / Float(length) > mean + 1.0 * std {
                    family[root(j)] = root(i)
                }
            }
        }
        return segments.indices.map(root)
    }

    static func barEnergy(_ analysis: SongAnalysis, bars: [Double]) -> [Float] {
        guard !analysis.energy.isEmpty else { return [Float](repeating: 0.5, count: bars.count) }
        let bounds = bars + [analysis.duration]
        return zip(bounds, bounds.dropFirst()).map { start, end in
            let values = analysis.beats.indices.filter {
                analysis.beats[$0].time >= start && analysis.beats[$0].time < end
            }
            .compactMap { $0 < analysis.energy.count ? analysis.energy[$0] : nil }
            return values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
        }
    }

    static func label(
        _ segments: [Range<Int>], families: [Int], energy: [Float], bars: [Double], duration: Double
    ) -> [SongSection] {
        let members = Dictionary(grouping: segments.indices, by: { families[$0] })
        func meanEnergy(_ indices: [Int]) -> Float {
            let values = indices.flatMap { segments[$0].map { energy[$0] } }
            return values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
        }
        let repeated = members.filter { $0.value.count >= 2 }
        let chorus = repeated.max { meanEnergy($0.value) < meanEnergy($1.value) }?.key
        let songEnergy = meanEnergy(Array(segments.indices))
        var verseNumber = 0
        var sections: [SongSection] = []
        var firstOfFamily: [Int: String] = [:]
        for (index, segment) in segments.enumerated() {
            let id = "sec-\(index + 1)"
            let start = index == 0 ? 0 : bars[segment.lowerBound]
            let end = index == segments.count - 1 ? duration : bars[segment.upperBound]
            let family = families[index]
            let isRepeated = (members[family]?.count ?? 0) >= 2
            let kind: SongSection.Kind
            var label: String
            if family == chorus {
                kind = .chorus
                label = "Refrain"
            } else if isRepeated {
                kind = .verse
                if firstOfFamily[family] == nil { verseNumber += 1 }
                label = "Strophe"
            } else if index == 0, segments.count > 2, meanEnergy([index]) <= songEnergy {
                kind = .intro
                label = "Intro"
            } else if index == segments.count - 1, segments.count > 2 {
                kind = .outro
                label = "Outro"
            } else if meanEnergy([index]) < songEnergy * 0.8 {
                kind = .instrumental
                label = "Zwischenspiel"
            } else {
                kind = .bridge
                label = "Bridge"
            }
            if kind == .verse, verseNumber > 1 { label += " \(verseNumber == 2 ? "B" : "\(verseNumber)")" }
            let repeatOf = isRepeated ? firstOfFamily[family] : nil
            if isRepeated, firstOfFamily[family] == nil { firstOfFamily[family] = id }
            sections.append(
                SongSection(
                    id: id, kind: kind, label: label, start: start, end: end, repeatOf: repeatOf, needsReview: true))
        }
        return sections
    }
}

extension SongStructure {
    /// Abschnitte aus dem Songtext: je Block ein Abschnitt, Beginn auf dem Taktanfang vor dem ersten Wort.
    /// Überschriften wie „[Refrain]“ bestimmen den Typ; gleicher Text heißt Wiederholung. Längere Vorspiele und
    /// Nachspiele werden Intro bzw. Outro.
    public static func sections(
        lyrics: LyricsText, aligned: LyricsAligner.Result, analysis: SongAnalysis
    ) -> [SongSection] {
        let bars = barStarts(analysis)
        func snap(_ time: Double) -> Double {
            bars.last { $0 <= time + 0.15 } ?? time
        }
        var starts: [(block: Int, time: Double)] = []
        for (block, range) in aligned.blockLines.enumerated()
        where !range.isEmpty && range.lowerBound < aligned.lines.count {
            starts.append((block, snap(aligned.lines[range.lowerBound].start)))
        }
        guard !starts.isEmpty else { return [] }
        let texts = lyrics.blocks.map { $0.lines.map(WordMatching.normalize).joined(separator: " ") }
        var counts: [String: Int] = [:]
        for text in texts { counts[text, default: 0] += 1 }
        let mostRepeated = counts.filter { $0.value >= 2 }.max { $0.value < $1.value }?.key
        var sections: [SongSection] = []
        var firstWithText: [String: String] = [:]
        var verse = 0
        if let first = starts.first, first.time > 4 {
            sections.append(SongSection(id: "sec-intro", kind: .intro, label: "Intro", start: 0, end: first.time))
        }
        for (position, entry) in starts.enumerated() {
            let block = lyrics.blocks[entry.block]
            let text = texts[entry.block]
            let start = position == 0 && sections.isEmpty ? 0 : entry.time
            var end = position + 1 < starts.count ? starts[position + 1].time : analysis.duration
            let lastWord = aligned.lines[aligned.blockLines[entry.block].upperBound - 1].end
            let hasOutro = position + 1 == starts.count && analysis.duration - lastWord > 6
            if hasOutro { end = snap(lastWord + 1) > start ? max(snap(lastWord + 1), lastWord) : lastWord }
            var kind = block.label.map(SongSection.Kind.init(label:)) ?? .other
            var label = block.label ?? ""
            if block.label == nil {
                if text == mostRepeated {
                    kind = .chorus
                    label = "Refrain"
                } else {
                    kind = .verse
                    verse += 1
                    label = "Strophe \(verse)"
                }
            }
            let id = "sec-\(position + 1)"
            let repeatOf = (counts[text] ?? 0) >= 2 ? firstWithText[text] : nil
            if firstWithText[text] == nil { firstWithText[text] = id }
            if end > start {
                sections.append(
                    SongSection(id: id, kind: kind, label: label, start: start, end: end, repeatOf: repeatOf))
            }
            if hasOutro, end < analysis.duration {
                sections.append(
                    SongSection(id: "sec-outro", kind: .outro, label: "Outro", start: end, end: analysis.duration))
            }
        }
        return sections
    }
}
