import SwiftUI
import SyllaBeatCore
import SyllaBeatUI

/// Inspektor einer Einstellung: Bild, Zeiten, Fixieren, Quell-In-Jog, „Warum dieser Clip?“ und Alternativen.
struct ShotInspector: View {
    var shot: Shot
    var project: Project
    var media: MediaController
    var cut: CutController

    private var number: Int { (project.cut?.shots.firstIndex { $0.id == shot.id } ?? 0) + 1 }
    private var clip: Clip? { project.clip(withID: shot.clipID) }
    private var scene: ClipScene? { clip?.scenes.first { $0.id == shot.sceneID } }

    private var beatCount: Int {
        project.analysis?.beats.filter { $0.time >= shot.start.time - 0.001 && $0.time < shot.end.time - 0.001 }.count
            ?? 0
    }

    private var section: SongSection? {
        project.analysis?.sections.first { $0.start <= shot.start.time + 0.001 && shot.start.time + 0.001 < $0.end }
    }

    var body: some View {
        CachedImage(url: clip?.thumbnailURL(scene: scene), generation: media.thumbnailGeneration)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Vorschaubild")
        VStack(alignment: .leading, spacing: 2) {
            Text("Einstellung \(number)").font(.headline)
            Text(clip?.name ?? shot.clipID).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(Format.time(shot.start.time)) – \(Format.time(shot.end.time))").monospacedDigit()
            Text(
                ["\(beatCount) \(beatCount == 1 ? "Beat" : "Beats")", section?.label].compactMap { $0 }.joined(
                    separator: " · ")
            )
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shot.summary")

        HStack {
            Toggle(
                isOn: Binding(
                    get: { shot.locked }, set: { cut.run(SetShotLocked(shotID: shot.id, locked: $0)) })
            ) {
                Label("Fixiert", systemImage: shot.locked ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.button)
            .help("Fixierte Einstellungen bleiben bei „Neu würfeln“ und Stiländerungen stehen (L)")
            .accessibilityIdentifier("shot.lock")
            Button("Neu schneiden", systemImage: "scissors") {
                cut.run(RecutShots(shotIDs: [shot.id], textScores: cut.textScores))
            }
            .help("Nur diese Einstellung neu bestimmen (⇧⌘R für die Auswahl)")
            .disabled(shot.locked)
            .accessibilityIdentifier("shot.recut")
        }
        .controlSize(.small)

        HStack(spacing: 6) {
            Text("Quell-In").foregroundStyle(.secondary)
            Button("Ein Frame zurück", systemImage: "chevron.left") {
                cut.run(NudgeSourceIn(shotID: shot.id, frames: -1))
            }
            Text(Format.time(shot.sourceIn.doubleValue)).monospacedDigit()
            Button("Ein Frame vor", systemImage: "chevron.right") { cut.run(NudgeSourceIn(shotID: shot.id, frames: 1)) }
            Spacer()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Ausschnitt im Clip um ein Quellframe verschieben; die Einstellung wird dabei fixiert.")

        if let source = shot.reasons?.copiedFrom,
            let template = project.cut?.shots.firstIndex(where: { $0.id == source })
        {
            Label(
                "Wiederholung von Einstellung \(template + 1): Änderungen dort gelten auch hier.",
                systemImage: "repeat"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let reasons = shot.reasons, !reasons.components.isEmpty {
            InspectorSection("Warum dieser Clip?") {
                ForEach(CutEngine.Component.allCases, id: \.rawValue) { component in
                    if let value = reasons.components[component.rawValue] {
                        ScoreRow(title: component.title, value: value)
                    }
                }
                Divider()
                Fact("Gesamt", reasons.total.formatted(.number.precision(.fractionLength(2))))
                if let line = lineText {
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !reasons.relaxed.isEmpty {
                    Label(
                        "Ausgewichen (\(reasons.relaxed.map(Self.ruleTitle).joined(separator: ", "))): "
                            + "passendes Material fehlte.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let chapter = project.story.chapter(withID: project.clip(withID: shot.clipID)?.chapterID) {
                    Fact("Kapitel", chapter.name)
                }
            }
            .accessibilityIdentifier("shot.reasons")
        } else if shot.reasons?.copiedFrom == nil {
            Text(shot.locked ? "Von Hand gewählt." : "Keine Begründung gespeichert.")
                .font(.callout).foregroundStyle(.secondary)
        }

        if let alternatives = shot.reasons?.alternatives, !alternatives.isEmpty {
            InspectorSection("Alternativen") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], spacing: 6) {
                    ForEach(Array(alternatives.enumerated()), id: \.offset) { _, alternative in
                        AlternativeTile(alternative: alternative, project: project, media: media) {
                            cut.run(
                                ReplaceShot(
                                    shotID: shot.id, clipID: alternative.clipID, sceneID: alternative.sceneID,
                                    sourceIn: alternative.sourceIn))
                        }
                    }
                }
                Text("Klick ersetzt den Clip und fixiert die Einstellung.").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("shot.alternatives")
        }
    }
}

/// Anteil an der Bewertung als Balken: grün hilft, rot spricht dagegen.
private struct ScoreRow: View {
    var title: String
    var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width * min(1, abs(value) / 1.2)
                ZStack(alignment: value >= 0 ? .leading : .trailing) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(value >= 0 ? Color.green : Color.red).frame(width: max(2, width))
                }
            }
            .frame(width: 60, height: 6)
            Text(value.formatted(.number.precision(.fractionLength(2))))
                .font(.callout.monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AlternativeTile: View {
    var alternative: ShotReasons.Alternative
    var project: Project
    var media: MediaController
    var choose: () -> Void

    private var clip: Clip? { project.clip(withID: alternative.clipID) }

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 2) {
                CachedImage(
                    url: clip?.thumbnailURL(scene: clip?.scenes.first { $0.id == alternative.sceneID }),
                    generation: media.thumbnailGeneration
                )
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(clip?.name ?? alternative.clipID).font(.caption2).lineLimit(1).truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .help(
            "\(clip?.name ?? alternative.clipID) · Bewertung \(alternative.score.formatted(.number.precision(.fractionLength(2))))"
        )
        .accessibilityLabel("Alternative \(clip?.name ?? alternative.clipID)")
    }
}

extension ShotInspector {
    static func ruleTitle(_ rule: String) -> String {
        rule == "kapitel" ? "Kapitel" : rule == Trait.timeOfDay.id ? "Tageszeit" : rule
    }

    /// Text-Treffer in Klartext: welche Zeile, und ob sie einen deutlichen Treffer hat.
    var lineText: String? {
        guard let lines = project.analysis?.lines else { return nil }
        func overlap(_ line: LyricLine) -> Double {
            max(0, min(line.end, shot.end.time) - max(line.start, shot.start.time))
        }
        guard let line = lines.max(by: { overlap($0) < overlap($1) }), overlap(line) > 0 else { return nil }
        let clear = cut.textScores.values[line.id].map { CutEngine.gateConfidence($0) >= 0.6 } ?? false
        return clear ? "Deutlicher Text-Treffer: „\(line.text)“" : "Kein klarer Text-Treffer: „\(line.text)“"
    }
}
