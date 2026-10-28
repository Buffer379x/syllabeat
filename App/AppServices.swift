import Foundation
import Observation
import SyllaBeatAI
import SyllaBeatCore

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
