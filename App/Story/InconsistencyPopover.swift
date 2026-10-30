import SwiftUI
import SyllaBeatCore
import SyllaBeatUI

/// Status-Chip „Stimmig“ bzw. „n Ungereimtheiten“ mit Liste, Sprung zur Stelle und Abhilfe.
struct InconsistencyChip: View {
    var project: Project
    var cut: CutController
    var seek: (Double) -> Void
    @State private var shows = false

    private var findings: [Inconsistency] {
        project.cut.map { InconsistencyChecker.check(project, cut: $0) } ?? []
    }

    var body: some View {
        let findings = findings
        if project.cut != nil {
            Button {
                shows.toggle()
            } label: {
                Chip(
                    title: findings.isEmpty
                        ? "Stimmig" : "\(findings.count) Ungereimtheit\(findings.count == 1 ? "" : "en")",
                    systemImage: "exclamationmark.triangle", done: findings.isEmpty)
            }
            .buttonStyle(.plain)
            .help("Was im Schnitt nicht zur Geschichte passt")
            .accessibilityIdentifier("chip.inconsistencies")
            .popover(isPresented: $shows, arrowEdge: .bottom) {
                list(findings).frame(width: 420).padding(14)
            }
        }
    }

    @ViewBuilder
    private func list(_ findings: [Inconsistency]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(findings.isEmpty ? "Alles stimmig" : "Ungereimtheiten").font(.headline)
            if findings.isEmpty {
                Text("Tageszeit, Kapitel und Motive passen zur Geschichte.").foregroundStyle(.secondary)
            }
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: 4) {
                    Label(finding.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if !finding.shotIDs.isEmpty {
                            Button("Zeigen") { show(finding) }
                        }
                        actions(finding)
                    }
                    .controlSize(.small)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("inconsistency.\(finding.kind.rawValue)")
                Divider()
            }
        }
    }

    @ViewBuilder
    private func actions(_ finding: Inconsistency) -> some View {
        switch finding.kind {
        case .timeGoesBack, .chapterOutsidePlan, .sameMotifRepeated, .watermark:
            Button("Neu schneiden") {
                cut.run(RecutShots(shotIDs: Set(finding.shotIDs), textScores: cut.textScores))
                shows = false
            }
        case .copyBreaksTrait:
            Button("Gleiche Clips, andere Ausschnitte") {
                var style = project.style
                style.refrainMode = .sameClips
                cut.setStyle(style)
                shows = false
            }
        case .relaxed, .chapterGoesBack:
            Button("Drehbuch öffnen") {
                shows = false
                cut.showsDrehbuch = true
            }
        case .lineTimingRepaired, .traitUnknown:
            EmptyView()
        }
    }

    private func show(_ finding: Inconsistency) {
        cut.selection = Set(finding.shotIDs)
        if let start = project.cut?.shots.first(where: { finding.shotIDs.contains($0.id) })?.start.time { seek(start) }
        shows = false
    }
}

extension Project {
    /// Ungereimtheiten als Marker in der Bildspur (Anfang der ersten betroffenen Einstellung).
    var inconsistencyMarkers: [TimelineMarker] {
        guard let cut else { return [] }
        let starts = Dictionary(cut.shots.map { ($0.id, $0.start.time) }, uniquingKeysWith: { a, _ in a })
        return InconsistencyChecker.check(self, cut: cut).compactMap { finding in
            finding.shotIDs.first.flatMap { starts[$0] }.map { TimelineMarker(time: $0, message: finding.message) }
        }
    }
}
