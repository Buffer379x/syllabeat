import Foundation

/// Zusätze für YouTube: Kapitel-Zeitmarken für die Videobeschreibung und die Wahl des Vorschaubilds.
public enum YouTubeExport {
    /// Mindestlänge eines YouTube-Kapitels.
    static let minimumPart = 10.0

    /// Zeitmarken („0:00 Aufbruch“) aus den Story-Kapiteln entlang des Schnitts, sonst aus den Songabschnitten. Teile
    /// unter 10 s gehen im vorigen auf; der erste beginnt bei 0:00. Unter drei Teilen: `nil` (YouTube verlangt drei).
    public static func chapters(_ project: Project, cut: Cut) -> String? {
        var parts: [(start: Double, end: Double, name: String)] = []
        if !project.story.chapters.isEmpty {
            for shot in cut.shots {
                let name = project.story.chapter(withID: project.clip(withID: shot.clipID)?.chapterID)?.name
                if let last = parts.last, name == nil || name == last.name {
                    parts[parts.count - 1].end = shot.end.time
                } else {
                    parts.append((shot.start.time, shot.end.time, name ?? ""))
                }
            }
        } else {
            parts = (project.analysis?.sections ?? []).sorted { $0.start < $1.start }.map {
                ($0.start, $0.end, $0.label)
            }
        }
        var merged: [(start: Double, end: Double, name: String)] = []
        for part in parts where part.end > part.start {
            if let last = merged.last, part.end - part.start < minimumPart || part.name == last.name {
                merged[merged.count - 1].end = part.end
            } else {
                merged.append(part)
            }
        }
        if let first = merged.first, first.end - first.start < minimumPart, merged.count > 1 {
            merged[1].start = 0
            merged.removeFirst()
        }
        guard merged.count >= 3 else { return nil }
        merged[0].start = 0
        return merged.map { "\(time($0.start)) \($0.name)" }.joined(separator: "\n") + "\n"
    }

    /// Szene für das Vorschaubild: im Schnitt verwendet, kein Gebrauchsbild, höchster Wert aus Ästhetik und Bewertung.
    public static func thumbnailScene(_ project: Project, cut: Cut) -> (clipID: String, sceneID: String)? {
        var best: (clipID: String, sceneID: String, score: Double)?
        for shot in cut.shots {
            guard let clip = project.clip(withID: shot.clipID),
                let scene = clip.scenes.first(where: { $0.id == shot.sceneID }) ?? clip.scenes.first,
                scene.features?.isUtility != true
            else { continue }
            let score = (scene.features?.aesthetics ?? 0) + (clip.rating.map { 0.15 * Double($0 - 3) } ?? 0)
            if score > best?.score ?? -.infinity { best = (clip.id, scene.id, score) }
        }
        return best.map { ($0.clipID, $0.sceneID) }
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = total / 60 % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, total % 60)
            : String(format: "%d:%02d", minutes, total % 60)
    }
}
