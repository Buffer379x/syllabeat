import Foundation
import Testing

@testable import SyllaBeatCore

/// Antwortet auf Range-Anfragen mit 206 und dem Rest der Datei (wie ein Server, der Fortsetzen unterstützt).
final class RangeServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var content = Data()
    nonisolated(unsafe) static var ranges: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "modelle.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        Self.ranges.append(range ?? "-")
        var start = 0
        if let range, let value = Int(range.dropFirst("bytes=".count).dropLast()) { start = value }
        let body = Self.content.subdata(in: start..<Self.content.count)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: range == nil ? 200 : 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct DownloadResumeTests {
    @Test func continuesPartialDownloadWithRange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Fortsetzen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = Data((0..<300_000).map { UInt8($0 % 251) })
        RangeServer.content = content
        RangeServer.ranges = []
        // Abgebrochener Download: die erste Hälfte liegt schon als `.part` da.
        try content.prefix(120_000).write(to: folder.appendingPathComponent("gewichte.bin.part"))
        let digest = try {
            let file = folder.appendingPathComponent("vergleich")
            try content.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            return try Downloader.sha256(of: file)
        }()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServer.self]
        let item = DownloadItem(url: URL(string: "https://modelle.test/gewichte.bin")!, sha256: digest, bytes: 300_000)
        let file = try await Downloader.fetch(item, into: folder, configuration: configuration)
        #expect(try Data(contentsOf: file) == content)
        #expect(RangeServer.ranges == ["bytes=120000-"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("gewichte.bin.part").path))
    }
}
