import Foundation

/// Ähnlichkeiten aus SigLIP 2: Textzeile ↔ Szene (`values`, nach Zeilen-ID) und Storyboard-Suchbegriffe eines
/// Abschnitts ↔ Szene (`sections`, nach Abschnitts-ID), jeweils nach Szenen-ID. Optional: ohne sie schneidet die
/// Engine nach Energie, Ästhetik und Abwechslung.
public struct TextScores: Sendable, Equatable {
    public var values: [String: [String: Float]]
    public var sections: [String: [String: Float]]

    public init(_ values: [String: [String: Float]] = [:], sections: [String: [String: Float]] = [:]) {
        self.values = values
        self.sections = sections
    }
}

/// Schritt 2 der Engine: Welche Szene in welchen Slot? Beam-Suche (Breite 16) über die jeweils 64 besten Kandidaten.
/// Harte Bedingungen: genug Quelllänge ab Quell-In (bei Wiederholungen für das längste Mitglied), ausgeschlossene
/// Clips tabu, fixierte Shots bleiben. Ergebnis inklusive Begründung und Alternativen je Shot.
public enum CutEngine {
    public enum Component: String, CaseIterable, Sendable {
        case text, story, energy, aesthetics, rating, shotSize, reuse, adjacent, sharpness, chance, chapter, continuity,
            watermark

        public var title: String {
            switch self {
            case .text: "Text ↔ Bild"
            case .story: "Storyboard"
            case .energy: "Energie ↔ Bewegung"
            case .aesthetics: "Ästhetik"
            case .rating: "Bewertung"
            case .shotSize: "Wechsel der Einstellungsgröße"
            case .reuse: "Wiederverwendung"
            case .adjacent: "Gleicher Clip direkt davor"
            case .sharpness: "Schärfe"
            case .chance: "Zufall (Neu würfeln)"
            case .chapter: "Kapitel"
            case .continuity: "Kontinuität"
            case .watermark: "Wasserzeichen"
            }
        }
    }

    static let beamWidth = 16
    static let candidatesPerSlot = 64
    /// Reserve für die Rundung auf Timeline- und Quellframes.
    static let margin = 0.1

    /// Anteile einer Bewertung als feste Felder: schneller als ein Dictionary, und die Summe läuft immer in derselben
    /// Reihenfolge (Gleitkomma-Addition hängt von der Reihenfolge ab).
    struct Scores: Equatable {
        var text = 0.0
        var story = 0.0
        var energy = 0.0
        var aesthetics = 0.0
        var rating = 0.0
        var shotSize = 0.0
        var reuse = 0.0
        var adjacent = 0.0
        var sharpness = 0.0
        var chance = 0.0
        var chapter = 0.0
        var continuity = 0.0
        var watermark = 0.0

        var total: Double {
            text + story + energy + aesthetics + rating + shotSize + reuse + adjacent + sharpness + chance + chapter
                + continuity + watermark
        }

        subscript(component: Component) -> Double {
            switch component {
            case .text: text
            case .story: story
            case .energy: energy
            case .aesthetics: aesthetics
            case .rating: rating
            case .shotSize: shotSize
            case .reuse: reuse
            case .adjacent: adjacent
            case .sharpness: sharpness
            case .chance: chance
            case .chapter: chapter
            case .continuity: continuity
            case .watermark: watermark
            }
        }

        /// Für die Begründung: nur Anteile, die etwas bewirken.
        var named: [String: Double] {
            var result: [String: Double] = [:]
            for component in Component.allCases where self[component] != 0 {
                result[component.rawValue] = self[component]
            }
            return result
        }
    }

    /// Eine Szene als Bildquelle: zusammenhängend bis zum nächsten echten Schnitt im Clip.
    struct Unit {
        var clipIndex: Int
        var clipID: String
        var sceneID: String
        var start: Double
        /// Ende der zusammenhängenden Einstellung (über 5-s-Teile hinweg).
        var end: Double
        var fps: Rational
        var available: Double
        var motion: Double
        var aesthetics: Double
        var sharpness: Double
        var utility: Bool
        var shotSize: ShotSize
        var rating: Int
        /// Kapitelindex der Geschichte.
        var chapter: Int?
        /// Stufe je aktivem Merkmal (`nil` = unbekannt).
        var traits: [Int?] = []
        /// Anteile, die nicht vom Slot abhängen.
        var fixed = Scores()

        var length: Double { end - start }
    }

    struct Candidate {
        var unit: Int
        var base: Double
        var scores: Scores
        /// Gelockerte Regeln (Materialmangel), z. B. „kapitel“.
        var relaxed: [String] = []
    }

    struct Pick {
        var unit: Int
        var sourceIn: Double
        var scores: Scores
        var total: Double
        var relaxed: [String] = []
    }

    /// Ein Pfad der Beam-Suche. Die Picks liegen als Rückverweise in einer gemeinsamen Liste, damit beim Verzweigen
    /// nicht der ganze bisherige Schnitt kopiert wird.
    struct Beam {
        var score: Double
        var node: Int
        var clipUses: [UInt16]
        var unitUses: [UInt16]
        /// Nächster Quell-In je benutzter Einheit (sonst Szenenanfang).
        var cursor: [Int: Double]
        /// Höchster Kapitelindex im laufenden Abschnitt (Fortschritt), −1 am Abschnittsanfang.
        var chapterFloor = -1
        /// Je aktivem Merkmal: höchste Stufe (fortlaufend) bzw. zuletzt gezeigte und im Abschnitt gesehene Stufen
        /// (blockweise).
        var traitFloor: [Int] = []
        var traitLast: [Int] = []
        var traitSeen: [UInt64] = []
    }

    struct Node {
        var pick: Pick
        var parent: Int
    }

    struct Expansion {
        var beam: Int
        var pick: Pick
        var score: Double
    }

    /// Erzeugt einen Schnitt. Shots in `keep` bleiben unverändert (fixierte und bei Teilneuberechnung alle anderen).
    public static func generate(
        _ project: Project, style: CutStyle, textScores: TextScores = TextScores(), keep: [Shot] = [],
        name: String? = nil
    ) -> Cut? {
        var slots = SlotPlanner.plan(project, style: style, keep: keep)
        guard !slots.isEmpty else { return nil }
        // Kopien einer fixierten Vorlage, für die deren Material nicht reicht, werden frei geschnitten.
        let available = Dictionary(
            project.clips.map { ($0.id, $0.meta.availableSeconds.doubleValue) }, uniquingKeysWith: { first, _ in first }
        )
        for index in slots.indices {
            guard case .copy(let from) = slots[index].role, case .locked(let template) = slots[from].role else {
                continue
            }
            if template.sourceIn.doubleValue + slots[index].duration + margin > available[template.clipID] ?? 0 {
                slots[index].role = .free
            }
        }
        let units = makeUnits(project)
        guard !units.isEmpty || slots.allSatisfy({ if case .locked = $0.role { true } else { false } }) else {
            return nil
        }
        // Benötigte Länge je Slot: bei Vorlagen das Maximum über alle Kopien.
        var need = slots.map { $0.duration }
        for slot in slots {
            if case .copy(let from) = slot.role { need[from] = max(need[from], slot.duration + 0.05) }
        }
        let text = gated(textScores.values, keys: Set(slots.compactMap(\.lineID)), units: units)
        let story = normalize(textScores.sections, keys: Set(slots.compactMap(\.sectionID)), units: units)
        let rules = StoryContext.make(project, slots: slots)
        let traits = project.story.traits.filter { $0.rule != .off }
        // Vorausschau für fortlaufende Merkmale: höchste Stufe, die alle späteren freien Slots mit ihrem erlaubten
        // Material noch zeigen können (unbekannte Stufen passen zu allem). Höher darf ein Slot nicht vorrücken, sonst
        // müsste die Geschichte später zurückspringen.
        var cap = Array(repeating: Array(repeating: Int.max, count: traits.count), count: slots.count)
        if traits.contains(where: { $0.rule == .progressive }),
            units.contains(where: { $0.traits.contains { $0 != nil } })
        {
            var running = Array(repeating: Int.max, count: traits.count)
            for slotIndex in slots.indices.reversed() {
                if case .free = slots[slotIndex].role {
                    let allowed = rules.allowed[slotIndex]
                    for (t, trait) in traits.enumerated()
                    where trait.rule == .progressive && rules.pinned[slotIndex][trait.id] == nil {
                        var best = -1
                        for unit in units where allowed == nil || unit.chapter.map({ allowed?[$0] != nil }) == true {
                            guard t < unit.traits.count, let level = unit.traits[t] else {
                                best = Int.max
                                break
                            }
                            best = max(best, level)
                        }
                        if best >= 0 { running[t] = min(running[t], best) }
                    }
                }
                cap[slotIndex] = running
            }
        }
        var nodes: [Node] = []
        nodes.reserveCapacity(slots.count * beamWidth)
        var beams = [
            Beam(
                score: 0, node: -1, clipUses: Array(repeating: 0, count: project.clips.count),
                unitUses: Array(repeating: 0, count: units.count), cursor: [:],
                traitFloor: Array(repeating: -1, count: traits.count),
                traitLast: Array(repeating: -1, count: traits.count),
                traitSeen: Array(repeating: 0, count: traits.count))
        ]
        /// Pick des Slots `index` auf dem Pfad, der in `node` endet.
        func pick(at index: Int, from node: Int, slot current: Int) -> Pick {
            var node = node
            for _ in 0..<(current - 1 - index) { node = nodes[node].parent }
            return nodes[node].pick
        }
        var alternatives: [[Candidate]] = Array(repeating: [], count: slots.count)
        for (slotIndex, slot) in slots.enumerated() {
            var best = TopK<Expansion>(capacity: beamWidth) { $0.score }
            switch slot.role {
            case .locked(let shot):
                let unit = units.firstIndex { $0.clipID == shot.clipID && $0.sceneID == shot.sceneID } ?? -1
                for (b, beam) in beams.enumerated() {
                    best.insert(
                        Expansion(
                            beam: b,
                            pick: Pick(unit: unit, sourceIn: shot.sourceIn.doubleValue, scores: Scores(), total: 0),
                            score: beam.score))
                }
            case .copy(let from):
                for (b, beam) in beams.enumerated() {
                    var copied = pick(at: from, from: beam.node, slot: slotIndex)
                    if style.refrainMode == .sameClips, copied.unit >= 0 {
                        let unit = units[copied.unit]
                        let cursor = beam.cursor[copied.unit] ?? unit.start
                        copied.sourceIn = cursor + slot.duration + margin <= unit.end ? cursor : unit.start
                    }
                    best.insert(Expansion(beam: b, pick: copied, score: beam.score))
                }
            case .free:
                let candidates = rankedCandidates(
                    slotIndex, slot, need: need[slotIndex], units: units, text: slot.lineID.flatMap { text[$0] },
                    story: slot.sectionID.flatMap { story[$0] }, seed: style.seed, allowed: rules.allowed[slotIndex])
                alternatives[slotIndex] = Array(candidates.prefix(9))
                // Erst streng (Fortschritt der Geschichte als Filter); findet kein Pfad einen Kandidaten, als Abschlag.
                for strict in [true, false] where strict || best.items.isEmpty {
                    for (b, beam) in beams.enumerated() {
                        let previous = beam.node >= 0 ? nodes[beam.node].pick.unit : -1
                        let previousUnit = previous >= 0 ? units[previous] : nil
                        let floor = rules.sectionStart[slotIndex] ? -1 : beam.chapterFloor
                        let progresses = rules.allowed[slotIndex] != nil && !rules.montage[slotIndex]
                        for candidate in candidates {
                            let unit = units[candidate.unit]
                            var scores = candidate.scores
                            var relaxed = candidate.relaxed
                            if progresses, let chapter = unit.chapter, chapter < floor {
                                if strict { continue }
                                scores.chapter -= 1.5
                                if !relaxed.contains("kapitel") { relaxed.append("kapitel") }
                            }
                            // Merkmale: festgelegt (genau dieser Wert), fortlaufend (nie zurück), blockweise (kein Zurückwechseln im
                            // Abschnitt, nur Abschlag). Unbekannte Werte sind neutral.
                            var violates = false
                            for (t, trait) in traits.enumerated() {
                                guard t < unit.traits.count, let level = unit.traits[t] else { continue }
                                if let pin = rules.pinned[slotIndex][trait.id] {
                                    if level != pin {
                                        violates = true
                                        scores.continuity -= 3
                                        if !relaxed.contains(trait.id) { relaxed.append(trait.id) }
                                    }
                                    continue
                                }
                                switch trait.rule {
                                case .progressive where level < beam.traitFloor[t] || level > cap[slotIndex][t]:
                                    violates = true
                                    scores.continuity -= 3
                                    if !relaxed.contains(trait.id) { relaxed.append(trait.id) }
                                case .blockwise
                                where !rules.sectionStart[slotIndex] && level != beam.traitLast[t]
                                    && beam.traitSeen[t] & (1 << UInt64(min(level, 63))) != 0:
                                    scores.continuity -= 0.8
                                default: break
                                }
                            }
                            if violates && strict { continue }
                            scores.reuse =
                                -0.35 * Double(beam.clipUses[unit.clipIndex]) - 0.8
                                * Double(beam.unitUses[candidate.unit])
                            scores.adjacent = previousUnit?.clipID == unit.clipID && units.count > 1 ? -2 : 0
                            scores.shotSize = previousUnit.map { $0.shotSize != unit.shotSize ? 0.15 : 0 } ?? 0
                            let total = scores.total
                            let score = beam.score + total
                            guard best.accepts(score) else { continue }
                            let cursor = beam.cursor[candidate.unit] ?? unit.start
                            let sourceIn = cursor + need[slotIndex] + margin <= unit.end ? cursor : unit.start
                            best.insert(
                                Expansion(
                                    beam: b,
                                    pick: Pick(
                                        unit: candidate.unit, sourceIn: sourceIn, scores: scores, total: total,
                                        relaxed: relaxed),
                                    score: score))
                        }
                    }
                }
            }
            // Zustände der Elternpfade übernehmen; nur wer mehrere Kinder hat, wird kopiert.
            var children = Array(repeating: 0, count: beams.count)
            for expansion in best.items { children[expansion.beam] += 1 }
            var next: [Beam] = []
            next.reserveCapacity(best.items.count)
            for expansion in best.items {
                var beam: Beam
                children[expansion.beam] -= 1
                if children[expansion.beam] == 0 {
                    beam = beams[expansion.beam]
                    beams[expansion.beam] = Beam(score: 0, node: -1, clipUses: [], unitUses: [], cursor: [:])
                } else {
                    beam = beams[expansion.beam]
                }
                let pick = expansion.pick
                if rules.sectionStart[slotIndex] { beam.chapterFloor = -1 }
                if case .free = slot.role, rules.allowed[slotIndex] != nil, !rules.montage[slotIndex], pick.unit >= 0,
                    let chapter = units[pick.unit].chapter
                {
                    beam.chapterFloor = max(beam.chapterFloor, chapter)
                }
                for (t, trait) in traits.enumerated() {
                    if rules.sectionStart[slotIndex] {
                        beam.traitLast[t] = -1
                        beam.traitSeen[t] = 0
                    }
                    guard case .free = slot.role, pick.unit >= 0, t < units[pick.unit].traits.count,
                        let level = units[pick.unit].traits[t]
                    else { continue }
                    if trait.rule == .progressive, rules.pinned[slotIndex][trait.id] == nil,
                        !pick.relaxed.contains(trait.id)
                    {
                        beam.traitFloor[t] = max(beam.traitFloor[t], level)
                    }
                    if trait.rule == .blockwise {
                        beam.traitLast[t] = level
                        beam.traitSeen[t] |= 1 << UInt64(min(level, 63))
                    }
                }
                nodes.append(Node(pick: pick, parent: beam.node))
                beam.node = nodes.count - 1
                beam.score = expansion.score
                if pick.unit >= 0 {
                    let unit = units[pick.unit]
                    beam.clipUses[unit.clipIndex] &+= 1
                    beam.unitUses[pick.unit] &+= 1
                    let end = pick.sourceIn + slot.duration
                    beam.cursor[pick.unit] = end + 0.5 <= unit.end ? end : unit.start
                }
                next.append(beam)
            }
            beams = next
            guard !beams.isEmpty else { return nil }
        }
        // Besten Pfad von hinten nach vorn einsammeln.
        var picks: [Pick] = []
        picks.reserveCapacity(slots.count)
        var node = beams[0].node
        while node >= 0 {
            picks.append(nodes[node].pick)
            node = nodes[node].parent
        }
        picks.reverse()
        // Behaltene Shots bekommen neue IDs; ihr Verweis auf eine Vorlage bleibt nur, wenn die Vorlage mitkommt.
        var keptIDs: [String: String] = [:]
        for (index, slot) in slots.enumerated() {
            if case .locked(let shot) = slot.role { keptIDs[shot.id] = "shot-\(index + 1)" }
        }
        var shots: [Shot] = []
        for (index, slot) in slots.enumerated() {
            let pick = picks[index]
            if case .locked(let shot) = slot.role {
                var reasons = shot.reasons
                reasons?.copiedFrom = shot.reasons?.copiedFrom.flatMap { keptIDs[$0] }
                shots.append(
                    Shot(
                        id: "shot-\(index + 1)", start: shot.start, end: shot.end, clipID: shot.clipID,
                        sceneID: shot.sceneID, sourceIn: shot.sourceIn, locked: shot.locked, reasons: reasons))
                continue
            }
            if case .copy(let from) = slot.role, case .locked(let template) = slots[from].role {
                shots.append(
                    Shot(
                        id: "shot-\(index + 1)", start: slot.start, end: slot.end, clipID: template.clipID,
                        sceneID: template.sceneID, sourceIn: template.sourceIn,
                        reasons: ShotReasons(
                            components: [:], total: 0, alternatives: [], copiedFrom: "shot-\(from + 1)")))
                continue
            }
            guard pick.unit >= 0 else { return nil }
            let unit = units[pick.unit]
            // Abrunden auf Millisekunden: nie später als geplant, damit die Quelllänge reicht.
            let sourceIn = Rational(seconds: (pick.sourceIn * 1000).rounded(.down) / 1000)
            var copiedFrom: String?
            if case .copy(let from) = slot.role { copiedFrom = "shot-\(from + 1)" }
            let others = alternatives[index].filter { $0.unit != pick.unit }.prefix(8).map { candidate in
                ShotReasons.Alternative(
                    clipID: units[candidate.unit].clipID, sceneID: units[candidate.unit].sceneID,
                    sourceIn: Rational(seconds: (units[candidate.unit].start * 1000).rounded() / 1000),
                    score: candidate.base)
            }
            shots.append(
                Shot(
                    id: "shot-\(index + 1)", start: slot.start, end: slot.end, clipID: unit.clipID,
                    sceneID: unit.sceneID, sourceIn: sourceIn,
                    reasons: ShotReasons(
                        components: pick.scores.named, total: pick.total, alternatives: Array(others),
                        copiedFrom: copiedFrom, relaxed: pick.relaxed)))
        }
        return Cut(
            id: "cut-\(style.seed)", name: name ?? "\(style.preset.title) · \(style.seed)", seed: style.seed,
            origin: .engine, shots: shots)
    }

    /// Alle nutzbaren Szenen: nicht ausgeschlossen, analysiert, ohne nötige Arbeitskopie.
    static func makeUnits(_ project: Project) -> [Unit] {
        var units: [Unit] = []
        let allSharpness = project.clips.flatMap { $0.scenes.compactMap { $0.features?.sharpness } }.sorted()
        let allMotion = project.clips.flatMap { $0.scenes.compactMap { $0.features?.motion } }.sorted()
        /// Anteil der Werte unterhalb (binäre Suche über die sortierte Liste).
        func percentile(_ value: Double, _ sorted: [Double]) -> Double {
            guard !sorted.isEmpty else { return 0.5 }
            var low = 0
            var high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid] < value { low = mid + 1 } else { high = mid }
            }
            return Double(low) / Double(sorted.count)
        }
        let chapterIndex = Dictionary(
            project.story.chapters.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let traits = project.story.traits.filter { $0.rule != .off }
        let resolved = StoryResolver.resolve(project)
        for (clipIndex, clip) in project.clips.enumerated() {
            guard !clip.excluded, !clip.meta.needsConversion, clip.meta.duration > 0, !clip.scenes.isEmpty else {
                continue
            }
            let available = clip.meta.availableSeconds.doubleValue
            for (index, scene) in clip.scenes.enumerated() {
                // Zusammenhängend bis zum nächsten echten Schnitt.
                var end = scene.end
                var next = index + 1
                while next < clip.scenes.count, clip.scenes[next].continuesPrevious {
                    end = clip.scenes[next].end
                    next += 1
                }
                let features = scene.features
                // Sperrbereiche zerlegen die Einheit; Stücke, die erst in einer späteren Szene beginnen, gehören zu
                // deren eigener Einheit.
                let pieces =
                    clip.blocked.isEmpty
                    ? [scene.start...min(end, available)]
                    : usableIntervals(
                        start: scene.start, end: min(end, available), blocked: clip.blocked,
                        margin: 1 / clip.meta.fps.doubleValue, minimum: 0.2
                    )
                    .filter { $0.lowerBound < scene.end }
                for piece in pieces where piece.upperBound > piece.lowerBound {
                    var unit = Unit(
                        clipIndex: clipIndex, clipID: clip.id, sceneID: scene.id, start: piece.lowerBound,
                        end: piece.upperBound, fps: clip.meta.fps, available: available,
                        motion: percentile(features?.motion ?? 0, allMotion),
                        aesthetics: features?.aesthetics ?? 0,
                        sharpness: percentile(features?.sharpness ?? 0, allSharpness),
                        utility: features?.isUtility ?? false, shotSize: features?.shotSize ?? .wide,
                        rating: clip.rating ?? 0, chapter: clip.chapterID.flatMap { chapterIndex[$0] },
                        traits: traits.map { resolved[clip.id]?.traitLevels[$0.id] })
                    unit.fixed.aesthetics = 0.4 * (unit.aesthetics + 1) / 2 - (unit.utility ? 1.5 : 0)
                    unit.fixed.sharpness = unit.sharpness < 0.15 ? -0.4 : 0
                    unit.fixed.rating = unit.rating > 0 ? 0.15 * Double(unit.rating - 3) : 0
                    units.append(unit)
                }
            }
        }
        return units
    }

    /// Teile von `[start, end]` ohne Sperrbereiche (mit `margin` Abstand), jeweils mindestens `minimum` lang.
    static func usableIntervals(
        start: Double, end: Double, blocked: [SourceRange], margin: Double, minimum: Double
    ) -> [ClosedRange<Double>] {
        var pieces: [ClosedRange<Double>] = start < end ? [start...end] : []
        for range in blocked.sorted(by: { $0.start < $1.start }) {
            let from = range.start - margin
            let to = range.end + margin
            pieces = pieces.flatMap { piece -> [ClosedRange<Double>] in
                guard from < piece.upperBound, to > piece.lowerBound else { return [piece] }
                var rest: [ClosedRange<Double>] = []
                if from > piece.lowerBound { rest.append(piece.lowerBound...from) }
                if to < piece.upperBound { rest.append(to...piece.upperBound) }
                return rest
            }
        }
        return pieces.filter { $0.upperBound - $0.lowerBound >= minimum }
    }

    /// Nur klare Text-Treffer: Szenen über dem 90. Perzentil, skaliert mit der Sicherheit der Zeile. Abstrakte Zeilen
    /// (kein Ausreißer) wirken so kaum; im Spike stieg die Zeilentreue gegenüber dem Strecken auf 0…1.
    public static func gate(_ row: [String: Float]) -> [String: Double] {
        guard let (p90, span, confidence) = gateParameters(row) else { return [:] }
        return row.mapValues { Double(min(1, max(0, ($0 - p90) / span))) * confidence }
    }

    /// Sicherheit einer Zeile: wie weit der beste Treffer über dem 90. Perzentil liegt (ab 0,03 voll).
    public static func gateConfidence(_ row: [String: Float]) -> Double {
        gateParameters(row)?.confidence ?? 0
    }

    static func gateParameters(_ row: [String: Float]) -> (p90: Float, span: Float, confidence: Double)? {
        let sorted = row.values.sorted()
        guard let top = sorted.last else { return nil }
        let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
        return (p90, max(0.03, top - p90), Double(min(1, max(0, (top - p90) / 0.03))))
    }

    /// Text-Ähnlichkeiten je Zeile nach `gate`, als Liste je Einheit.
    static func gated(_ scores: [String: [String: Float]], keys: Set<String>, units: [Unit]) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        for key in keys {
            guard let row = scores[key], !row.isEmpty else { continue }
            let values = gate(row)
            result[key] = units.map { values[$0.sceneID] ?? 0 }
        }
        return result
    }

    /// Ähnlichkeiten je Zeile bzw. Abschnitt auf 0…1 normieren (SigLIP-Werte liegen dicht beieinander), als Liste
    /// je Einheit.
    static func normalize(_ scores: [String: [String: Float]], keys: Set<String>, units: [Unit]) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        for key in keys {
            guard let row = scores[key], let low = row.values.min(), let high = row.values.max(), high > low
            else { continue }
            result[key] = units.map { unit in row[unit.sceneID].map { Double(($0 - low) / (high - low)) } ?? 0 }
        }
        return result
    }

    /// Die besten Einheiten für einen Slot nach festen Anteilen (ohne Wiederverwendung und Nachbarschaft).
    static func rankedCandidates(
        _ slotIndex: Int, _ slot: Slot, need: Double, units: [Unit], text: [Double]?, story: [Double]?, seed: UInt64,
        allowed: [Int: ChapterRole]? = nil
    ) -> [Candidate] {
        let prefix = SeededRandom.mix(SeededRandom.mix(SeededRandom.basis, seed), UInt64(slotIndex))
        // Mit Drehbuch nur erlaubte Kapitel; reicht deren Material nicht, alle mit Abschlag (Ausweichen).
        for strict in [true, false] where strict || allowed != nil {
            var top = TopK<Candidate>(capacity: candidatesPerSlot) { $0.base }
            for (index, unit) in units.enumerated() where unit.length >= need + margin {
                var random = SeededRandom(seed: SeededRandom.mix(SeededRandom.mix(prefix, UInt64(index)), 0xC0FFEE))
                var scores = unit.fixed
                var relaxed: [String] = []
                if let allowed {
                    if let role = unit.chapter.flatMap({ allowed[$0] }) {
                        scores.chapter = role == .main ? 1.5 : 0.6
                    } else if strict {
                        continue
                    } else {
                        scores.chapter = -1.5
                        relaxed = ["kapitel"]
                    }
                }
                if let text { scores.text = 1.2 * text[index] }
                if let story { scores.story = 1.0 * story[index] }
                scores.energy = 0.6 * (1 - abs(unit.motion - slot.energy))
                scores.chance = 0.5 * (random.unit() - 0.5)
                let base = scores.total
                guard top.accepts(base) else { continue }
                top.insert(Candidate(unit: index, base: base, scores: scores, relaxed: relaxed))
            }
            if !top.items.isEmpty || !strict || allowed == nil { return top.items }
        }
        return []
    }
}

/// Die besten `capacity` Elemente nach Punktzahl, absteigend; bei Gleichstand gewinnt das früher eingefügte (stabil,
/// damit gleicher Seed gleiches Ergebnis heißt).
struct TopK<Element> {
    let capacity: Int
    let score: (Element) -> Double
    private(set) var items: [Element] = []

    init(capacity: Int, score: @escaping (Element) -> Double) {
        self.capacity = capacity
        self.score = score
        items.reserveCapacity(capacity + 1)
    }

    /// Vorfilter: Ist die Liste voll, muss ein neues Element echt besser sein als das schlechteste.
    func accepts(_ value: Double) -> Bool { items.count < capacity || value > score(items[items.count - 1]) }

    mutating func insert(_ element: Element) {
        let value = score(element)
        guard accepts(value) else { return }
        // Erste Position mit echt schlechterem Element; gleich gute bleiben davor.
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if score(items[mid]) < value { high = mid } else { low = mid + 1 }
        }
        items.insert(element, at: low)
        if items.count > capacity { items.removeLast() }
    }
}
