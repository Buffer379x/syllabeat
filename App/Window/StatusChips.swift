import SwiftUI
import SyllaBeatCore

/// Zustände des Projekts statt Seiten: Clips, Song, Schnitt.
struct StatusChips: View {
    var project: Project

    var body: some View {
        HStack(spacing: 6) {
            Chip(
                title: project.clips.isEmpty ? "Keine Clips" : "Clips \(project.clips.count)",
                systemImage: "film.stack", done: !project.clips.isEmpty
            )
            .accessibilityIdentifier("chip.clips")
            Chip(title: songTitle, systemImage: "music.note", done: project.analysis != nil)
                .accessibilityIdentifier("chip.song")
            Chip(title: cutTitle, systemImage: "scissors", done: project.cut != nil)
                .accessibilityIdentifier("chip.cut")
        }
    }

    private var songTitle: String {
        guard let analysis = project.analysis else {
            return project.song == nil ? "Kein Song" : "Song nicht analysiert"
        }
        let bpm = analysis.tempo > 0 ? "\(Int(analysis.tempo.rounded())) BPM · " : ""
        return "\(bpm)\(analysis.beats.count) Beats"
    }

    private var cutTitle: String {
        guard let cut = project.cut else { return "Kein Schnitt" }
        return "\(cut.shots.count) Einstellungen"
    }
}

struct Chip: View {
    var title: String
    var systemImage: String
    var done: Bool

    var body: some View {
        Label {
            Text(title).monospacedDigit()
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : systemImage)
                .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "erledigt" : "offen")
    }
}

/// Symbol der Aufgabenzentrale mit Fortschrittsring; das Popover listet alle Aufgaben.
struct JobCenterButton: View {
    @Environment(AppServices.self) private var services
    @State private var showsPopover = false

    var body: some View {
        let jobs = services.jobs
        Button {
            showsPopover.toggle()
        } label: {
            ZStack {
                if let progress = jobs.overallProgress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                } else if !jobs.activeJobs.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checklist")
                }
            }
            .frame(width: 22)
        }
        .help(jobs.activeJobs.isEmpty ? "Aufgaben" : "\(jobs.activeJobs.count) Aufgaben laufen")
        .accessibilityLabel("Aufgaben")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            JobList(center: jobs).frame(width: 340).padding(12)
        }
    }
}

struct JobList: View {
    var center: JobCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Aufgaben").font(.headline)
                Spacer()
                if center.jobs.contains(where: { !$0.state.isActive }) {
                    Button("Erledigte entfernen") { center.clearFinished() }.buttonStyle(.link)
                }
            }
            if center.jobs.isEmpty {
                Text("Keine Aufgaben. Analysen laufen hier im Hintergrund und lassen sich abbrechen.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(center.jobs.reversed()) { job in
                JobRow(job: job) { center.cancel(job.id) }
            }
        }
    }
}

private struct JobRow: View {
    var job: JobInfo
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.title)
                Spacer()
                if job.state.isActive {
                    Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Abbrechen")
                        .accessibilityLabel("\(job.title) abbrechen")
                }
            }
            switch job.state {
            case .waiting: Text("Wartet …").font(.caption).foregroundStyle(.secondary)
            case .running:
                if let progress = job.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            case .finished: Label("Fertig", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            case .cancelled: Label("Abgebrochen", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var detail: String {
        guard let remaining = job.remainingTime() else { return job.detail }
        let text = Duration.seconds(remaining).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        return job.detail.isEmpty ? "noch \(text)" : "\(job.detail) · noch \(text)"
    }
}
