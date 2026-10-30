import Foundation

/// Erwartung für ein Messprojekt (`sbtool geschichte`): welche Dateinamen-Teile zu welchem Kapitel gehören, welche
/// Kapitel in welchem Abschnitt vorkommen sollen und welche Motive eine Zeile zeigen soll.
public struct StoryTruth: Decodable, Sendable {
    public struct Line: Decodable, Sendable {
        public var enthaelt: [String]
        public var motive: [String]
    }

    /// Kapitel → Teile von Dateinamen.
    public var kapitel: [String: [String]]
    /// Abschnittsname → erlaubte Kapitel.
    public var abschnitte: [String: [String]]
    public var zeilen: [Line]
    /// Teile von Dateinamen, die Abend/Nacht bedeuten.
    public var abend: [String]
    /// Erzählreihenfolge der Kapitel (für das Drehbuch); optional.
    public var reihenfolge: [String]?

    public func lineMotifs(_ text: String) -> [String]? {
        let tokens = zeilen.filter { rule in rule.enthaelt.contains { text.contains($0) } }.flatMap(\.motive)
        return tokens.isEmpty ? nil : tokens
    }
}

/// Messgrößen eines Schnitts gegen eine `StoryTruth`, zeitgewichtet.
public struct StoryMeasurement: Sendable, Equatable {
    /// Anteil der Zeit mit einem Clip aus einem erlaubten Kapitel des Abschnitts.
    public var chapterHits: Double
    /// Anteil der Zeit in Zeilen mit Motiv, in der das Motiv zu sehen ist.
    public var lineHits: Double
    /// Wechsel zwischen Tag und Abend entlang des Schnitts.
    public var timeSwitches: Int
    /// „Motiv · fremd · gleiches Motiv“ innerhalb einer Zeile.
    public var sandwiches: Int
    public var shots: Int

    public init(chapterHits: Double, lineHits: Double, timeSwitches: Int, sandwiches: Int, shots: Int) {
        self.chapterHits = chapterHits
        self.lineHits = lineHits
        self.timeSwitches = timeSwitches
        self.sandwiches = sandwiches
        self.shots = shots
    }
}

public enum StoryMetrics {
    public static func measure(_ project: Project, cut: Cut, truth: StoryTruth) -> StoryMeasurement {
        let analysis = project.analysis
        let sections = (analysis?.sections ?? []).sorted { $0.start < $1.start }
        let lines = analysis?.lines ?? []
        let names = Dictionary(project.clips.map { ($0.id, $0.name.lowercased()) }, uniquingKeysWith: { a, _ in a })
        func matches(_ clipID: String, _ tokens: [String]) -> Bool {
            let name = names[clipID] ?? clipID.lowercased()
            return tokens.contains { name.contains($0.lowercased()) }
        }
        func line(_ shot: Shot) -> LyricLine? {
            func overlap(_ line: LyricLine) -> Double {
                max(0, min(line.end, shot.end.time) - max(line.start, shot.start.time))
            }
            return lines.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
        }
        var chapterHit = 0.0
        var chapterTotal = 0.0
        var lineHit = 0.0
        var lineTotal = 0.0
        for shot in cut.shots {
            let middle = (shot.start.time + shot.end.time) / 2
            if let section = sections.first(where: { $0.start <= middle && middle < $0.end }) ?? sections.last,
                let chapters = truth.abschnitte[section.label]
            {
                chapterTotal += shot.duration
                if matches(shot.clipID, chapters.flatMap { truth.kapitel[$0] ?? [] }) { chapterHit += shot.duration }
            }
            if let line = line(shot), let motifs = truth.lineMotifs(line.text) {
                lineTotal += shot.duration
                if matches(shot.clipID, motifs) { lineHit += shot.duration }
            }
        }
        let evening = cut.shots.map { matches($0.clipID, truth.abend) }
        let switches = zip(evening, evening.dropFirst()).filter { $0 != $1 }.count
        var sandwiches = 0
        let motifs = cut.shots.map { motifKey(names[$0.clipID] ?? $0.clipID) }
        for index in cut.shots.indices.dropFirst().dropLast()
        where motifs[index - 1] == motifs[index + 1] && motifs[index] != motifs[index - 1] {
            let ids = [index - 1, index, index + 1].map { line(cut.shots[$0])?.id }
            if let first = ids[0], ids.allSatisfy({ $0 == first }) { sandwiches += 1 }
        }
        return StoryMeasurement(
            chapterHits: chapterTotal > 0 ? chapterHit / chapterTotal : 0,
            lineHits: lineTotal > 0 ? lineHit / lineTotal : 0, timeSwitches: switches, sandwiches: sandwiches,
            shots: cut.shots.count)
    }

    /// Motiv eines Dateinamens für den Sandwich-Vergleich (Takes zählen gleich).
    static func motifKey(_ name: String) -> String {
        FileNameMotif.parse(name).key
    }
}
