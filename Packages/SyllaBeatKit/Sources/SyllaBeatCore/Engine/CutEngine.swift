import Foundation

/// Ähnlichkeit zwischen Textzeilen und Szenen (SigLIP 2), nach Zeilen-ID und Szenen-ID. Optional: ohne sie schneidet
/// die Engine nach Energie, Ästhetik und Abwechslung.
public struct TextScores: Sendable, Equatable {
    public var values: [String: [String: Float]]

    public init(_ values: [String: [String: Float]] = [:]) {
        self.values = values
    }
}

/// Schritt 2 der Engine: Welche Szene in welchen Slot? Beam-Suche (Breite 16) über die jeweils 64 besten Kandidaten.
/// Harte Bedingungen: genug Quelllänge ab Quell-In (bei Wiederholungen für das längste Mitglied), ausgeschlossene
/// Clips tabu, fixierte Shots bleiben. Ergebnis inklusive Begründung und Alternativen je Shot.
public enum CutEngine {
    public enum Component: String, CaseIterable, Sendable {
        case text, energy, aesthetics, rating, shotSize, reuse, adjacent, sharpness, chance

        public var title: String {
            switch self {
            case .text: "Text ↔ Bild"
            case .energy: "Energie ↔ Bewegung"
            case .aesthetics: "Ästhetik"
            case .rating: "Bewertung"
            case .shotSize: "Wechsel der Einstellungsgröße"
            case .reuse: "Wiederverwendung"
            case .adjacent: "Gleicher Clip direkt davor"
            case .sharpness: "Schärfe"
            case .chance: "Zufall (Neu würfeln)"
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
        var energy = 0.0
        var aesthetics = 0.0
        var rating = 0.0
        var shotSize = 0.0
        var reuse = 0.0
        var adjacent = 0.0
        var sharpness = 0.0
        var chance = 0.0

        var total: Double { text + energy + aesthetics + rating + shotSize + reuse + adjacent + sharpness + chance }

        subscript(component: Component) -> Double {
            switch component {
            case .text: text
            case .energy: energy
            case .aesthetics: aesthetics
            case .rating: rating
            case .shotSize: shotSize
            case .reuse: reuse
            case .adjacent: adjacent
            case .sharpness: sharpness
            case .chance: chance
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
        /// Anteile, die nicht vom Slot abhängen.
        var fixed = Scores()

        var length: Double { end - start }
    }

    struct Candidate {
        var unit: Int
        var base: Double
        var scores: Scores
    }

    struct Pick {
        var unit: Int
        var sourceIn: Double
        var scores: Scores
        var total: Double
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
        let text = normalize(textScores, slots: slots, units: units)
        var nodes: [Node] = []
        nodes.reserveCapacity(slots.count * beamWidth)
        var beams = [
            Beam(
                score: 0, node: -1, clipUses: Array(repeating: 0, count: project.clips.count),
                unitUses: Array(repeating: 0, count: units.count), cursor: [:])
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
                    seed: style.seed)
                alternatives[slotIndex] = Array(candidates.prefix(9))
                for (b, beam) in beams.enumerated() {
                    let previous = beam.node >= 0 ? nodes[beam.node].pick.unit : -1
                    let previousUnit = previous >= 0 ? units[previous] : nil
                    for candidate in candidates {
                        let unit = units[candidate.unit]
                        var scores = candidate.scores
                        scores.reuse =
                            -0.35 * Double(beam.clipUses[unit.clipIndex]) - 0.8 * Double(beam.unitUses[candidate.unit])
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
                                pick: Pick(unit: candidate.unit, sourceIn: sourceIn, scores: scores, total: total),
                                score: score))
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
                        copiedFrom: copiedFrom)))
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
                var unit = Unit(
                    clipIndex: clipIndex, clipID: clip.id, sceneID: scene.id, start: scene.start,
                    end: min(end, available), fps: clip.meta.fps, available: available,
                    motion: percentile(features?.motion ?? 0, allMotion),
                    aesthetics: features?.aesthetics ?? 0,
                    sharpness: percentile(features?.sharpness ?? 0, allSharpness),
                    utility: features?.isUtility ?? false, shotSize: features?.shotSize ?? .wide,
                    rating: clip.rating ?? 0)
                unit.fixed.aesthetics = 0.4 * (unit.aesthetics + 1) / 2 - (unit.utility ? 1.5 : 0)
                unit.fixed.sharpness = unit.sharpness < 0.15 ? -0.4 : 0
                unit.fixed.rating = unit.rating > 0 ? 0.15 * Double(unit.rating - 3) : 0
                units.append(unit)
            }
        }
        return units
    }

    /// Text-Ähnlichkeit je Zeile auf 0…1 normieren (SigLIP-Werte liegen dicht beieinander), als Liste je Einheit.
    static func normalize(_ scores: TextScores, slots: [Slot], units: [Unit]) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        for line in Set(slots.compactMap(\.lineID)) {
            guard let row = scores.values[line], let low = row.values.min(), let high = row.values.max(), high > low
            else { continue }
            result[line] = units.map { unit in row[unit.sceneID].map { Double(($0 - low) / (high - low)) } ?? 0 }
        }
        return result
    }

    /// Die besten Einheiten für einen Slot nach festen Anteilen (ohne Wiederverwendung und Nachbarschaft).
    static func rankedCandidates(
        _ slotIndex: Int, _ slot: Slot, need: Double, units: [Unit], text: [Double]?, seed: UInt64
    ) -> [Candidate] {
        var top = TopK<Candidate>(capacity: candidatesPerSlot) { $0.base }
        let prefix = SeededRandom.mix(SeededRandom.mix(SeededRandom.basis, seed), UInt64(slotIndex))
        for (index, unit) in units.enumerated() where unit.length >= need + margin {
            var random = SeededRandom(seed: SeededRandom.mix(SeededRandom.mix(prefix, UInt64(index)), 0xC0FFEE))
            var scores = unit.fixed
            if let text { scores.text = 1.2 * text[index] }
            scores.energy = 0.6 * (1 - abs(unit.motion - slot.energy))
            scores.chance = 0.5 * (random.unit() - 0.5)
            let base = scores.total
            guard top.accepts(base) else { continue }
            top.insert(Candidate(unit: index, base: base, scores: scores))
        }
        return top.items
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
