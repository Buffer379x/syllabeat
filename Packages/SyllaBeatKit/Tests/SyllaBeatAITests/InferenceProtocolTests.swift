import Foundation
import Testing

@testable import SyllaBeatAI

@Suite struct InferenceProtocolTests {
    @Test func messagesRoundTrip() throws {
        let status = InferenceStatus(
            processID: 42, version: "0.3.0", residentMemoryBytes: 1 << 20, uptime: 1.5, idleTimeout: 120)
        for response in [InferenceResponse.status(status), .failure("kein Modell")] {
            let data = try JSONEncoder().encode(response)
            #expect(try JSONDecoder().decode(InferenceResponse.self, from: data) == response)
        }
        let request = try JSONDecoder().decode(InferenceRequest.self, from: JSONEncoder().encode(InferenceRequest.ping))
        #expect(request == .ping)
    }

    /// Ohne gebaute App gibt es keinen Dienst; der Client meldet das verständlich statt zu hängen.
    @Test func missingServiceIsReported() async {
        let client = InferenceClient(serviceName: "de.syllabeat.test.fehlt")
        await #expect(throws: InferenceError.self) { _ = try await client.status() }
    }
}
