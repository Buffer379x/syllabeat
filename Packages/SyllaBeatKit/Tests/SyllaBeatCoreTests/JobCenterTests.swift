import Foundation
import Synchronization
import Testing

@testable import SyllaBeatCore

/// Zählt gleichzeitig laufende Aufgaben und merkt sich das Maximum.
private final class Concurrency: Sendable {
    private let state = Mutex((current: 0, peak: 0))

    func enter() {
        state.withLock { counter in
            counter.current += 1
            counter.peak = max(counter.peak, counter.current)
        }
    }
    func leave() { state.withLock { $0.current -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
}

@MainActor
@Suite struct JobCenterTests {
    @Test func inferenceRunsOneAtATime() async {
        let center = JobCenter()
        let counter = Concurrency()
        for index in 0..<4 {
            center.submit("Modell \(index)", resource: .inference) { _ in
                counter.enter()
                try await Task.sleep(for: .milliseconds(20))
                counter.leave()
            }
        }
        await center.waitUntilIdle()
        #expect(counter.peak == 1)
        #expect(center.jobs.allSatisfy { $0.state == .finished })
    }

    @Test func ioRunsInParallel() async {
        let center = JobCenter(limits: [.io: 3])
        let counter = Concurrency()
        for index in 0..<6 {
            center.submit("Datei \(index)", resource: .io) { _ in
                counter.enter()
                try await Task.sleep(for: .milliseconds(50))
                counter.leave()
            }
        }
        await center.waitUntilIdle()
        #expect(counter.peak == 3)
    }

    @Test func cancelsRunningAndWaitingJobs() async {
        let center = JobCenter()
        let running = center.submit("lang", resource: .inference) { _ in
            try await Task.sleep(for: .seconds(30))
        }
        let waiting = center.submit("wartet", resource: .inference) { _ in }
        try? await Task.sleep(for: .milliseconds(20))
        center.cancel(waiting)
        center.cancel(running)
        await center.waitUntilIdle()
        #expect(center.jobs.first { $0.id == running }?.state == .cancelled)
        #expect(center.jobs.first { $0.id == waiting }?.state == .cancelled)
        // Die Ressource ist danach wieder frei.
        center.submit("danach", resource: .inference) { _ in }
        await center.waitUntilIdle()
        #expect(center.jobs.last?.state == .finished)
    }

    @Test func reportsProgressAndFailure() async {
        struct Broken: LocalizedError { var errorDescription: String? { "Datei fehlt" } }
        let center = JobCenter()
        let ok = center.submit("Analyse", resource: .io) { context in
            await context.progress(0.5, detail: "Hälfte")
        }
        let failing = center.submit("Defekt", resource: .io) { _ in throw Broken() }
        await center.waitUntilIdle()
        let job = center.jobs.first { $0.id == ok }
        #expect(job?.detail == "Hälfte" && job?.progress == 1)
        #expect(center.jobs.first { $0.id == failing }?.state == .failed("Datei fehlt"))
        center.clearFinished()
        #expect(center.jobs.isEmpty)
    }

    @Test func estimatesRemainingTime() {
        let start = Date(timeIntervalSince1970: 0)
        let job = JobInfo(
            id: UUID(), title: "x", resource: .io, state: .running, progress: 0.25, detail: "", startedAt: start)
        #expect(job.remainingTime(now: start.addingTimeInterval(10)) == 30)
    }
}
