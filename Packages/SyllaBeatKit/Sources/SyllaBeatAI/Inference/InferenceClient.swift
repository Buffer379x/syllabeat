import Foundation
import SyllaBeatCore
import XPC

/// Verbindung der App zum XPC-Dienst. Die Sitzung wird bei Bedarf aufgebaut und nach einem Fehler neu erstellt.
public actor InferenceClient {
    private let serviceName: String
    private var session: XPCSession?

    public init(serviceName: String = InferenceService.bundleIdentifier) {
        self.serviceName = serviceName
    }

    public func status() async throws -> InferenceStatus {
        switch try await send(.ping) {
        case .status(let status): return status
        case .failure(let reason): throw InferenceError.remote(reason)
        }
    }

    private func send(_ request: InferenceRequest) async throws -> InferenceResponse {
        let session = try connect()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try session.send(request) { (result: Result<InferenceResponse, any Error>) in
                        continuation.resume(with: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            self.session?.cancel(reason: "Fehler")
            self.session = nil
            Log.inference.error("XPC-Anfrage fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            throw InferenceError.unavailable(error.localizedDescription)
        }
    }

    private func connect() throws -> XPCSession {
        if let session { return session }
        do {
            let session = try XPCSession(xpcService: serviceName) { [weak self] (error: XPCRichError) in
                Task { await self?.dropSession() }
                Log.inference.notice("XPC-Sitzung beendet: \(error.localizedDescription, privacy: .public)")
            }
            self.session = session
            return session
        } catch {
            throw InferenceError.unavailable(error.localizedDescription)
        }
    }

    private func dropSession() {
        session = nil
    }
}
