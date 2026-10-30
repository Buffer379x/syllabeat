import Foundation

/// Zeile ohne klares Bild (oder vom Nutzer als „braucht ein Bild“ markiert).
public struct LineGap: Sendable, Equatable {
    public var text: String
    public var confidence: Double
    public var marked: Bool

    public init(text: String, confidence: Double, marked: Bool) {
        self.text = text
        self.confidence = confidence
        self.marked = marked
    }
}

/// Bedarf eines Kapitels an Material.
public struct ChapterNeed: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Mindestens das 1,5-Fache des Bedarfs.
        case ok
        /// Zwischen einfachem und 1,5-fachem Bedarf.
        case short
        /// Weniger als der Bedarf.
        case missing
    }

    public var chapterID: String
    /// Sekunden, die das Drehbuch dem Kapitel zuteilt.
    public var needed: Double
    /// Nutzbare Sekunden ohne Sperrbereiche.
    public var available: Double
    public var status: Status
    public var suggestedClips: Int

    public init(chapterID: String, needed: Double, available: Double, status: Status, suggestedClips: Int) {
        self.chapterID = chapterID
        self.needed = needed
        self.available = available
        self.status = status
        self.suggestedClips = suggestedClips
    }
}

/// Was fehlt: Zeilen ohne klares Bild, Kapitel mit zu wenig Material, Motive nur mit Wasserzeichen.
public struct CoverageReport: Sendable, Equatable {
    public var lines: [LineGap]
    public var chapters: [ChapterNeed]
    /// Motivschlüssel, die es nur mit Wasserzeichen gibt.
    public var watermarkOnly: [String]

    public init(lines: [LineGap], chapters: [ChapterNeed], watermarkOnly: [String]) {
        self.lines = lines
        self.chapters = chapters
        self.watermarkOnly = watermarkOnly
    }

    public var isEmpty: Bool { lines.isEmpty && chapters.allSatisfy { $0.status == .ok } && watermarkOnly.isEmpty }
}

public enum CoverageAnalyzer {
    /// Unter dieser Sicherheit hat eine Zeile kein klares Bild.
    public static let clearConfidence = 0.6
    /// Länge, die für einen neuen Clip angenommen wird.
    public static let newClipSeconds = 10.0

    /// `lineConfidence`: Sicherheit je Zeilentext (`CutEngine.gateConfidence`).
    public static func analyze(_ project: Project, lineConfidence: [String: Double]) -> CoverageReport {
        CoverageReport(
            lines: lineGaps(project, lineConfidence), chapters: chapterNeeds(project),
            watermarkOnly: watermarkOnly(project))
    }

    static func lineGaps(_ project: Project, _ confidence: [String: Double]) -> [LineGap] {
        var seen: Set<String> = []
        var result: [LineGap] = []
        for line in (project.analysis?.lines ?? []).sorted(by: { $0.start < $1.start }) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            let need = project.story.lineNeeds[text]
            let value = confidence[text] ?? 0
            if need == true || (need == nil && confidence[text] != nil && value < clearConfidence) {
                result.append(LineGap(text: text, confidence: value, marked: need == true))
            }
        }
        return result
    }

    /// Hauptkapitel teilen sich die Abschnittsdauer, eine Beimischung zählt ein Viertel eines Hauptanteils;
    /// identische Refrain-Kopien zählen nicht (sie zeigen dasselbe Material).
    static func chapterNeeds(_ project: Project) -> [ChapterNeed] {
        let sections = project.analysis?.sections ?? []
        var needed: [String: Double] = [:]
        for section in sections {
            if section.repeatOf != nil, project.style.refrainMode == .identical, project.story.plan[section.id] == nil {
                continue
            }
            guard let entry = project.story.plan[section.id] ?? section.repeatOf.flatMap({ project.story.plan[$0] }),
                !entry.isEmpty
            else { continue }
            let mains = Double(entry.values.filter { $0 == .main }.count)
            let mixes = Double(entry.values.filter { $0 == .mix }.count)
            let share = (section.end - section.start) / (mains + 0.25 * mixes)
            for (chapter, role) in entry { needed[chapter, default: 0] += role == .main ? share : 0.25 * share }
        }
        return project.story.chapters.compactMap { chapter in
            guard let need = needed[chapter.id], need > 0 else { return nil }
            let available = project.clips.filter { $0.chapterID == chapter.id && !$0.excluded }.reduce(0.0) {
                sum, clip in
                let length = clip.meta.availableSeconds.doubleValue
                let blocked = clip.blocked.normalized(length: length).reduce(0.0) { $0 + $1.end - $1.start }
                return sum + max(0, length - blocked)
            }
            let status: ChapterNeed.Status =
                available >= 1.5 * need - 1e-9 ? .ok : available >= need - 1e-9 ? .short : .missing
            let suggested = status == .ok ? 0 : Int(ceil((1.5 * need - available) / newClipSeconds - 1e-9))
            return ChapterNeed(
                chapterID: chapter.id, needed: need, available: available, status: status,
                suggestedClips: status == .ok ? 0 : max(1, suggested))
        }
    }

    static func watermarkOnly(_ project: Project) -> [String] {
        let motifs = project.motifs().values.filter { $0.words.count >= 2 || $0.generator != nil || $0.copy > 1 }
        let grouped = Dictionary(grouping: motifs, by: \.key)
        return grouped.filter { $0.value.allSatisfy { $0.watermark == true } }.keys.sorted()
    }
}
