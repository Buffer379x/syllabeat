import SwiftUI
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatUI

/// Erster Start (Plan 8.2): „Wie soll SyllaBeat arbeiten?“ Lokal mit dem empfohlenen Modellpaket (Downloads laufen im
/// Hintergrund), mit Cloud-KI oder erst einmal ohne KI. Erscheint einmal; später geht alles über die Einstellungen.
struct WelcomeSheet: View {
    var done: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.openSettings) private var openSettings

    /// Bausteine des lokalen Pakets mit Download-Größe (0 = eingebaut oder schon geladen).
    private var localPackage: [(title: String, bytes: Int64)] {
        var items: [(String, Int64)] = []
        items.append(
            ("Gesangserkennung (Whisper)", TranscriptionModel.isInstalled ? 0 : TranscriptionModel.downloadBytes))
        items.append(
            ("Bildsuche (SigLIP 2)", ModelCatalog.siglip2.isInstalled ? 0 : ModelCatalog.siglip2.downloadBytes))
        if AppleIntelligenceProvider.availability.available && AppleIntelligenceProvider.supportsImages {
            items.append(("Bildbeschreibung und Regie (Apple Intelligence, eingebaut)", 0))
        } else {
            let vision = ModelCatalog.recommendedVision()
            items.append(
                ("Bildbeschreibung und Regie (\(vision.title))", vision.isInstalled ? 0 : vision.downloadBytes))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Willkommen bei SyllaBeat").font(.title2.weight(.semibold))
            Text("Wie soll SyllaBeat arbeiten? Das lässt sich jederzeit in den Einstellungen ändern.")
                .foregroundStyle(.secondary)
            choice(
                title: "Lokal (empfohlen)", systemImage: "desktopcomputer",
                detail: "Alles bleibt auf diesem Mac. "
                    + localPackage.map {
                        $0.bytes > 0 ? "\($0.title): \(Format.bytes(UInt64($0.bytes)))" : "\($0.title) ✓"
                    }
                    .joined(separator: " · "),
                identifier: "welcome.local", action: chooseLocal)
            choice(
                title: "Mit Cloud-KI", systemImage: "cloud",
                detail:
                    "Regie und Beschreibungen über Anthropic, OpenAI oder einen eigenen Server. Vor dem ersten Senden zeigt SyllaBeat, was übertragen wird; Videos verlassen den Mac nie.",
                identifier: "welcome.cloud", action: chooseCloud)
            choice(
                title: "Erst einmal ohne KI", systemImage: "hand.raised",
                detail: "Schnitt nach Beats, Energie und Abwechslung. Regie per Kopieren und Einfügen bleibt möglich.",
                identifier: "welcome.none", action: chooseNone)
        }
        .padding(24)
        .frame(width: 520)
    }

    private func choice(
        title: String, systemImage: String, detail: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage).font(.title2).frame(width: 30).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func chooseLocal() {
        if !TranscriptionModel.isInstalled { services.installTranscription() }
        if !ModelCatalog.siglip2.isInstalled { services.install(ModelCatalog.siglip2) }
        let appleVision = AppleIntelligenceProvider.availability.available && AppleIntelligenceProvider.supportsImages
        if !appleVision, !ModelCatalog.recommendedVision().isInstalled {
            services.install(ModelCatalog.recommendedVision())
        }
        AISettings.setKind(appleVision ? .appleIntelligence : .mlx, for: .vision)
        AISettings.setKind(AppleIntelligenceProvider.availability.available ? .appleIntelligence : .mlx, for: .director)
        done()
    }

    private func chooseCloud() {
        AISettings.setKind(.anthropic, for: .director)
        AISettings.setKind(nil, for: .vision)
        done()
        openSettings()
    }

    private func chooseNone() {
        AISettings.setKind(nil, for: .vision)
        AISettings.setKind(.manual, for: .director)
        done()
    }
}
