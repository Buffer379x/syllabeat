import Foundation

/// Deterministischer Zufall (SplitMix64): gleicher Seed, gleiches Ergebnis – auf jedem Mac.
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    public init(_ parts: [UInt64]) {
        self.init(seed: parts.reduce(Self.basis, Self.mix))
    }

    /// Startwert und Schritt von FNV-1a: `mix(mix(basis, a), b)` ergibt denselben Seed wie `init([a, b])`, ohne Array.
    public static let basis: UInt64 = 0xCBF2_9CE4_8422_2325

    public static func mix(_ value: UInt64, _ part: UInt64) -> UInt64 {
        (value ^ part) &* 0x0000_0100_0000_01B3
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Gleichverteilt in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Stabiler Hash eines Textes (FNV-1a), unabhängig vom Prozess (anders als `hashValue`).
    public static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(basis) { mix($0, UInt64($1)) }
    }
}

/// Ein Zeitfenster für einen künftigen Shot.
public struct Slot: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case free
        /// Wiederholung: übernimmt den Shot des Slots mit diesem Index.
        case copy(of: Int)
        /// Fixierter Shot aus dem bisherigen Schnitt.
        case locked(Shot)
    }

    public var start: CutPoint
    public var end: CutPoint
    public var sectionID: String?
    /// Mittlere Songenergie im Slot, 0…1.
    public var energy: Double
    /// Textzeile, die den Slot am stärksten überdeckt.
    public var lineID: String?
    public var role: Role

    public var duration: Double { end.time - start.time }
}

/// Schritt 1 der Engine: Wo wird geschnitten? Kandidaten sind Beats (Taktanfänge bevorzugt), Wortanfänge nahe am
/// Beat und Abschnittsgrenzen. Wiederholungen übernehmen das Muster ihrer Vorlage; fixierte Shots bleiben stehen.
public enum SlotPlanner {
    public static let maximumShot = 8.0

    public static func plan(_ project: Project, style: CutStyle, keep fixed: [Shot] = []) -> [Slot] {
        guard let analysis = project.analysis, analysis.duration > 0 else { return [] }
        let beats = analysis.beats.map(\.time)
        let duration = analysis.duration
        let sections = normalizedSections(analysis)
        // Höchstdauer: 8 s, begrenzt durch die längste zusammenhängende Einstellung (Reserve für Wortanfänge).
        let longest = CutEngine.makeUnits(project).map { $0.end - $0.start }.max() ?? maximumShot
        let maximum = max(style.minimumDuration, min(maximumShot, longest - 0.15))
        var points: [CutPoint] = [CutPoint(time: 0, anchor: .songStart)]
        var boundaries: Set<Double> = []
        var templates: [String: (startBeat: Int, offsets: [Int])] = [:]
        for section in sections {
            let range = beatRange(beats, from: section.start, to: section.end)
            let startPoint = boundaryPoint(section, beats: beats)
            if section.start > 0, startPoint.time > points.last!.time {
                points.append(startPoint)
                boundaries.insert(startPoint.time)
            }
            var interior: [Int] = []
            let source = section.repeatOf.flatMap { templates[$0] }
            if style.refrainMode != .free, let source, let copied = copiedOffsets(source, into: range, beats: beats) {
                interior = copied
            } else {
                interior = generate(section, range: range, beats: beats, analysis: analysis, style: style)
            }
            if section.repeatOf == nil {
                templates[section.id] = (range.lowerBound, interior.map { $0 - range.lowerBound })
            }
            for index in interior where beats[index] > points.last!.time {
                points.append(CutPoint(time: beats[index], anchor: .beat(index)))
            }
        }
        points.append(CutPoint(time: duration, anchor: .songEnd))
        points = enforceDurations(
            points, beats: beats, minimum: style.minimumDuration, maximum: maximum, mandatory: boundaries)
        if style.alignToWords { points = alignToWords(points, words: analysis.words, minimum: style.minimumDuration) }
        points = insertFixed(points, fixed: fixed, minimum: style.minimumDuration)
        return slots(points, analysis: analysis, sections: sections, fixed: fixed, style: style)
    }

    /// Abschnitte lückenlos über den ganzen Song; ohne Abschnitte ein einziger.
    static func normalizedSections(_ analysis: SongAnalysis) -> [SongSection] {
        let sorted = analysis.sections.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else {
            return [SongSection(id: "song", kind: .verse, label: "Song", start: 0, end: analysis.duration)]
        }
        var result = sorted
        result[0].start = 0
        result[result.count - 1].end = analysis.duration
        return result
    }

    /// Indizes der Beats in [start, end).
    static func beatRange(_ beats: [Double], from start: Double, to end: Double) -> Range<Int> {
        let lower = beats.firstIndex { $0 >= start - 0.05 } ?? beats.count
        let upper = beats.firstIndex { $0 >= end - 0.05 } ?? beats.count
        return lower..<max(lower, upper)
    }

    /// Abschnittsgrenze: auf einem Beat, wenn einer innerhalb von 50 ms liegt, sonst am Abschnitt verankert.
    static func boundaryPoint(_ section: SongSection, beats: [Double]) -> CutPoint {
        if let index = beats.indices.min(by: { abs(beats[$0] - section.start) < abs(beats[$1] - section.start) }),
            abs(beats[index] - section.start) <= 0.05
        {
            return CutPoint(time: beats[index], anchor: .beat(index))
        }
        return CutPoint(time: section.start, anchor: .section(section.id))
    }

    /// Innere Schnitte eines Abschnitts als Beat-Indizes.
    static func generate(
        _ section: SongSection, range: Range<Int>, beats: [Double], analysis: SongAnalysis, style: CutStyle
    ) -> [Int] {
        guard range.count > 1 else { return [] }
        var random = SeededRandom([style.seed, SeededRandom.hash(section.id), 0x51_07])
        let chorus = section.kind == .chorus
        let base = Double(chorus && style.chorusFaster ? style.chorusBeats : style.verseBeats)
        let energies = range.compactMap { $0 < analysis.energy.count ? Double(analysis.energy[$0]) : nil }
        let energy = energies.isEmpty ? 0.5 : energies.reduce(0, +) / Double(energies.count)
        let scale = 1 + style.followEnergy * (0.5 - energy)
        let meter = max(1, analysis.meter)
        var result: [Int] = []
        var index = range.lowerBound
        while true {
            let length = max(1, Int((base * scale * variation(style.variation, &random)).rounded()))
            var next = index + length
            // Längere Shots enden bevorzugt auf einem Taktanfang.
            if length >= meter, meter > 1 {
                let window = (next - 1)...(next + 1)
                if let downbeat = window.first(where: { $0 < analysis.beats.count && analysis.beats[$0].isDownbeat }) {
                    next = downbeat
                }
            }
            guard next < range.upperBound, next > index else { break }
            result.append(next)
            index = next
        }
        return result
    }

    /// Faktor auf die Ziellänge: gering = fest, mittel = ½/1/2, hoch = breit gestreut.
    static func variation(_ variation: CutStyle.Variation, _ random: inout SeededRandom) -> Double {
        let roll = random.unit()
        switch variation {
        case .low: return 1
        case .medium: return roll < 0.2 ? 0.5 : roll < 0.85 ? 1 : 2
        case .high: return roll < 0.25 ? 0.5 : roll < 0.6 ? 1 : roll < 0.85 ? 1.5 : 2
        }
    }

    /// Muster der Vorlage auf die Wiederholung übertragen; bei anderer Beatzahl frei (nil).
    static func copiedOffsets(
        _ template: (startBeat: Int, offsets: [Int]), into range: Range<Int>, beats: [Double]
    )
        -> [Int]?
    {
        let mapped = template.offsets.map { range.lowerBound + $0 }
        guard mapped.allSatisfy({ range.contains($0) }) else { return nil }
        return mapped
    }

    /// Mindestdauer durch Verschmelzen, Höchstdauer durch Teilen an Beats. Abschnittsgrenzen (`mandatory`) sind
    /// Pflichtschnitte: Liegt ein gewöhnlicher Schnitt zu nah davor, entfällt dieser statt der Grenze.
    static func enforceDurations(
        _ points: [CutPoint], beats: [Double], minimum: Double, maximum: Double, mandatory: Set<Double> = []
    ) -> [CutPoint] {
        var result: [CutPoint] = [points[0]]
        for point in points.dropFirst() {
            if point.time - result.last!.time >= minimum {
                result.append(point)
            } else if point.anchor == .songEnd || mandatory.contains(point.time) {
                // Zu kurzer Rest: den vorigen gewöhnlichen Schnitt ersetzen (am Songende auch eine Grenze).
                let previousIsFixed = mandatory.contains(result.last!.time) && point.anchor != .songEnd
                if result.count > 1, !previousIsFixed {
                    result[result.count - 1] = point
                } else {
                    result.append(point)
                }
            }
        }
        var split: [CutPoint] = [result[0]]
        for point in result.dropFirst() {
            var start = split.last!.time
            while point.time - start > maximum {
                let target = start + (point.time - start) / ceil((point.time - start) / maximum)
                guard
                    let index = beats.indices.filter({ beats[$0] > start + minimum && beats[$0] < point.time - minimum }
                    )
                    .min(by: { abs(beats[$0] - target) < abs(beats[$1] - target) })
                else { break }
                split.append(CutPoint(time: beats[index], anchor: .beat(index)))
                start = beats[index]
            }
            split.append(point)
        }
        return split
    }

    /// Schnitte auf Wortanfänge legen, wenn ein Wort höchstens 80 ms neben dem Beat beginnt.
    static func alignToWords(_ points: [CutPoint], words: [Word], minimum: Double) -> [CutPoint] {
        guard !words.isEmpty else { return points }
        var result = points
        for index in result.indices.dropFirst().dropLast() {
            guard case .beat = result[index].anchor else { continue }
            let time = result[index].time
            guard
                let word = words.filter({ !$0.isUncertain && abs($0.start - time) <= 0.08 })
                    .min(by: { abs($0.start - time) < abs($1.start - time) })
            else { continue }
            let previous = result[index - 1].time
            let next = result[index + 1].time
            if word.start - previous >= minimum, next - word.start >= minimum {
                result[index] = CutPoint(time: word.start, anchor: .word(word.id))
            }
        }
        return result
    }

    /// Fixierte Shots: ihre Grenzen bleiben, Schnitte in ihnen entfallen, zu nahe Nachbarn verschmelzen.
    static func insertFixed(_ points: [CutPoint], fixed: [Shot], minimum: Double) -> [CutPoint] {
        guard !fixed.isEmpty else { return points }
        var result = points.filter { point in
            !fixed.contains { shot in point.time > shot.start.time - 1e-9 && point.time < shot.end.time + 1e-9 }
                || point.anchor == .songStart || point.anchor == .songEnd
        }
        for shot in fixed {
            result.append(shot.start)
            result.append(shot.end)
        }
        result.sort { $0.time < $1.time }
        var unique: [CutPoint] = []
        for point in result where unique.last.map({ abs($0.time - point.time) > 1e-6 }) ?? true {
            unique.append(point)
        }
        // Freie Reste unter der Mindestdauer neben fixierten Shots dem freien Nachbarn zuschlagen.
        let bounds = Set(fixed.flatMap { [$0.start.time, $0.end.time] })
        var cleaned: [CutPoint] = [unique[0]]
        for point in unique.dropFirst() {
            let gap = point.time - cleaned.last!.time
            let isFixed = bounds.contains(point.time) || point.anchor == .songEnd
            if gap < minimum, !isFixed, cleaned.count > 1 { continue }
            if gap < minimum, isFixed, cleaned.count > 1, !bounds.contains(cleaned.last!.time) {
                cleaned.removeLast()
            }
            cleaned.append(point)
        }
        return cleaned
    }

    static func slots(
        _ points: [CutPoint], analysis: SongAnalysis, sections: [SongSection], fixed: [Shot], style: CutStyle
    ) -> [Slot] {
        var slots: [Slot] = []
        var templateSlots: [String: [Int]] = [:]
        for (start, end) in zip(points, points.dropFirst()) where end.time > start.time {
            let middle = (start.time + end.time) / 2
            let section = sections.first { $0.start <= middle && middle < $0.end } ?? sections.last
            let beatIndices = analysis.beats.indices.filter {
                analysis.beats[$0].time >= start.time && analysis.beats[$0].time < end.time
            }
            let energies = beatIndices.compactMap { $0 < analysis.energy.count ? Double(analysis.energy[$0]) : nil }
            let line = analysis.lines.max { a, b in
                overlap(a, start.time, end.time) < overlap(b, start.time, end.time)
            }.flatMap { overlap($0, start.time, end.time) > 0 ? $0.id : nil }
            var role = Slot.Role.free
            if let shot = fixed.first(where: {
                abs($0.start.time - start.time) < 1e-6 && abs($0.end.time - end.time) < 1e-6
            }) {
                role = .locked(shot)
            }
            slots.append(
                Slot(
                    start: start, end: end, sectionID: section?.id,
                    energy: energies.isEmpty ? 0.5 : energies.reduce(0, +) / Double(energies.count), lineID: line,
                    role: role))
            if let id = section?.id { templateSlots[id, default: []].append(slots.count - 1) }
        }
        // Wiederholungen mit gleichem Muster übernehmen die Shots ihrer Vorlage. Weicht ein einzelner Slot ab (z. B.
        // der letzte, weil ein kurzes Outro angehängt wurde), wird nur er frei geschnitten.
        guard style.refrainMode != .free else { return slots }
        for section in sections {
            guard let source = section.repeatOf, let template = templateSlots[source],
                let copies = templateSlots[section.id], template.count == copies.count
            else { continue }
            for (from, to) in zip(template, copies)
            where slots[to].role == .free && abs(slots[from].duration - slots[to].duration) < 0.25 {
                slots[to].role = .copy(of: from)
            }
        }
        return slots
    }

    static func overlap(_ line: LyricLine, _ start: Double, _ end: Double) -> Double {
        max(0, min(line.end, end) - max(line.start, start))
    }
}
