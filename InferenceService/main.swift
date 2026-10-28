// XPC-Dienst SyllaBeatInference: Hier laufen später alle Modelle (MLX, WhisperKit, Core ML).
// Der Dienst beendet sich nach Leerlauf und gibt damit den Modellspeicher frei; launchd startet ihn bei Bedarf neu.
import Darwin
import Foundation
import SyllaBeatAI
import SyllaBeatCore
import Synchronization
import XPC

let started = Date()

/// Merkt sich die letzte Anfrage und beendet den Prozess nach `timeout` Sekunden Ruhe.
final class IdleWatchdog: Sendable {
    private let lastActivity = Mutex(Date())
    private let timeout: TimeInterval
    private let timer: DispatchSourceTimer

    init(timeout: TimeInterval) {
        self.timeout = timeout
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    }

    func touch() {
        lastActivity.withLock { $0 = Date() }
    }

    func start() {
        let interval = min(10, timeout / 4)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [self] in
            let idle = Date().timeIntervalSince(lastActivity.withLock { $0 })
            if idle >= timeout {
                Log.inference.info("Inferenzdienst beendet sich nach \(Int(idle)) s Leerlauf")
                exit(0)
            }
        }
        timer.resume()
    }
}

func residentMemory() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

func handle(_ request: InferenceRequest) -> InferenceResponse {
    switch request {
    case .ping:
        .status(
            InferenceStatus(
                processID: getpid(), version: BuildInfo.version, residentMemoryBytes: residentMemory(),
                uptime: Date().timeIntervalSince(started), idleTimeout: InferenceService.idleTimeout))
    }
}

let watchdog = IdleWatchdog(timeout: InferenceService.idleTimeout)

do {
    let listener = try XPCListener(service: InferenceService.bundleIdentifier) { request in
        request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
            watchdog.touch()
            do {
                return handle(try message.decode(as: InferenceRequest.self))
            } catch {
                return InferenceResponse.failure("Unbekannte Anfrage: \(error.localizedDescription)")
            }
        }
    }
    withExtendedLifetime(listener) {
        watchdog.start()
        Log.inference.info("Inferenzdienst gestartet")
        dispatchMain()
    }
} catch {
    Log.inference.fault("Inferenzdienst konnte nicht starten: \(error.localizedDescription, privacy: .public)")
    exit(1)
}
