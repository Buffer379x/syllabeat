import Foundation

/// Die einzige Frame-Tabelle für Vorschau und alle Exporte.
public struct FrameTable: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var shotID: String
        public var clipID: String
        public var startFrame: Int64
        public var endFrame: Int64
        public var sourceInFrame: Int64
        public var sourceOutFrame: Int64
        public var sourceFPS: Rational

        public var durationFrames: Int64 { endFrame - startFrame }
    }

    public var fps: Rational
    public var width: Int
    public var height: Int
    public var durationFrames: Int64
    public var entries: [Entry]
}

public enum CompileError: Error, Equatable, LocalizedError {
    case noAnalysis
    case empty
    case gap(shot: Int)
    case unknownClip(shot: Int, clipID: String)
    case tooShort(shot: Int)
    case sourceTooShort(shot: Int, clipName: String)
    case blocked(shot: Int, clipName: String)
    case wrongEnd

    public var errorDescription: String? {
        switch self {
        case .noAnalysis: "Bitte zuerst den Song analysieren."
        case .empty: "Der Schnitt enthält keine Einstellungen."
        case .gap(let shot): "Einstellung \(shot) schließt nicht lückenlos an die vorherige an."
        case .unknownClip(let shot, let clipID): "Einstellung \(shot) verweist auf den unbekannten Clip „\(clipID)“."
        case .tooShort(let shot): "Einstellung \(shot) ist kürzer als ein Frame."
        case .sourceTooShort(let shot, let clipName):
            "Einstellung \(shot): Der Clip „\(clipName)“ ist ab dem Quell-In zu kurz."
        case .blocked(let shot, let clipName):
            "Einstellung \(shot): „\(clipName)“ liegt in einem Sperrbereich."
        case .wrongEnd: "Der Schnitt endet nicht am Songende."
        }
    }
}

/// Kompiliert einen Schnitt: Grenzen einmal auf Frames runden (ab halb aufwärts), Quell-In auf Quellframes,
/// Dauern in Quellframes umrechnen. Rechnet exakt wie `compile_timeline` in 0.2.0.
public enum CutCompiler {
    public static func compile(_ project: Project, cut: Cut) throws -> FrameTable {
        guard let analysis = project.analysis else { throw CompileError.noAnalysis }
        guard !cut.shots.isEmpty else { throw CompileError.empty }
        let rate = project.timeline.fps
        let clips = Dictionary(project.clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let songEnd = FrameMath.frame(atSeconds: analysis.duration, rate: rate)
        var entries: [FrameTable.Entry] = []
        var previousEnd: Int64 = 0
        for (index, shot) in cut.shots.enumerated() {
            guard FrameMath.frame(atSeconds: shot.start.time, rate: rate) == previousEnd else {
                throw CompileError.gap(shot: index + 1)
            }
            let entry = try self.entry(shot, number: index + 1, clips: clips, rate: rate)
            entries.append(entry)
            previousEnd = entry.endFrame
        }
        guard previousEnd == songEnd else { throw CompileError.wrongEnd }
        return FrameTable(
            fps: rate, width: project.timeline.width, height: project.timeline.height, durationFrames: songEnd,
            entries: entries)
    }

    /// Einen Shot auf Frames runden und gegen das Quellmaterial prüfen.
    static func entry(_ shot: Shot, number: Int, clips: [String: Clip], rate: Rational) throws -> FrameTable.Entry {
        let start = FrameMath.frame(atSeconds: shot.start.time, rate: rate)
        let end = FrameMath.frame(atSeconds: shot.end.time, rate: rate)
        guard end > start else { throw CompileError.tooShort(shot: number) }
        guard let clip = clips[shot.clipID] else { throw CompileError.unknownClip(shot: number, clipID: shot.clipID) }
        let sourceRate = clip.meta.fps
        let sourceIn = FrameMath.frame(at: shot.sourceIn, rate: sourceRate)
        let duration = FrameMath.seconds(ofFrames: end - start, rate: rate)
        let sourceOut = sourceIn + FrameMath.frame(at: duration, rate: sourceRate)
        let sourceEnd = FrameMath.seconds(ofFrames: sourceIn, rate: sourceRate) + duration
        guard sourceIn >= 0, sourceEnd <= clip.meta.availableSeconds + Rational(1, 1_000_000) else {
            throw CompileError.sourceTooShort(shot: number, clipName: clip.name)
        }
        let sourceStart = FrameMath.seconds(ofFrames: sourceIn, rate: sourceRate).doubleValue
        if clip.blocked.contains(where: { $0.overlaps(sourceStart, sourceEnd.doubleValue) }) {
            throw CompileError.blocked(shot: number, clipName: clip.name)
        }
        return FrameTable.Entry(
            shotID: shot.id, clipID: shot.clipID, startFrame: start, endFrame: end, sourceInFrame: sourceIn,
            sourceOutFrame: sourceOut, sourceFPS: sourceRate)
    }

    /// Shots, die sich nicht kompilieren lassen (kürzer als ein Frame, Clip fehlt, Material zu kurz, Sperrbereich).
    public static func brokenShots(_ project: Project, cut: Cut) -> Set<String> {
        let clips = Dictionary(project.clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var broken: Set<String> = []
        for (index, shot) in cut.shots.enumerated()
        where (try? entry(shot, number: index + 1, clips: clips, rate: project.timeline.fps)) == nil {
            broken.insert(shot.id)
        }
        return broken
    }
}
