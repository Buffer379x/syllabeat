import Foundation
import Synchronization

/// Blockierende Medienzugriffe (AVAssetReader-Schleifen) laufen auf einer eigenen Queue statt im Thread-Pool von
/// Swift Concurrency. Sonst können wenige Kerne vollständig blockiert werden, während AVFoundation auf genau diesen
/// Pool wartet.
public enum Blocking {
    private static let queue = DispatchQueue(
        label: "de.syllabeat.blocking", qos: .userInitiated, attributes: .concurrent)

    /// Abbruchsignal für die blockierende Arbeit; die Schleife fragt es regelmäßig ab.
    public final class Cancellation: Sendable {
        private let flag = Atomic(false)
        public var isCancelled: Bool { flag.load(ordering: .relaxed) }
        public func cancel() { flag.store(true, ordering: .relaxed) }

        public func check() throws {
            if isCancelled { throw CancellationError() }
        }
    }

    public static func run<T: Sendable>(_ work: @escaping @Sendable (Cancellation) throws -> T) async throws -> T {
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
public struct Unshared<Value>: @unchecked Sendable {
    public let value: Value
    public init(value: Value) { self.value = value }
}
