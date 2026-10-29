import Foundation
import Synchronization

/// Blockierende Medienzugriffe (AVAssetReader-Schleifen) laufen auf einer eigenen Queue statt im Thread-Pool von
/// Swift Concurrency. Sonst können wenige Kerne vollständig blockiert werden, während AVFoundation auf genau diesen
/// Pool wartet.
enum Blocking {
    private static let queue = DispatchQueue(
        label: "de.syllabeat.media.reading", qos: .userInitiated, attributes: .concurrent)

    /// Abbruchsignal für die blockierende Arbeit; die Schleife fragt es regelmäßig ab.
    final class Cancellation: Sendable {
        private let flag = Atomic(false)
        var isCancelled: Bool { flag.load(ordering: .relaxed) }
        func cancel() { flag.store(true, ordering: .relaxed) }

        func check() throws {
            if isCancelled { throw CancellationError() }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable (Cancellation) throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with: Result { try work(cancellation) }) }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// AVFoundation-Objekte werden nur innerhalb einer Leseoperation benutzt und nicht geteilt.
struct Unshared<Value>: @unchecked Sendable {
    let value: Value
}
