import Foundation

extension Project {
    /// Fixierte Shots des aktiven Schnitts.
    var lockedShots: [Shot] { cut?.shots.filter(\.locked) ?? [] }

    mutating func regenerate(style: CutStyle, textScores: TextScores, keep: [Shot]) throws {
        guard analysis != nil else { throw EditError.invalidValue("Bitte zuerst den Song analysieren.") }
        guard let generated = CutEngine.generate(self, style: style, textScores: textScores, keep: keep) else {
            throw EditError.invalidValue(
                "Für einen Schnitt fehlen nutzbare Clips. Clips hinzufügen oder „Nie verwenden“ zurücknehmen.")
        }
        self.style = style
        cut = generated
    }

    /// Ändert einen Shot. Im Refrain-Modus „identisch“ folgen die Kopien ihrer Vorlage; fixierte Kopien oder solche,
    /// für die das Material nicht reicht, werden zu eigenständigen Shots.
    /// Nach Rasteränderungen: Shots, die nicht mehr kompilieren, neu bestimmen; der Rest bleibt, wie er ist.
    mutating func repairCut() {
        guard var cut, analysis != nil else { return }
        // Shots unter einem Frame oder unter der halben Mindestdauer dem Vorgänger (bzw. Nachfolger) zuschlagen; der
        // wird dann neu bestimmt. Etwas kürzer gewordene Shots bleiben: Das ist die gewollte Folge der Korrektur.
        let rate = timeline.fps
        func empty(_ shot: Shot) -> Bool {
            if !shot.locked, shot.duration < style.minimumDuration / 2 { return true }
            return FrameMath.frame(atSeconds: shot.end.time, rate: rate)
                <= FrameMath.frame(atSeconds: shot.start.time, rate: rate)
        }
        var merged: Set<String> = []
        var index = 0
        while index < cut.shots.count, cut.shots.count > 1 {
            guard empty(cut.shots[index]) else {
                index += 1
                continue
            }
            if index > 0 {
                cut.shots[index - 1].end = cut.shots[index].end
                merged.insert(cut.shots[index - 1].id)
            } else {
                cut.shots[1].start = cut.shots[0].start
                merged.insert(cut.shots[1].id)
            }
            cut.shots.remove(at: index)
        }
        let broken = CutCompiler.brokenShots(self, cut: cut).union(merged)
        guard !broken.isEmpty else { return }
        self.cut = cut
        let keep = cut.shots.filter { !broken.contains($0.id) }
        if let repaired = CutEngine.generate(self, style: style, keep: keep, name: cut.name) {
            self.cut = Cut(id: cut.id, name: cut.name, seed: cut.seed, origin: cut.origin, shots: repaired.shots)
        }
    }

    /// Shot-IDs plus die Kopien der enthaltenen Vorlagen (Refrain „identisch“ bleibt identisch).
    func withCopies(_ ids: Set<String>) -> Set<String> {
        guard style.refrainMode == .identical, let shots = cut?.shots else { return ids }
        return ids.union(shots.filter { $0.reasons?.copiedFrom.map(ids.contains) ?? false }.map(\.id))
    }

    mutating func updateShot(_ id: String, _ change: (inout Shot) throws -> Void) throws {
        guard var cut, let index = cut.shots.firstIndex(where: { $0.id == id }) else {
            throw EditError.invalidValue("Diese Einstellung gibt es nicht.")
        }
        try change(&cut.shots[index])
        if style.refrainMode == .identical {
            let template = cut.shots[index]
            let available = clip(withID: template.clipID)?.meta.availableSeconds ?? .zero
            for i in cut.shots.indices where cut.shots[i].reasons?.copiedFrom == id {
                let copy = cut.shots[i]
                if copy.clipID == template.clipID && copy.sourceIn == template.sourceIn { continue }
                if !copy.locked, template.sourceIn + Rational(seconds: copy.duration) <= available {
                    cut.shots[i].clipID = template.clipID
                    cut.shots[i].sceneID = template.sceneID
                    cut.shots[i].sourceIn = template.sourceIn
                } else {
                    cut.shots[i].reasons?.copiedFrom = nil
                }
            }
        }
        self.cut = cut
    }
}

/// Erster Schnitt (Autopilot) oder komplett neu; fixierte Shots bleiben.
public struct GenerateCut: EditCommand {
    public var textScores: TextScores
    public init(textScores: TextScores = TextScores()) { self.textScores = textScores }

    public var actionName: String { "Schnitt erstellen" }

    public func apply(to project: inout Project) throws {
        try project.regenerate(style: project.style, textScores: textScores, keep: project.lockedShots)
    }
}

/// Neuer Stil (Preset oder Regler): schneidet sofort neu, fixierte Shots bleiben stehen.
public struct SetCutStyle: EditCommand {
    public var style: CutStyle
    public var textScores: TextScores
    public init(style: CutStyle, textScores: TextScores = TextScores()) {
        self.style = style
        self.textScores = textScores
    }

    public var actionName: String { "Schnittstil ändern" }

    public func apply(to project: inout Project) throws {
        guard project.analysis != nil, project.cut != nil else {
            project.style = style
            return
        }
        try project.regenerate(style: style, textScores: textScores, keep: project.lockedShots)
    }
}

/// „Neu würfeln“: neuer Seed, fixierte Shots bleiben.
public struct Reroll: EditCommand {
    public var textScores: TextScores
    public init(textScores: TextScores = TextScores()) { self.textScores = textScores }

    public var actionName: String { "Neu würfeln" }

    public func apply(to project: inout Project) throws {
        var style = project.style
        style.seed = style.seed &+ 1
        try project.regenerate(style: style, textScores: textScores, keep: project.lockedShots)
    }
}

/// Teil neu schneiden: nur die gewählten Shots (bzw. ein Zeitbereich) werden neu bestimmt, der Rest bleibt.
public struct RecutShots: EditCommand {
    public var shotIDs: Set<String>
    public var textScores: TextScores
    public init(shotIDs: Set<String>, textScores: TextScores = TextScores()) {
        self.shotIDs = shotIDs
        self.textScores = textScores
    }

    public var actionName: String { shotIDs.count == 1 ? "Einstellung neu schneiden" : "Auswahl neu schneiden" }

    public func apply(to project: inout Project) throws {
        guard let cut = project.cut else { throw EditError.invalidValue("Es gibt noch keinen Schnitt.") }
        let selected = project.withCopies(shotIDs)
        let keep = cut.shots.filter { !selected.contains($0.id) || $0.locked }
        var style = project.style
        style.seed = style.seed &+ 7919
        try project.regenerate(style: style, textScores: textScores, keep: keep)
        project.style.seed = style.seed
    }
}

public struct SetShotLocked: EditCommand {
    public var shotID: String
    public var locked: Bool
    public init(shotID: String, locked: Bool) {
        self.shotID = shotID
        self.locked = locked
    }

    public var actionName: String { locked ? "Einstellung fixieren" : "Fixierung lösen" }

    public func apply(to project: inout Project) throws {
        try project.updateShot(shotID) { $0.locked = locked }
    }
}

/// Mehrere Einstellungen auf einmal fixieren oder lösen (Taste `L`).
public struct SetShotsLocked: EditCommand {
    public var shotIDs: Set<String>
    public var locked: Bool
    public init(shotIDs: Set<String>, locked: Bool) {
        self.shotIDs = shotIDs
        self.locked = locked
    }

    public var actionName: String { locked ? "Fixieren" : "Fixierung lösen" }

    public func apply(to project: inout Project) throws {
        guard var cut = project.cut else { throw EditError.invalidValue("Es gibt noch keinen Schnitt.") }
        for index in cut.shots.indices where shotIDs.contains(cut.shots[index].id) { cut.shots[index].locked = locked }
        project.cut = cut
    }
}

/// Alternative wählen: Clip und Quell-In ersetzen; die Einstellung wird fixiert, damit die Wahl bleibt.
public struct ReplaceShot: EditCommand {
    public var shotID: String
    public var clipID: String
    public var sceneID: String?
    public var sourceIn: Rational
    public init(shotID: String, clipID: String, sceneID: String?, sourceIn: Rational) {
        self.shotID = shotID
        self.clipID = clipID
        self.sceneID = sceneID
        self.sourceIn = sourceIn
    }

    public var actionName: String { "Clip ersetzen" }

    public func apply(to project: inout Project) throws {
        guard let clip = project.clip(withID: clipID) else { throw EditError.unknownClip(clipID) }
        try project.updateShot(shotID) { shot in
            let end = sourceIn + Rational(seconds: shot.duration)
            guard end <= clip.meta.availableSeconds else {
                throw EditError.invalidValue("„\(clip.name)“ ist ab dieser Stelle zu kurz für die Einstellung.")
            }
            shot.clipID = clipID
            shot.sceneID = sceneID
            shot.sourceIn = sourceIn
            shot.locked = true
            // Von Hand gewählt: Die alte Bewertung gilt nicht mehr, die Alternativen bleiben zum Zurückwechseln.
            shot.reasons = ShotReasons(components: [:], total: 0, alternatives: shot.reasons?.alternatives ?? [])
        }
    }
}

/// Quell-In um ganze Quellframes verschieben (Jog im Inspektor).
public struct NudgeSourceIn: EditCommand {
    public var shotID: String
    public var frames: Int
    public init(shotID: String, frames: Int) {
        self.shotID = shotID
        self.frames = frames
    }

    public var actionName: String { "Quell-In verschieben" }

    public func apply(to project: inout Project) throws {
        let snapshot = project
        try project.updateShot(shotID) { shot in
            guard let clip = snapshot.clip(withID: shot.clipID) else { throw EditError.unknownClip(shot.clipID) }
            let step = Rational(Int64(frames)) / clip.meta.fps
            let moved = shot.sourceIn + step
            guard moved >= .zero, moved + Rational(seconds: shot.duration) <= clip.meta.availableSeconds else {
                throw EditError.invalidValue("Weiter geht es in diesem Clip nicht.")
            }
            shot.sourceIn = moved
            shot.locked = true
        }
    }
}

/// Drei Varianten mit verschiedenen Seeds erzeugen und die erste aktivieren.
public struct CreateVariants: EditCommand {
    public var textScores: TextScores
    public init(textScores: TextScores = TextScores()) { self.textScores = textScores }

    public var actionName: String { "Varianten erzeugen" }

    public func apply(to project: inout Project) throws {
        let keep = project.lockedShots
        var variants: [Cut] = []
        for offset in 0..<3 {
            var style = project.style
            style.seed = style.seed &+ UInt64(offset * 101)
            guard
                let cut = CutEngine.generate(
                    project, style: style, textScores: textScores, keep: keep, name: "Variante \(offset + 1)")
            else { throw EditError.invalidValue("Für Varianten fehlen nutzbare Clips.") }
            variants.append(
                Cut(id: "variant-\(offset + 1)", name: cut.name, seed: cut.seed, origin: .engine, shots: cut.shots))
        }
        project.variants = variants
        project.cut = variants[0]
    }
}

public struct SelectVariant: EditCommand {
    public var variantID: String
    public init(variantID: String) { self.variantID = variantID }

    public var actionName: String { "Variante wählen" }

    public func apply(to project: inout Project) throws {
        guard let variant = project.variants.first(where: { $0.id == variantID }) else {
            throw EditError.invalidValue("Diese Variante gibt es nicht.")
        }
        // Änderungen an der aktiven Variante bleiben in der Liste erhalten.
        if let current = project.cut, let index = project.variants.firstIndex(where: { $0.id == current.id }) {
            project.variants[index] = current
        }
        project.cut = variant
        project.style.seed = variant.seed
    }
}

/// Füllen oder Einpassen für Vorschau und Exporte.
public struct SetFit: EditCommand {
    public var fit: TimelineSettings.Fit
    public init(fit: TimelineSettings.Fit) { self.fit = fit }

    public var actionName: String { "Bildanpassung ändern" }

    public func apply(to project: inout Project) throws {
        project.timeline.fit = fit
    }
}

/// Format, Bildrate und Bildanpassung der Timeline. Schnittgrenzen sind Zeiten mit Ankern; danach wird neu gerundet
/// und repariert, was kürzer als ein Frame geworden ist.
public struct SetTimelineSettings: EditCommand {
    public var settings: TimelineSettings
    public init(settings: TimelineSettings) { self.settings = settings }

    public var actionName: String { "Timeline-Format ändern" }

    public func apply(to project: inout Project) throws {
        guard settings.width > 0, settings.height > 0, settings.fps > .zero else {
            throw EditError.invalidValue("Ungültiges Timeline-Format.")
        }
        project.timeline = settings
        project.repairCut()
    }
}

/// Storyboard übernehmen (oder mit `nil` entfernen) und den Schnitt danach neu bestimmen; fixierte Shots bleiben.
/// Ein Undo-Schritt für beides.
public struct ApplyStoryboard: EditCommand {
    public var storyboard: Storyboard?
    public var textScores: TextScores
    public init(storyboard: Storyboard?, textScores: TextScores = TextScores()) {
        self.storyboard = storyboard
        self.textScores = textScores
    }

    public var actionName: String { storyboard == nil ? "Storyboard entfernen" : "Storyboard übernehmen" }

    public func apply(to project: inout Project) throws {
        project.storyboard = storyboard
        guard project.analysis != nil, project.cut != nil else { return }
        try project.regenerate(style: project.style, textScores: textScores, keep: project.lockedShots)
    }
}

extension Project {
    /// Nach einer Handbearbeitung: Gibt es Shots, die nicht kompilieren, wird die Änderung abgelehnt.
    func requireCompilable(_ cut: Cut, change: String) throws {
        let broken = CutCompiler.brokenShots(self, cut: cut)
        guard broken.isEmpty else {
            let numbers = cut.shots.enumerated().filter { broken.contains($0.element.id) }.map { "\($0.offset + 1)" }
            throw EditError.invalidValue(
                "\(change) geht nicht: Einstellung \(numbers.joined(separator: ", ")) wäre kürzer als ein Frame oder länger als ihr Clip."
            )
        }
    }

    /// Von Hand geänderte Shots und ihre Kopien sind keine identischen Wiederholungen mehr.
    func detachingCopies(_ cut: Cut, of ids: Set<String>) -> Cut {
        var cut = cut
        for index in cut.shots.indices {
            let shot = cut.shots[index]
            if ids.contains(shot.id) || shot.reasons?.copiedFrom.map(ids.contains) == true {
                cut.shots[index].reasons?.copiedFrom = nil
            }
        }
        return cut
    }
}

/// `B`: die Einstellung an `time` teilen. Beide Hälften zeigen denselben Clip lückenlos weiter.
public struct SplitShot: EditCommand {
    public var point: CutPoint
    public init(at point: CutPoint) { self.point = point }

    public var actionName: String { "Schnitt einfügen" }

    public func apply(to project: inout Project) throws {
        guard var cut = project.cut,
            let index = cut.shots.firstIndex(where: { $0.start.time < point.time && point.time < $0.end.time })
        else { throw EditError.invalidValue("Hier liegt keine Einstellung, die sich teilen lässt.") }
        let shot = cut.shots[index]
        var first = shot
        first.end = point
        let second = Shot(
            id: shot.id + "b", start: point, end: shot.end, clipID: shot.clipID, sceneID: shot.sceneID,
            sourceIn: shot.sourceIn + Rational(seconds: point.time - shot.start.time), locked: shot.locked,
            reasons: shot.reasons.map { ShotReasons(components: [:], total: 0, alternatives: $0.alternatives) })
        cut.shots[index] = first
        cut.shots.insert(second, at: index + 1)
        cut = project.detachingCopies(cut, of: [shot.id])
        cut = cut.renumbered()
        try project.requireCompilable(cut, change: "Teilen")
        project.cut = cut
    }
}

/// ⌫: Einstellung mit der vorigen verschmelzen; die vorige läuft weiter.
public struct MergeShotWithPrevious: EditCommand {
    public var shotID: String
    public init(shotID: String) { self.shotID = shotID }

    public var actionName: String { "Schnitt entfernen" }

    public func apply(to project: inout Project) throws {
        guard var cut = project.cut, let index = cut.shots.firstIndex(where: { $0.id == shotID }), index > 0 else {
            throw EditError.invalidValue("Die erste Einstellung hat keine vorige.")
        }
        let previous = cut.shots[index - 1].id
        cut.shots[index - 1].end = cut.shots[index].end
        cut.shots.remove(at: index)
        cut = project.detachingCopies(cut, of: [previous, shotID])
        cut = cut.renumbered()
        try project.requireCompilable(cut, change: "Verschmelzen")
        project.cut = cut
    }
}

/// Shotkante ziehen (Trimmen wie „Rollen“): Die Grenze zwischen `index` und `index + 1` wandert nach `point`; die
/// folgende Einstellung beginnt ihren Clip entsprechend später oder früher, damit ihr Bild an Ort und Stelle bleibt.
public struct MoveCut: EditCommand {
    public var index: Int
    public var point: CutPoint
    public init(after index: Int, to point: CutPoint) {
        self.index = index
        self.point = point
    }

    public var actionName: String { "Schnitt verschieben" }

    public func apply(to project: inout Project) throws {
        guard var cut = project.cut, index >= 0, index + 1 < cut.shots.count else {
            throw EditError.invalidValue("Diese Schnittkante gibt es nicht.")
        }
        let next = cut.shots[index + 1]
        guard cut.shots[index].start.time < point.time, point.time < next.end.time else {
            throw EditError.invalidValue("Die Kante darf keine Einstellung überspringen.")
        }
        let delta = Rational(seconds: point.time) - Rational(seconds: next.start.time)
        cut.shots[index].end = point
        cut.shots[index + 1].start = point
        cut.shots[index + 1].sourceIn = next.sourceIn + delta
        guard cut.shots[index + 1].sourceIn >= .zero else {
            throw EditError.invalidValue("Schnitt verschieben geht nicht: Der folgende Clip beginnt nicht früh genug.")
        }
        cut = project.detachingCopies(cut, of: [cut.shots[index].id, next.id])
        try project.requireCompilable(cut, change: "Schnitt verschieben")
        project.cut = cut
    }
}

extension Cut {
    /// Shots nach dem Einfügen oder Entfernen wieder `shot-1` … nummerieren; Verweise auf Vorlagen wandern mit.
    func renumbered() -> Cut {
        var mapping: [String: String] = [:]
        for (offset, shot) in shots.enumerated() { mapping[shot.id] = "shot-\(offset + 1)" }
        var result = self
        result.shots = shots.map { shot in
            var reasons = shot.reasons
            reasons?.copiedFrom = shot.reasons?.copiedFrom.flatMap { mapping[$0] }
            return Shot(
                id: mapping[shot.id]!, start: shot.start, end: shot.end, clipID: shot.clipID, sceneID: shot.sceneID,
                sourceIn: shot.sourceIn, locked: shot.locked, reasons: reasons)
        }
        return result
    }
}
