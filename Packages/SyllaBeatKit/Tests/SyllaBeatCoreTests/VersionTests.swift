import Foundation
import Testing

/// Gegenstück zum Versionstest von 0.2.0: Beim Release wird die erwartete Version hier bewusst angepasst.
@Test func marketingVersionIsSetOnce() throws {
    let config = try String(
        contentsOf: Fixtures.repository.appendingPathComponent("Config/Version.xcconfig"), encoding: .utf8)
    let line = config.split(separator: "\n").first { $0.hasPrefix("MARKETING_VERSION") }
    let version = line?.split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
    #expect(version == "0.4.0")
}
