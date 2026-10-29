import Foundation

// MARK: - Songtext

public struct SetLyrics: EditCommand {
    public var text: String
    public init(text: String) { self.text = text }

    public var actionName: String { "Songtext ändern" }

    public func apply(to project: inout Project) throws {
        project.lyricsText = text
    }
}

// MARK: - Beat-Raster

/// Grundlage aller Rasterbefehle: neue Beats setzen und verankerte Schnittpunkte mitführen.
extension Project {
    /// `oldToNewTime` gibt für einen alten Beat-Index die Zeit, an der er jetzt liegt; verankerte Schnittpunkte rasten
    /// auf den nächsten neuen Beat ein.
    mutating func replaceBeats(_ beats: [Beat], tempo: Double? = nil, oldToNewTime: (Int) -> Double) throws {
        guard var analysis else { throw EditError.invalidValue("Bitte zuerst den Song analysieren.") }
        let sorted = beats.filter { $0.time > 0 && $0.time < analysis.duration }.sorted { $0.time < $1.time }
        guard sorted.count >= 2 else { throw EditError.invalidValue("Das Raster braucht mindestens zwei Beats.") }
        let oldCount = analysis.beats.count
        analysis.beats = sorted
        if let tempo { analysis.tempo = tempo }
        if analysis.energy.count != sorted.count { analysis.energy = [] }
        self.analysis = analysis
        guard var cut else { return }
        func remap(_ point: CutPoint) -> CutPoint {
            guard case .beat(let index) = point.anchor, index < oldCount else { return point }
            let target = oldToNewTime(index)
            let nearest = sorted.indices.min { abs(sorted[$0].time - target) < abs(sorted[$1].time - target) }!
            return CutPoint(time: sorted[nearest].time, anchor: .beat(nearest))
        }
        for index in cut.shots.indices {
            cut.shots[index].start = remap(cut.shots[index].start)
            cut.shots[index].end = remap(cut.shots[index].end)
        }
        // Zusammengefallene Einstellungen entfallen; die Folge bleibt lückenlos.
        cut.shots.removeAll { $0.end.time <= $0.start.time }
        for index in cut.shots.indices.dropFirst() { cut.shots[index].start = cut.shots[index - 1].end }
        self.cut = cut
        // Einstellungen, für die das Material nicht mehr reicht, neu bestimmen (im selben Undo-Schritt).
        repairCut()
    }

    func requireAnalysis() throws -> SongAnalysis {
        guard let analysis else { throw EditError.invalidValue("Bitte zuerst den Song analysieren.") }
        return analysis
    }
}

/// Verschiebt das ganze Raster um einen festen Wert (Versatz-Regler).
public struct ShiftBeats: EditCommand {
    public var milliseconds: Double
    public init(milliseconds: Double) { self.milliseconds = milliseconds }

    public var actionName: String { "Raster verschieben" }

    public func apply(to project: inout Project) throws {
        guard milliseconds != 0 else { return }
        let analysis = try project.requireAnalysis()
        let delta = milliseconds / 1000
        let beats = analysis.beats.map {
            Beat(time: $0.time + delta, isDownbeat: $0.isDownbeat, confidence: $0.confidence)
        }
        try project.replaceBeats(beats) { analysis.beats[$0].time + delta }
    }
}

/// Tempo korrigieren: verdoppeln, halbieren oder für Triolengefühl ×¾ bzw. ×4⁄3.
public struct ScaleTempo: EditCommand {
    public enum Factor: String, Sendable, CaseIterable {
        case double, half, threeQuarters, fourThirds

        public var title: String {
            switch self {
            case .double: "Tempo ×2"
            case .half: "Tempo ÷2"
            case .threeQuarters: "Tempo ×¾"
            case .fourThirds: "Tempo ×4⁄3"
            }
        }

        var ratio: Double {
            switch self {
            case .double: 2
            case .half: 0.5
            case .threeQuarters: 0.75
            case .fourThirds: 4.0 / 3
            }
        }
    }

    public var factor: Factor
    public init(factor: Factor) { self.factor = factor }

    public var actionName: String { factor.title }

    public func apply(to project: inout Project) throws {
        let analysis = try project.requireAnalysis()
        let old = analysis.beats
        guard old.count >= 2 else { throw EditError.invalidValue("Zu wenige Beats.") }
        let meter = max(1, analysis.meter)
        let phase = old.firstIndex(where: \.isDownbeat) ?? 0
        // Zeit an einer (gebrochenen) Beat-Position, linear interpoliert bzw. am Rand fortgesetzt.
        func time(at position: Double) -> Double {
            let lower = min(max(0, Int(position.rounded(.down))), old.count - 2)
            let fraction = position - Double(lower)
            return old[lower].time + (old[lower + 1].time - old[lower].time) * fraction
        }
        let step = 1 / factor.ratio
        var positions: [Double] = []
        var position = Double(phase).truncatingRemainder(dividingBy: step)
        while position <= Double(old.count - 1) + 1e-9 {
            positions.append(position)
            position += step
        }
        // Der bisherige erste Taktanfang bleibt Taktanfang.
        let first = positions.firstIndex { abs($0 - Double(phase)) < step / 2 } ?? 0
        let marked = positions.enumerated().map { index, position in
            Beat(time: time(at: position), isDownbeat: ((index - first) % meter + meter) % meter == 0)
        }
        try project.replaceBeats(marked, tempo: analysis.tempo * factor.ratio) { old[$0].time }
    }
}

/// „Taktanfang hier“: Der gewählte Beat und jeder `meter`-te davor und danach werden Taktanfänge.
public struct SetDownbeat: EditCommand {
    public var beatIndex: Int
    public init(beatIndex: Int) { self.beatIndex = beatIndex }

    public var actionName: String { "Taktanfang setzen" }

    public func apply(to project: inout Project) throws {
        guard var analysis = project.analysis, analysis.beats.indices.contains(beatIndex) else {
            throw EditError.invalidValue("Diesen Beat gibt es nicht.")
        }
        let meter = max(1, analysis.meter)
        for index in analysis.beats.indices {
            analysis.beats[index].isDownbeat = ((index - beatIndex) % meter + meter) % meter == 0
        }
        project.analysis = analysis
    }
}

public struct SetMeter: EditCommand {
    public var meter: Int
    public init(meter: Int) { self.meter = meter }

    public var actionName: String { "Taktart ändern" }

    public func apply(to project: inout Project) throws {
        guard (2...12).contains(meter), var analysis = project.analysis else {
            throw EditError.invalidValue("Die Taktart muss 2 bis 12 Schläge haben.")
        }
        let first = analysis.beats.firstIndex(where: \.isDownbeat) ?? 0
        analysis.meter = meter
        for index in analysis.beats.indices {
            analysis.beats[index].isDownbeat = ((index - first) % meter + meter) % meter == 0
        }
        project.analysis = analysis
    }
}

public struct DeleteBeat: EditCommand {
    public var beatIndex: Int
    public init(beatIndex: Int) { self.beatIndex = beatIndex }

    public var actionName: String { "Beat löschen" }

    public func apply(to project: inout Project) throws {
        let analysis = try project.requireAnalysis()
        guard analysis.beats.indices.contains(beatIndex) else {
            throw EditError.invalidValue("Diesen Beat gibt es nicht.")
        }
        var beats = analysis.beats
        beats.remove(at: beatIndex)
        try project.replaceBeats(beats) { analysis.beats[$0].time }
    }
}

public struct InsertBeat: EditCommand {
    public var time: Double
    public init(time: Double) { self.time = time }

    public var actionName: String { "Beat einfügen" }

    public func apply(to project: inout Project) throws {
        let analysis = try project.requireAnalysis()
        guard time > 0, time < analysis.duration,
            !analysis.beats.contains(where: { abs($0.time - time) < 0.05 })
        else { throw EditError.invalidValue("Hier liegt schon ein Beat.") }
        try project.replaceBeats(analysis.beats + [Beat(time: time)]) { analysis.beats[$0].time }
    }
}

// MARK: - Abschnitte

extension Project {
    mutating func updateSections(_ change: (inout [SongSection]) throws -> Void) throws {
        var analysis = try requireAnalysis()
        try change(&analysis.sections)
        analysis.sections.sort { $0.start < $1.start }
        // Wiederholungen dürfen nur auf vorhandene, frühere Abschnitte zeigen.
        let ids = Set(analysis.sections.map(\.id))
        for index in analysis.sections.indices
        where analysis.sections[index].repeatOf.map({ !ids.contains($0) }) ?? false {
            analysis.sections[index].repeatOf = nil
        }
        self.analysis = analysis
    }
}

public struct SetSectionKind: EditCommand {
    public var sectionID: String
    public var kind: SongSection.Kind
    public var label: String
    public init(sectionID: String, kind: SongSection.Kind, label: String) {
        self.sectionID = sectionID
        self.kind = kind
        self.label = label
    }

    public var actionName: String { "Abschnittstyp ändern" }

    public func apply(to project: inout Project) throws {
        try project.updateSections { sections in
            guard let index = sections.firstIndex(where: { $0.id == sectionID }) else {
                throw EditError.invalidValue("Diesen Abschnitt gibt es nicht.")
            }
            sections[index].kind = kind
            sections[index].label = label
            sections[index].needsReview = false
        }
    }
}

public struct SetSectionRepeat: EditCommand {
    public var sectionID: String
    public var repeatOf: String?
    public init(sectionID: String, repeatOf: String?) {
        self.sectionID = sectionID
        self.repeatOf = repeatOf
    }

    public var actionName: String { repeatOf == nil ? "Wiederholung aufheben" : "Wiederholung festlegen" }

    public func apply(to project: inout Project) throws {
        try project.updateSections { sections in
            guard let index = sections.firstIndex(where: { $0.id == sectionID }) else {
                throw EditError.invalidValue("Diesen Abschnitt gibt es nicht.")
            }
            if let repeatOf {
                guard repeatOf != sectionID, let source = sections.first(where: { $0.id == repeatOf }),
                    source.start < sections[index].start
                else { throw EditError.invalidValue("Eine Wiederholung muss auf einen früheren Abschnitt zeigen.") }
                // Ketten auf den Ursprung zurückführen, damit keine Zyklen entstehen.
                sections[index].repeatOf = source.repeatOf ?? source.id
                sections[index].kind = source.kind
                sections[index].label = source.label
            } else {
                sections[index].repeatOf = nil
            }
            sections[index].needsReview = false
        }
    }
}

/// Verschiebt den Anfang eines Abschnitts (und damit das Ende des vorigen).
public struct MoveSectionBoundary: EditCommand {
    public var sectionID: String
    public var time: Double
    public init(sectionID: String, time: Double) {
        self.sectionID = sectionID
        self.time = time
    }

    public var actionName: String { "Abschnittsgrenze verschieben" }

    public func apply(to project: inout Project) throws {
        try project.updateSections { sections in
            guard let index = sections.firstIndex(where: { $0.id == sectionID }), index > 0 else {
                throw EditError.invalidValue("Der erste Abschnitt beginnt immer am Songanfang.")
            }
            guard time > sections[index - 1].start + 0.5, time < sections[index].end - 0.5 else {
                throw EditError.invalidValue("Ein Abschnitt muss mindestens eine halbe Sekunde lang bleiben.")
            }
            sections[index - 1].end = time
            sections[index].start = time
        }
    }
}

public struct SplitSection: EditCommand {
    public var time: Double
    public init(time: Double) { self.time = time }

    public var actionName: String { "Abschnitt teilen" }

    public func apply(to project: inout Project) throws {
        try project.updateSections { sections in
            guard let index = sections.firstIndex(where: { $0.start + 0.5 < time && time < $0.end - 0.5 }) else {
                throw EditError.invalidValue("Hier lässt sich kein Abschnitt teilen.")
            }
            var second = sections[index]
            let ids = Set(sections.map(\.id))
            var number = sections.count + 1
            while ids.contains("sec-\(number)") { number += 1 }
            second = SongSection(
                id: "sec-\(number)", kind: second.kind, label: second.label, start: time, end: second.end)
            sections[index].end = time
            sections.insert(second, at: index + 1)
        }
    }
}

public struct MergeSectionWithPrevious: EditCommand {
    public var sectionID: String
    public init(sectionID: String) { self.sectionID = sectionID }

    public var actionName: String { "Abschnitte verbinden" }

    public func apply(to project: inout Project) throws {
        try project.updateSections { sections in
            guard let index = sections.firstIndex(where: { $0.id == sectionID }), index > 0 else {
                throw EditError.invalidValue("Der erste Abschnitt hat keinen Vorgänger.")
            }
            sections[index - 1].end = sections[index].end
            let removed = sections.remove(at: index).id
            for i in sections.indices where sections[i].repeatOf == removed { sections[i].repeatOf = nil }
        }
    }
}

// MARK: - Text

public struct EditWord: EditCommand {
    public var wordID: String
    public var text: String
    public init(wordID: String, text: String) {
        self.wordID = wordID
        self.text = text
    }

    public var actionName: String { "Wort korrigieren" }

    public func apply(to project: inout Project) throws {
        var analysis = try project.requireAnalysis()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = analysis.words.firstIndex(where: { $0.id == wordID }) else {
            throw EditError.invalidValue("Das Wort darf nicht leer sein.")
        }
        analysis.words[index].text = trimmed
        // Ein korrigiertes Wort gilt als geprüft.
        analysis.words[index].confidence = 1
        analysis.words[index].estimated = false
        analysis.words[index].syllables = []
        for line in analysis.lines.indices where analysis.lines[line].wordIDs.contains(wordID) {
            let words = analysis.lines[line].wordIDs.compactMap { id in analysis.words.first { $0.id == id } }
            analysis.lines[line].text = words.map(\.text).joined(separator: " ")
            analysis.lines[line].needsReview = words.contains(where: \.isUncertain)
        }
        project.analysis = analysis
    }
}
