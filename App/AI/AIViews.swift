import AppKit
import SwiftUI
import SyllaBeatAI
import SyllaBeatCore

/// Vor dem ersten Senden an einen Cloud-Anbieter: was genau übertragen wird.
struct ConsentSheet: View {
    var request: AIController.ConsentRequest
    var grant: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Daten an \(request.kind.title) senden?", systemImage: "icloud.and.arrow.up")
                .font(.title3.weight(.semibold))
            Text("Für \(request.task.title) überträgt SyllaBeat \(request.task.transferredData).")
            Text(
                "Videos verlassen den Mac nie. Die Zustimmung gilt für diesen Anbieter und diese Aufgabe; widerrufen lässt sie sich unter Einstellungen → Datenschutz."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Senden erlauben", action: grant)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("consent.grant")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Manueller Anbieter: Prompt kopieren, Antwort eines beliebigen Modells einfügen, Prüfung mit Rückmeldung.
struct ManualExchangeSheet: View {
    var exchange: AIController.ManualExchange
    var ai: AIController
    @State private var answer = ""
    @State private var problems: [String] = []
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storyboard von Hand").font(.title3.weight(.semibold))
            Text("1. Den Prompt kopieren und in ein Chatfenster eines beliebigen Modells einfügen.")
            ScrollView {
                Text(exchange.prompt).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Button(copied ? "Kopiert" : "Prompt kopieren", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(exchange.prompt, forType: .string)
                copied = true
            }
            Text("2. Die Antwort hier einfügen.")
            TextEditor(text: $answer)
                .font(.caption.monospaced())
                .frame(height: 140)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("manual.answer")
            if !problems.isEmpty {
                Label(problems.prefix(3).joined(separator: "; "), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) {
                    ai.manualExchange = nil
                    dismiss()
                }
                Button("Übernehmen") {
                    Task { problems = await ai.submitManualAnswer(answer, for: exchange) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Inspektor-Bereich „Regie“: Regieanweisung, Storyboard erstellen und anzeigen.
struct DirectorSection: View {
    var project: Project
    var ai: AIController
    var run: (any EditCommand) -> Void
    @State private var brief = ""
    @FocusState private var editing: Bool

    var body: some View {
        InspectorSection("Regie") {
            TextField(
                "Regieanweisung", text: $brief,
                prompt: Text("z. B. Liebesgeschichte am Meer, Refrain bei Nacht"), axis: .vertical
            )
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            .focused($editing)
            .onSubmit(commit)
            .accessibilityIdentifier("director.brief")
            HStack {
                Button(
                    project.storyboard == nil ? "Storyboard erstellen" : "Neu erstellen", systemImage: "wand.and.stars"
                ) {
                    commit()
                    ai.createStoryboard()
                }
                .disabled(project.analysis == nil || ai.creatingStoryboard)
                .accessibilityIdentifier("director.create")
                if ai.creatingStoryboard { ProgressView().controlSize(.small) }
                Spacer()
                if project.storyboard != nil {
                    Button("Entfernen", role: .destructive) { Task { await ai.apply(nil) } }
                        .help("Ohne Storyboard neu schneiden (fixierte Einstellungen bleiben)")
                }
            }
            .controlSize(.small)
            Text(providerNote).font(.caption).foregroundStyle(.secondary)
            if let storyboard = project.storyboard {
                Text(storyboard.idea).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("director.idea")
                ForEach(storyboard.sections) { plan in
                    StoryboardRow(plan: plan, label: label(plan.sectionID))
                }
                Text("Von \(storyboard.model)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .onAppear { brief = project.brief }
        .onChange(of: project.brief) { _, new in if !editing { brief = new } }
        .onChange(of: editing) { _, now in if !now { commit() } }
    }

    private var providerNote: String {
        guard let kind = AISettings.kind(for: .director) else {
            return "Kein Anbieter gewählt (Einstellungen → Anbieter)."
        }
        return "Anbieter: \(kind.title)" + (kind.mayBeCloud ? " – vor dem Senden wird gefragt." : "")
    }

    private func label(_ sectionID: String) -> String {
        project.analysis?.sections.first { $0.id == sectionID }?.label ?? sectionID
    }

    private func commit() {
        guard brief != project.brief else { return }
        run(SetBrief(brief: brief))
    }
}

private struct StoryboardRow: View {
    var plan: Storyboard.SectionPlan
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout.weight(.semibold))
                Text(plan.mood).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(plan.pace.title).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if !plan.imageIdea.isEmpty {
                Text(plan.imageIdea).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !plan.searchTerms.isEmpty {
                Text(plan.searchTerms.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
