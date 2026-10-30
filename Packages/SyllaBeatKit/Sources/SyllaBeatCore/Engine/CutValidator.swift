import Foundation

/// Prüft die Invarianten I1–I5, I8 und I9 eines Schnitts (Plan Abschnitt 10.1). I6 (Determinismus) und I7 (Exporte) prüfen
/// die Tests direkt.
public enum CutValidator {
    /// `minimumFactor`: Anteil der Mindestdauer, den jeder freie Shot erreichen muss (nach Rasterkorrekturen ½).
    public static func validate(
        _ project: Project, cut: Cut, previous: Cut? = nil, minimumFactor: Double = 1
    )
        -> [String]
    {
        var issues: [String] = []
        guard let analysis = project.analysis else { return ["Keine Songanalyse."] }
        // I1: lückenlos, überlappungsfrei, von 0 bis Songende.
        if cut.shots.first?.start.time != 0 { issues.append("I1: Der Schnitt beginnt nicht bei 0.") }
        if let last = cut.shots.last, abs(last.end.time - analysis.duration) > 1e-9 {
            issues.append("I1: Der Schnitt endet nicht am Songende.")
        }
        for (a, b) in zip(cut.shots, cut.shots.dropFirst()) where a.end.time != b.start.time {
            issues.append("I1: Lücke oder Überlappung zwischen \(a.id) und \(b.id).")
        }
        // I2: Mindestdauer. Ausgenommen sind fixierte Shots (sie können aus einem anderen Stil stammen) und Reste,
        // die auf beiden Seiten an Fixiertes oder an Songanfang/-ende grenzen: Dort gibt es nichts zu verschmelzen.
        let minimum = project.style.minimumDuration * minimumFactor - 1e-9
        for (index, shot) in cut.shots.enumerated() where !shot.locked && shot.duration < minimum {
            let before = index == 0 || cut.shots[index - 1].locked
            let after = index == cut.shots.count - 1 || cut.shots[index + 1].locked
            if before && after { continue }
            issues.append("I2: \(shot.id) ist kürzer als die Mindestdauer (\(shot.duration) s).")
        }
        // I2 und I3: einmal runden, jeder Shot ≥ 1 Frame, Summe = Songlänge, genug Quellmaterial.
        do {
            let table = try CutCompiler.compile(project, cut: cut)
            let total = table.entries.reduce(Int64(0)) { $0 + $1.durationFrames }
            if total != FrameMath.frame(atSeconds: analysis.duration, rate: project.timeline.fps) {
                issues.append("I2: Summe der Frames ≠ Songlänge.")
            }
        } catch CompileError.blocked {
            // Wird unten als I8 gemeldet.
        } catch {
            issues.append("I2/I3: \(error.localizedDescription)")
        }
        // I8: kein Shot berührt einen Sperrbereich.
        let clips = Dictionary(project.clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, shot) in cut.shots.enumerated() {
            do {
                _ = try CutCompiler.entry(shot, number: index + 1, clips: clips, rate: project.timeline.fps)
            } catch CompileError.blocked {
                issues.append("I8: \(shot.id) liegt in einem Sperrbereich.")
            } catch {}
        }
        // I4: Wiederholungen im Modus „identisch“ zeigen dieselben Clips und Quell-Ins wie ihre Vorlage.
        if project.style.refrainMode == .identical {
            for shot in cut.shots {
                guard let source = shot.reasons?.copiedFrom, let template = cut.shots.first(where: { $0.id == source })
                else { continue }
                if template.clipID != shot.clipID || template.sourceIn != shot.sourceIn {
                    issues.append("I4: \(shot.id) weicht von seiner Vorlage \(source) ab.")
                }
            }
        }
        // I9: Mit Drehbuch liegt jeder freie Shot in einem erlaubten Kapitel seines Abschnitts oder ist als
        // ausgewichen vermerkt.
        if !project.story.plan.isEmpty {
            let sections = SlotPlanner.normalizedSections(analysis)
            for shot in cut.shots where !shot.locked && shot.reasons?.copiedFrom == nil {
                let middle = (shot.start.time + shot.end.time) / 2
                guard let section = sections.first(where: { $0.start <= middle && middle < $0.end }),
                    let entry = project.story.plan[section.id] ?? section.repeatOf.flatMap({ project.story.plan[$0] }),
                    !entry.isEmpty
                else { continue }
                let chapter = project.clip(withID: shot.clipID)?.chapterID
                if !(chapter.map { entry[$0] != nil } ?? false), !(shot.reasons?.relaxed.contains("kapitel") ?? false) {
                    issues.append("I9: \(shot.id) liegt außerhalb der Kapitel seines Abschnitts.")
                }
            }
        }
        // I5: fixierte Shots unverändert.
        for locked in previous?.shots.filter(\.locked) ?? [] {
            let kept = cut.shots.contains {
                $0.locked && $0.clipID == locked.clipID && $0.sourceIn == locked.sourceIn
                    && $0.start.time == locked.start.time && $0.end.time == locked.end.time
            }
            if !kept { issues.append("I5: Der fixierte Shot ab \(locked.start.time) s wurde verändert.") }
        }
        return issues
    }
}
