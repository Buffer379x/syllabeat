// XPC-Dienst SyllaBeatInference: Hier laufen später alle Modelle (MLX, WhisperKit, Core ML).
// Der Dienst beendet sich nach Leerlauf und gibt damit den Modellspeicher frei; launchd startet ihn bei Bedarf neu.
import Darwin
import Foundation
import SyllaBeatAI
import SyllaBeatCore
import SyllaBeatModels
import Synchronization
import XPC

let started = Date()

/// Merkt sich die letzte Anfrage und beendet den Prozess nach `timeout` Sekunden Ruhe (nie während einer Anfrage).
final class IdleWatchdog: Sendable {
    private let lastActivity = Mutex(Date())
    private let active = Mutex(0)
    private let timeout: TimeInterval
    private let timer: DispatchSourceTimer

    init(timeout: TimeInterval) {
        self.timeout = timeout
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    }

    func begin() {
        active.withLock { $0 += 1 }
        lastActivity.withLock { $0 = Date() }
    }

    func end() {
        active.withLock { $0 -= 1 }
        lastActivity.withLock { $0 = Date() }
    }

    func start() {
        let interval = min(10, timeout / 4)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [self] in
            let idle = Date().timeIntervalSince(lastActivity.withLock { $0 })
            if idle >= timeout, active.withLock({ $0 }) == 0 {
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

/// Hält die geladenen Modelle; Anfragen laufen nacheinander (eine GPU-Aufgabe zur Zeit).
actor Engine {
    private var siglip: SiglipEmbedder?
    private var whisper: WhisperTranscriber?

    private func transcriber() async throws -> WhisperTranscriber {
        if let whisper { return whisper }
        let loaded = try await WhisperTranscriber()
        whisper = loaded
        return loaded
    }

    private func embedder(_ model: String) async throws -> SiglipEmbedder {
        guard model == ModelCatalog.siglip2.id else { throw EmbeddingError.unexpectedModel(model) }
        if let siglip { return siglip }
        let loaded = try await SiglipEmbedder()
        siglip = loaded
        return loaded
    }

    func handle(_ request: InferenceRequest) async -> InferenceResponse {
        do {
            switch request {
            case .ping:
                return .status(
                    InferenceStatus(
                        processID: getpid(), version: BuildInfo.version, residentMemoryBytes: residentMemory(),
                        uptime: Date().timeIntervalSince(started), idleTimeout: InferenceService.idleTimeout))
            case .embedImages(let model, let paths):
                let embedder = try await embedder(model)
                return .vectors(paths.map { (try? embedder.embed(imageAt: URL(fileURLWithPath: $0))) ?? [] })
            case .embedText(let model, let text):
                return .vectors([try await embedder(model).embed(text: text)])
            case .transcribe(let path, let language):
                return .words(try await transcriber().transcribe(path: path, language: language))
            case .installTranscription:
                try await WhisperTranscriber.install()
                return .done
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

let engine = Engine()

/// XPC-Nachrichten dürfen von jedem Thread aus beantwortet werden.
struct PendingReply: @unchecked Sendable {
    let message: XPCReceivedMessage
}
let watchdog = IdleWatchdog(timeout: InferenceService.idleTimeout)

do {
    let listener = try XPCListener(service: InferenceService.bundleIdentifier) { request in
        request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
            let decoded: InferenceRequest
            do {
                decoded = try message.decode(as: InferenceRequest.self)
            } catch {
                return InferenceResponse.failure("Unbekannte Anfrage: \(error.localizedDescription)")
            }
            // Antwort folgt asynchron, damit lange Modellaufgaben die Verbindung nicht blockieren.
            watchdog.begin()
            let pending = PendingReply(message: message)
            Task {
                pending.message.reply(await engine.handle(decoded))
                watchdog.end()
            }
            return nil
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
