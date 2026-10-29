import Foundation
import Security
import SyllaBeatAI
import SyllaBeatCore

/// Wofür ein Modell gebraucht wird.
enum AITask: String, CaseIterable, Identifiable {
    /// Bildbeschreibungen (F-12), braucht Bildeingabe.
    case vision
    /// KI-Regie, Storyboard (F-13).
    case director

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vision: "Bildbeschreibungen"
        case .director: "Regie (Storyboard)"
        }
    }

    /// Was an einen Cloud-Anbieter ginge (für die Zustimmung).
    var transferredData: String {
        switch self {
        case .vision: "die Vorschaubilder der Szenen (je Clip bis zu sechs Bilder mit 320 Pixeln Breite)"
        case .director: "Songtext, Abschnittsnamen und -zeiten sowie die Regieanweisung"
        }
    }
}

/// Anbieter-Einstellungen: Auswahl je Aufgabe und Verbindungsdaten in den Einstellungen, API-Schlüssel im
/// Schlüsselbund. Zustimmungen für Cloud-Anbieter gelten je Anbieter und Aufgabe.
enum AISettings {
    private static var defaults: UserDefaults { .standard }

    /// Gewählter Anbieter; `nil` heißt: aus. Ohne Auswahl gilt die Empfehlung für diesen Mac.
    static func kind(for task: AITask) -> ProviderKind? {
        if let raw = defaults.string(forKey: "ai.\(task.rawValue).provider") {
            return raw == "off" ? nil : ProviderKind(rawValue: raw)
        }
        return recommended(for: task)
    }

    static func setKind(_ kind: ProviderKind?, for task: AITask) {
        defaults.set(kind?.rawValue ?? "off", forKey: "ai.\(task.rawValue).provider")
    }

    /// Apple Intelligence, wenn verfügbar (Bilder erst ab macOS 27), sonst das lokale MLX-Modell, sonst manuell bzw. aus.
    static func recommended(for task: AITask) -> ProviderKind? {
        let apple = AppleIntelligenceProvider.availability.available
        switch task {
        case .vision:
            if apple && AppleIntelligenceProvider.supportsImages { return .appleIntelligence }
            return installedMLX != nil ? .mlx : nil
        case .director:
            if apple { return .appleIntelligence }
            return installedMLX != nil ? .mlx : .manual
        }
    }

    /// Geladenes Qwen3-VL (bevorzugt die Empfehlung für diesen Mac).
    static var installedMLX: ModelPackage? {
        let recommended = ModelCatalog.recommendedVision()
        if recommended.isInstalled { return recommended }
        return [ModelCatalog.qwen3VL8bit, ModelCatalog.qwen3VL4bit].first(where: \.isInstalled)
    }

    /// `client`: die gemeinsame Verbindung der App zum Inferenzdienst (eine XPC-Sitzung für alles).
    static func provider(for task: AITask, client: InferenceClient) -> (any LanguageModelProvider)? {
        kind(for: task).map { provider(of: $0, client: client) }
    }

    static func provider(of kind: ProviderKind, client: InferenceClient) -> any LanguageModelProvider {
        switch kind {
        case .appleIntelligence: AppleIntelligenceProvider()
        case .mlx: MLXProvider(package: installedMLX ?? ModelCatalog.recommendedVision(), client: client)
        case .ollama: OllamaProvider(baseURL: url(ollamaURL, fallback: "http://localhost:11434"), model: ollamaModel)
        case .openAICompatible:
            OpenAICompatibleProvider(
                baseURL: url(openAIURL, fallback: "http://localhost:1234/v1"),
                apiKey: Keychain.read("openai").flatMap { $0.isEmpty ? nil : $0 }, model: openAIModel)
        case .anthropic: AnthropicProvider(apiKey: Keychain.read("anthropic") ?? "", model: anthropicModel)
        case .manual: ManualProvider()
        }
    }

    private static func url(_ text: String, fallback: String) -> URL {
        URL(string: text.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 }
            ?? URL(string: fallback)!
    }

    static var ollamaURL: String {
        get { defaults.string(forKey: "ai.ollama.url") ?? "http://localhost:11434" }
        set { defaults.set(newValue, forKey: "ai.ollama.url") }
    }

    static var ollamaModel: String {
        get { defaults.string(forKey: "ai.ollama.model") ?? "qwen2.5vl:7b" }
        set { defaults.set(newValue, forKey: "ai.ollama.model") }
    }

    static var openAIURL: String {
        get { defaults.string(forKey: "ai.openai.url") ?? "http://localhost:1234/v1" }
        set { defaults.set(newValue, forKey: "ai.openai.url") }
    }

    static var openAIModel: String {
        get { defaults.string(forKey: "ai.openai.model") ?? "" }
        set { defaults.set(newValue, forKey: "ai.openai.model") }
    }

    static var anthropicModel: String {
        get { defaults.string(forKey: "ai.anthropic.model") ?? AnthropicProvider.defaultModel }
        set { defaults.set(newValue, forKey: "ai.anthropic.model") }
    }

    /// Neue Clips nach der Analyse automatisch beschreiben.
    static var autoDescribe: Bool {
        // `bool(forKey:)` versteht auch „NO“/„YES“ aus Startargumenten.
        defaults.object(forKey: "ai.autoDescribe") == nil ? true : defaults.bool(forKey: "ai.autoDescribe")
    }

    /// Nur MLX belegt den Inferenzdienst; Apple Intelligence läuft im App-Prozess, Ollama und Cloud über das Netz.
    /// So wartet ein kurzes Storyboard nicht hinter einer langen Beschreibungsaufgabe.
    static func resource(for provider: any LanguageModelProvider) -> ResourceClass {
        provider.kind == .mlx ? .inference : .network
    }

    // MARK: - Zustimmung für Cloud-Anbieter

    static func consentKey(_ kind: ProviderKind, _ task: AITask) -> String {
        "ai.consent.\(kind.rawValue).\(task.rawValue)"
    }

    static func hasConsent(_ kind: ProviderKind, _ task: AITask) -> Bool {
        defaults.bool(forKey: consentKey(kind, task))
    }

    static func setConsent(_ granted: Bool, _ kind: ProviderKind, _ task: AITask) {
        defaults.set(granted, forKey: consentKey(kind, task))
    }

    /// Erteilte Zustimmungen (für die Übersicht unter Datenschutz).
    static var consents: [(kind: ProviderKind, task: AITask)] {
        ProviderKind.allCases.flatMap { kind in AITask.allCases.map { (kind, $0) } }.filter { hasConsent($0.0, $0.1) }
    }
}

/// API-Schlüssel im Schlüsselbund (generisches Passwort, Dienst `de.syllabeat.app.ai`).
enum Keychain {
    static let service = "de.syllabeat.app.ai"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
