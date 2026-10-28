import Foundation
import Observation

/// Ressourcenklassen der Aufgabenzentrale. Jede Klasse hat eine eigene Obergrenze gleichzeitiger Aufgaben.
public enum ResourceClass: String, Sendable, CaseIterable {
    /// Dekodierung und Dateizugriffe: parallel, so viele wie Performance-Kerne.
    case io
    /// GPU/ANE-Inferenz: immer nur eine Aufgabe.
    case inference
    /// Netzwerk: parallel, begrenzt.
    case network

    public var defaultLimit: Int {
        switch self {
        case .io: max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        case .inference: 1
        case .network: 4
        }
    }
}

/// Zustand einer Aufgabe, wie ihn die Oberfläche zeigt.
public struct JobInfo: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case waiting, running, finished, cancelled
        case failed(String)

        public var isActive: Bool { self == .waiting || self == .running }
    }

    public let id: UUID
    public var title: String
    public var resource: ResourceClass
    public var state: State
    /// 0…1, `nil` solange unbekannt.
    public var progress: Double?
    public var detail: String
    public var startedAt: Date?
    public var finishedAt: Date?

    /// Geschätzte Restzeit aus dem bisherigen Fortschritt.
    public func remainingTime(now: Date = Date()) -> TimeInterval? {
        guard state == .running, let startedAt, let progress, progress > 0.02, progress < 1 else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        return elapsed * (1 - progress) / progress
    }
}

/// Was eine laufende Aufgabe melden kann.
public struct JobContext: Sendable {
    public let id: UUID
    let report: @Sendable (Double?, String?) async -> Void

    /// Meldet Fortschritt (0…1) und optional einen Text wie „Clip 3 von 40“.
    public func progress(_ fraction: Double?, detail: String? = nil) async {
        await report(fraction.map { min(max($0, 0), 1) }, detail)
    }
}

/// Aufgabenzentrale: Warteschlange je Ressourcenklasse, Fortschritt, Abbruch. Nie blockierend.
@MainActor
@Observable
public final class JobCenter {
    public private(set) var jobs: [JobInfo] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let limiter: ResourceLimiter

    public init(limits: [ResourceClass: Int] = [:]) {
        limiter = ResourceLimiter(limits: limits)
    }

    public var activeJobs: [JobInfo] { jobs.filter(\.state.isActive) }

    /// Mittlerer Fortschritt aller aktiven Aufgaben, für den Ring in der Werkzeugleiste.
    public var overallProgress: Double? {
        let values = activeJobs.compactMap(\.progress)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    @discardableResult
    public func submit(
        _ title: String, resource: ResourceClass, priority: TaskPriority = .medium,
        work: @escaping @Sendable (JobContext) async throws -> Void
    ) -> UUID {
        let id = UUID()
        jobs.append(JobInfo(id: id, title: title, resource: resource, state: .waiting, progress: nil, detail: ""))
        let limiter = limiter
        let context = JobContext(id: id) { [weak self] fraction, detail in
            await self?.update(id) { job in
                if let fraction { job.progress = fraction }
                if let detail { job.detail = detail }
            }
        }
        tasks[id] = Task(priority: priority) { [weak self] in
            do {
                try await limiter.acquire(resource)
            } catch {
                self?.finish(id, state: .cancelled)
                return
            }
            self?.update(id) { job in
                job.state = .running
                job.startedAt = Date()
            }
            let state: JobInfo.State
            do {
                try Task.checkCancellation()
                try await work(context)
                state = .finished
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = .failed(error.localizedDescription)
            }
            await limiter.release(resource)
            self?.finish(id, state: state)
        }
        Log.jobs.info("Aufgabe gestartet: \(title, privacy: .public) [\(resource.rawValue, privacy: .public)]")
        return id
    }

    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    public func cancelAll() {
        tasks.values.forEach { $0.cancel() }
    }

    /// Entfernt beendete Aufgaben aus der Liste.
    public func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    /// Wartet, bis alle aktuell bekannten Aufgaben beendet sind (für Tests und `sbtool`).
    public func waitUntilIdle() async {
        for task in Array(tasks.values) { await task.value }
    }

    private func update(_ id: UUID, _ change: (inout JobInfo) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func finish(_ id: UUID, state: JobInfo.State) {
        update(id) { job in
            job.state = state
            job.finishedAt = Date()
            if state == .finished { job.progress = 1 }
        }
        tasks[id] = nil
        if case .failed(let reason) = state {
            Log.jobs.error("Aufgabe fehlgeschlagen: \(reason, privacy: .public)")
        }
    }
}

/// Begrenzt gleichzeitige Aufgaben je Ressourcenklasse. Wartende werden der Reihe nach bedient
/// und können abgebrochen werden.
actor ResourceLimiter {
    private var limits: [ResourceClass: Int]
    private var running: [ResourceClass: Int] = [:]
    private var waiting: [ResourceClass: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)]] = [:]

    init(limits: [ResourceClass: Int]) {
        self.limits = Dictionary(uniqueKeysWithValues: ResourceClass.allCases.map { ($0, $0.defaultLimit) })
        self.limits.merge(limits) { _, new in max(1, new) }
    }

    func acquire(_ resource: ResourceClass) async throws {
        try Task.checkCancellation()
        if running[resource, default: 0] < limits[resource, default: 1], waiting[resource, default: []].isEmpty {
            running[resource, default: 0] += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[resource, default: []].append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, resource: resource) }
        }
    }

    func release(_ resource: ResourceClass) {
        if var queue = waiting[resource], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[resource] = queue
            next.continuation.resume()
        } else {
            running[resource, default: 1] -= 1
        }
    }

    private func cancelWaiter(_ id: UUID, resource: ResourceClass) {
        guard let index = waiting[resource]?.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiting[resource]!.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func runningCount(_ resource: ResourceClass) -> Int { running[resource, default: 0] }
}
