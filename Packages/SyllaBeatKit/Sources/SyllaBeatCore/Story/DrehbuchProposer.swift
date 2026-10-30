import Foundation

/// Drehbuch-Vorschlag ohne KI: Abschnitte in Songreihenfolge werden Kapiteln in Erzählreihenfolge zugeordnet, ohne
/// Rückschritt (dynamische Programmierung). Beleg je Abschnitt und Kapitel kommt aus der Text-Bild-Ähnlichkeit; der
/// erste Abschnitt gehört dem ersten, der letzte dem letzten Kapitel (+1). Montage-Abschnitte bekommen ihr bestes
/// Kapitel. Bei Gleichstand gewinnt das kleinere Kapitel. Im Spike 8/11 Abschnitte richtig.
public enum DrehbuchProposer {
    public static func plan(
        sections: [SongSection], chapters: [Chapter], evidence: [String: [Double]], montage: Set<String>
    ) -> [String: [String: ChapterRole]] {
        guard !chapters.isEmpty, !sections.isEmpty else { return [:] }
        let count = chapters.count
        let ordered = sections.sorted { $0.start < $1.start }
        var scores = ordered.map { section -> [Double] in
            let values = evidence[section.id] ?? []
            return (0..<count).map { $0 < values.count ? values[$0] : 0 }
        }
        scores[0][0] += 1
        scores[ordered.count - 1][count - 1] += 1
        var plan: [String: [String: ChapterRole]] = [:]
        func best(_ values: [Double]) -> Int {
            var index = 0
            for candidate in values.indices where values[candidate] > values[index] { index = candidate }
            return index
        }
        let chain = ordered.indices.filter { !montage.contains(ordered[$0].id) }
        for index in ordered.indices where montage.contains(ordered[index].id) {
            plan[ordered[index].id] = [chapters[best(scores[index])].id: .main]
        }
        guard !chain.isEmpty else { return plan }
        var total = Array(repeating: Array(repeating: 0.0, count: count), count: chain.count)
        var back = Array(repeating: Array(repeating: 0, count: count), count: chain.count)
        for (k, section) in chain.enumerated() {
            for chapter in 0..<count {
                if k == 0 {
                    total[k][chapter] = scores[section][chapter]
                    continue
                }
                let previous = best(Array(total[k - 1][0...chapter]))
                total[k][chapter] = total[k - 1][previous] + scores[section][chapter]
                back[k][chapter] = previous
            }
        }
        var chapter = best(total[chain.count - 1])
        for k in stride(from: chain.count - 1, through: 0, by: -1) {
            plan[ordered[chain[k]].id] = [chapters[chapter].id: .main]
            chapter = back[k][chapter]
        }
        return plan
    }
}
