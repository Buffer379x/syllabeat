import Foundation
import Observation
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatMedia

/// Dienste, die alle Fenster teilen: Aufgabenzentrale und Inferenzdienst.
@MainActor
@Observable
final class AppServices {
    let jobs = JobCenter()
    @ObservationIgnored let inference = InferenceClient()

    enum InferenceCheck: Equatable {
        case unknown, checking
        case available(InferenceStatus)
        case failed(String)
    }

    private(set) var inferenceCheck = InferenceCheck.unknown
    private(set) var cacheBytes: Int64?
    /// Zählt Installationen und Löschungen, damit Ansichten Modell- und Komponentenstatus neu lesen.
    private(set) var installGeneration = 0
    private(set) var installing: Set<String> = []

    init() {
        trimCache()
    }

    // MARK: - Zwischenspeicher

    static let cacheLimitKey = "cacheLimitGB"

    var cacheLimitGB: Int {
        get { UserDefaults.standard.object(forKey: Self.cacheLimitKey) as? Int ?? 10 }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.cacheLimitKey)
            trimCache()
        }
    }

    /// Hält den Zwischenspeicher unter dem Limit (älteste Clips zuerst) und misst danach die Größe.
    func trimCache() {
        let limit = Int64(cacheLimitGB) * 1_000_000_000
        Task.detached(priority: .utility) { [weak self] in
            let cache = MediaCache()
            try? cache.trim(toBytes: limit)
            let size = cache.size()
            await MainActor.run { self?.cacheBytes = size }
        }
    }

    func clearCache() {
        Task.detached(priority: .userInitiated) { [weak self] in
            try? MediaCache().clear()
            await MainActor.run { self?.cacheBytes = 0 }
        }
    }

    // MARK: - Modelle und Komponenten

    func install(_ package: ModelPackage) {
        guard !installing.contains(package.id) else { return }
        installing.insert(package.id)
        jobs.submit("\(package.title) laden", resource: .network) { [weak self] context in
            let owner = self
            defer { Task { @MainActor in owner?.finishInstall(package.id) } }
            try await package.install { fraction in
                Task { await context.progress(fraction, detail: "\(Int(fraction * 100)) %") }
            }
        }
    }

    func uninstall(_ package: ModelPackage) {
        try? package.uninstall()
        installGeneration += 1
    }

    func installFFmpeg() {
        guard !installing.contains("ffmpeg") else { return }
        installing.insert("ffmpeg")
        jobs.submit("ffmpeg laden", resource: .network) { [weak self] context in
            let owner = self
            defer { Task { @MainActor in owner?.finishInstall("ffmpeg") } }
            _ = try await FFmpeg.install { fraction in
                Task { await context.progress(fraction, detail: "\(Int(fraction * 100)) %") }
            }
        }
    }

    func uninstallFFmpeg() {
        try? FFmpeg.uninstall()
        installGeneration += 1
    }

    private func finishInstall(_ id: String) {
        installing.remove(id)
        installGeneration += 1
    }

    /// Prüft den XPC-Dienst als Aufgabe in der Aufgabenzentrale.
    func checkInference() {
        guard inferenceCheck != .checking else { return }
        inferenceCheck = .checking
        let client = inference
        jobs.submit("Inferenzdienst prüfen", resource: .inference) { [weak self] context in
            await context.progress(nil, detail: "Verbindung wird aufgebaut …")
            let result: InferenceCheck
            do {
                result = .available(try await client.status())
            } catch {
                result = .failed(error.localizedDescription)
            }
            await MainActor.run { self?.inferenceCheck = result }
            if case .failed(let reason) = result { throw InferenceError.unavailable(reason) }
        }
    }
}
