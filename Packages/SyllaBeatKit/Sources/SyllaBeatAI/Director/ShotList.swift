import Foundation
import SyllaBeatCore

/// Eintrag der Drehliste: was fehlt, unter welchem Dateinamen und mit welchem Prompt für den KI-Generator.
public struct ShotListEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case line, chapter, watermark }

    public var kind: Kind
    public var reason: String
    public var fileName: String
    public var prompt: String
}

/// Drehliste für neue KI-Clips aus dem `CoverageReport`.
public enum ShotList {
    public static func entries(_ report: CoverageReport, project: Project) -> [ShotListEntry] {
        let style = project.story.promptStyle
        let group = dominantGroup(project)
        var result: [ShotListEntry] = report.lines.map { gap in
            ShotListEntry(
                kind: .line, reason: gap.marked ? "Von dir markiert" : "Zeile ohne klares Bild",
                fileName: fileName(for: gap.text, group: group), prompt: prompt(style: style, content: gap.text))
        }
        for need in report.chapters where need.status != .ok {
            let name = project.story.chapter(withID: need.chapterID)?.name ?? need.chapterID
            result.append(
                ShotListEntry(
                    kind: .chapter,
                    reason:
                        "Kapitel „\(name)“: braucht ≈ \(Int(need.needed.rounded())) s, hat \(Int(need.available.rounded())) s → "
                        + "\(need.suggestedClips) weitere\(need.suggestedClips == 1 ? "r" : "") Clip\(need.suggestedClips == 1 ? "" : "s")",
                    fileName: fileName(for: name, group: group), prompt: prompt(style: style, content: name)))
        }
        for key in report.watermarkOnly {
            result.append(
                ShotListEntry(
                    kind: .watermark, reason: "Nur mit Wasserzeichen vorhanden – ohne neu erzeugen",
                    fileName: key.replacingOccurrences(of: " ", with: "_") + "_no_watermark",
                    prompt: prompt(style: style, content: key)))
        }
        return result
    }

    /// Dateiname im Schema der vorhandenen Clips: Gruppe + Wörter (ab drei Buchstaben, ohne Füllwörter, Umlaute
    /// ausgeschrieben), mit Unterstrichen.
    public static func fileName(for text: String, group: String?) -> String {
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 && !StoryScores.stopWords.contains($0) }
            .map { word in
                word.replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
                    .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "ß", with: "ss")
            }
        return ((group.map { [$0] } ?? []) + words).joined(separator: "_")
    }

    public static func prompt(style: String, content: String) -> String {
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        return style.isEmpty ? content : "\(style). \(content)"
    }

    /// Als Text zum Kopieren oder Sichern.
    public static func text(_ entries: [ShotListEntry]) -> String {
        entries.map { "\($0.reason)\n  Datei: \($0.fileName)\n  Prompt: \($0.prompt)" }.joined(separator: "\n\n") + "\n"
    }

    /// Häufigste Gruppe der Dateinamen im Projekt (z. B. „farm“).
    static func dominantGroup(_ project: Project) -> String? {
        let groups = project.motifs().values.compactMap(\.group)
        return Dictionary(grouping: groups, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}
