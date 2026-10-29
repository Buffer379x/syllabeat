import SwiftUI
import SyllaBeatAI
import SyllaBeatCore

/// Anbieter je Aufgabe und ihre Verbindungsdaten; Schlüssel liegen im Schlüsselbund (F-11).
struct ProviderSettings: View {
    @Environment(AppServices.self) private var services
    @State private var vision: ProviderKind?
    @State private var director: ProviderKind?
    @AppStorage("ai.autoDescribe") private var autoDescribe = true
    @AppStorage("ai.ollama.url") private var ollamaURL = "http://localhost:11434"
    @AppStorage("ai.ollama.model") private var ollamaModel = "qwen2.5vl:7b"
    @AppStorage("ai.openai.url") private var openAIURL = "http://localhost:1234/v1"
    @AppStorage("ai.openai.model") private var openAIModel = ""
    @AppStorage("ai.anthropic.model") private var anthropicModel = AnthropicProvider.defaultModel
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var results: [ProviderKind: String] = [:]
    @State private var testing: Set<ProviderKind> = []
    @State private var anthropicModels: [String] = []

    var body: some View {
        Form {
            Section {
                Picker("Bildbeschreibungen", selection: $vision) {
                    Text("Aus").tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases.filter { $0 != .manual }) { Text($0.title).tag(Optional($0)) }
                }
                .onChange(of: vision) { _, new in AISettings.setKind(new, for: .vision) }
                .accessibilityIdentifier("provider.vision")
                Picker("Regie (Storyboard)", selection: $director) {
                    Text("Aus").tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .onChange(of: director) { _, new in AISettings.setKind(new, for: .director) }
                .accessibilityIdentifier("provider.director")
                Toggle("Neue Clips nach der Analyse automatisch beschreiben", isOn: $autoDescribe)
            } header: {
                Text("Aufgaben")
            } footer: {
                Text(
                    "Empfehlung für diesen Mac: Beschreibungen mit \(AISettings.recommended(for: .vision)?.title ?? "dem lokalen Modell (laden unter Modelle)"), Regie mit \(AISettings.recommended(for: .director)?.title ?? "–"). Cloud-Anbieter starten nie von selbst."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Lokal") {
                connection(.appleIntelligence) { EmptyView() }
                connection(.mlx) { EmptyView() }
            }
            Section("Ollama") {
                TextField("Adresse", text: $ollamaURL)
                TextField("Modell", text: $ollamaModel, prompt: Text("z. B. qwen2.5vl:7b"))
                connection(.ollama) { EmptyView() }
            }
            Section("OpenAI-kompatibel (LM Studio, llama.cpp, OpenAI)") {
                TextField("Adresse", text: $openAIURL)
                SecureField("API-Schlüssel (falls nötig)", text: $openAIKey)
                    .onSubmit { Keychain.write(openAIKey, account: "openai") }
                TextField("Modell", text: $openAIModel)
                connection(.openAICompatible) { EmptyView() }
            }
            Section("Anthropic Claude") {
                SecureField("API-Schlüssel", text: $anthropicKey)
                    .onSubmit { Keychain.write(anthropicKey, account: "anthropic") }
                    .accessibilityIdentifier("provider.anthropic.key")
                Picker("Modell", selection: $anthropicModel) {
                    ForEach(
                        Array(
                            Set(
                                anthropicModels + [
                                    AnthropicProvider.defaultModel, AnthropicProvider.economyModel, anthropicModel,
                                ])
                        )
                        .sorted(), id: \.self
                    ) { Text($0).tag($0) }
                }
                connection(.anthropic) {
                    Button("Modelle abrufen") { Task { await loadAnthropicModels() } }
                        .disabled(anthropicKey.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            vision = AISettings.kind(for: .vision)
            director = AISettings.kind(for: .director)
            openAIKey = Keychain.read("openai") ?? ""
            anthropicKey = Keychain.read("anthropic") ?? ""
        }
        .onDisappear {
            Keychain.write(openAIKey, account: "openai")
            Keychain.write(anthropicKey, account: "anthropic")
        }
    }

    /// Zeile „Verbindung testen“ mit Ergebnis.
    private func connection(_ kind: ProviderKind, @ViewBuilder extra: () -> some View) -> some View {
        LabeledContent {
            HStack {
                extra()
                if testing.contains(kind) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Verbindung testen") { Task { await test(kind) } }
                        .accessibilityIdentifier("provider.test.\(kind.rawValue)")
                }
            }
        } label: {
            Text(kind == .appleIntelligence || kind == .mlx ? kind.title : "Verbindung")
            if let result = results[kind] {
                Text(result).accessibilityIdentifier("provider.result.\(kind.rawValue)")
            }
        }
    }

    private func test(_ kind: ProviderKind) async {
        Keychain.write(openAIKey, account: "openai")
        Keychain.write(anthropicKey, account: "anthropic")
        testing.insert(kind)
        defer { testing.remove(kind) }
        do {
            results[kind] =
                "✓ " + (try await AISettings.provider(of: kind, client: services.inference).testConnection())
        } catch {
            results[kind] = "✗ " + error.localizedDescription
        }
    }

    private func loadAnthropicModels() async {
        Keychain.write(anthropicKey, account: "anthropic")
        do {
            anthropicModels = try await AnthropicProvider(apiKey: anthropicKey).models()
        } catch {
            results[.anthropic] = "✗ " + error.localizedDescription
        }
    }
}

/// Zustimmungen für Cloud-Anbieter: was gesendet werden darf, mit Widerruf.
struct PrivacySettings: View {
    @State private var consents: [Consent] = []

    var body: some View {
        Form {
            Section {
                Text(
                    "Videos verlassen den Mac nie. Cloud-Anbieter bekommen nur, was für die jeweilige Aufgabe nötig ist, und erst nach Zustimmung: für die Regie Songtext, Abschnitte und Regieanweisung, für Bildbeschreibungen kleine Vorschaubilder der Szenen."
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            Section("Erteilte Zustimmungen") {
                if consents.isEmpty {
                    Text("Keine. Vor dem ersten Senden an einen Cloud-Anbieter fragt SyllaBeat nach.")
                        .foregroundStyle(.secondary)
                }
                ForEach(consents, id: \.self) { consent in
                    let (kind, task) = (consent.kind, consent.task)
                    LabeledContent {
                        Button("Widerrufen") {
                            AISettings.setConsent(false, kind, task)
                            consents = Self.current
                        }
                    } label: {
                        Text("\(kind.title): \(task.title)")
                        Text(task.transferredData).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { consents = Self.current }
    }

    struct Consent: Hashable {
        var kind: ProviderKind
        var task: AITask
    }

    static var current: [Consent] { AISettings.consents.map { Consent(kind: $0.kind, task: $0.task) } }
}
