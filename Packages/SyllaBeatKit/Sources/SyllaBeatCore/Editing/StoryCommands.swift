import Foundation

/// Sperrbereiche eines Clips ersetzen (KI-Fehler). Schnitte, die danach einen Sperrbereich berühren, werden neu
/// bestimmt – auch fixierte (deren Fixierung entfällt).
public struct SetBlockedRanges: EditCommand {
    public var clipID: String
    public var ranges: [SourceRange]

    public init(clipID: String, ranges: [SourceRange]) {
        self.clipID = clipID
        self.ranges = ranges
    }

    public var actionName: String { "Sperrbereiche ändern" }

    public func apply(to project: inout Project) throws {
        guard let index = project.clips.firstIndex(where: { $0.id == clipID }) else {
            throw EditError.unknownClip(clipID)
        }
        project.clips[index].blocked = ranges.normalized(length: project.clips[index].meta.availableSeconds.doubleValue)
        project.repairCut()
    }
}

/// Den Quellbereich, den eine Einstellung gerade zeigt, sperren und die Einstellung neu schneiden (Taste X).
public struct BlockShotSource: EditCommand {
    public var shotID: String
    public init(shotID: String) { self.shotID = shotID }

    public var actionName: String { "Ausschnitt sperren" }

    public func apply(to project: inout Project) throws {
        guard let shot = project.cut?.shots.first(where: { $0.id == shotID }),
            let clip = project.clip(withID: shot.clipID)
        else { throw EditError.invalidValue("Diese Einstellung gibt es nicht.") }
        let start = shot.sourceIn.doubleValue
        try SetBlockedRanges(
            clipID: clip.id, ranges: clip.blocked + [SourceRange(start: start, end: start + shot.duration)]
        ).apply(to: &project)
    }
}
