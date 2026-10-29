import Foundation

/// XML-Baum mit Attributen in fester Reihenfolge; geschrieben wie `ElementTree.indent` in 0.2.0 (zwei Leerzeichen).
public struct XMLNode: Sendable, Equatable {
    public var name: String
    public var attributes: [(String, String)]
    public var text: String?
    public var children: [XMLNode]

    public init(_ name: String, _ attributes: [(String, String)] = [], text: String? = nil, children: [XMLNode] = []) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }

    public static func == (a: XMLNode, b: XMLNode) -> Bool {
        a.name == b.name && a.text == b.text && a.children == b.children
            && a.attributes.map { "\($0.0)=\($0.1)" } == b.attributes.map { "\($0.0)=\($0.1)" }
    }

    /// Kindelement mit Text (wie `_sub(parent, tag, value)` in 0.2.0).
    public static func value(_ name: String, _ value: CustomStringConvertible) -> XMLNode {
        XMLNode(name, text: value.description)
    }

    public mutating func add(_ child: XMLNode) {
        children.append(child)
    }

    func write(into output: inout String, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        output += indent + "<" + name
        for (key, value) in attributes { output += " \(key)=\"\(Self.escape(value, attribute: true))\"" }
        if children.isEmpty {
            if let text {
                output += ">" + Self.escape(text, attribute: false) + "</\(name)>\n"
            } else {
                output += " />\n"
            }
            return
        }
        output += ">"
        if let text { output += Self.escape(text, attribute: false) }
        output += "\n"
        for child in children { child.write(into: &output, depth: depth + 1) }
        output += indent + "</\(name)>\n"
    }

    static func escape(_ text: String, attribute: Bool) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            result = result.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "&#10;")
        }
        return result
    }

    /// Ganzes Dokument mit XML-Kopf und DOCTYPE.
    public func document(doctype: String) -> String {
        var body = ""
        write(into: &body, depth: 0)
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE \(doctype)>\n" + body
    }
}

public enum ExportError: Error, LocalizedError, Equatable {
    case noCut
    case noSong
    case unsupportedRate(Rational, format: String)
    case missingMedia([String])

    public var errorDescription: String? {
        switch self {
        case .noCut: "Es gibt noch keinen Schnitt zum Exportieren."
        case .noSong: "Für den Export fehlt der Song."
        case .unsupportedRate(let rate, let format):
            "\(format) kann die Bildrate \(rate) nicht verlustfrei darstellen. Bitte eine Standard-Bildrate oder FCPXML/OTIO wählen."
        case .missingMedia(let paths):
            "Mediendateien fehlen (\(paths.count)): \(paths.prefix(3).joined(separator: ", ")). „Ablage → Medien neu verknüpfen …“ sucht sie."
        }
    }
}

public enum ExportText {
    /// Datei-URL wie `Path.as_uri()` in 0.2.0: alles außer Buchstaben, Ziffern und `-._~/` wird kodiert
    /// (Leerzeichen, Klammern, Umlaute als UTF-8).
    public static func fileURL(_ path: String) -> String {
        let standardized = (path as NSString).expandingTildeInPath
        let absolute =
            standardized.hasPrefix("/")
            ? standardized : FileManager.default.currentDirectoryPath + "/" + standardized
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        return "file://" + (absolute.addingPercentEncoding(withAllowedCharacters: allowed) ?? absolute)
    }

    /// Zeit als FCPXML-Bruch: `4s`, `43/25s`.
    public static func time(_ value: Rational) -> String {
        value.denominator == 1 ? "\(value.numerator)s" : "\(value.numerator)/\(value.denominator)s"
    }

    /// Timecode `HH:MM:SS:FF` ohne Drop-Frame, Basis = gerundete Rate (wie 0.2.0).
    public static func timecode(_ frames: Int64, rate: Rational) -> String {
        let base = max(1, Int64(rate.doubleValue.rounded()))
        let frame = frames % base
        let seconds = frames / base
        return String(format: "%02lld:%02lld:%02lld:%02lld", seconds / 3600, (seconds / 60) % 60, seconds % 60, frame)
    }

    /// Start-Timecode einer Datei (`HH:MM:SS:FF` oder mit `;`) in Frames bei `rate`; `nil` ohne Timecode.
    public static func frames(ofTimecode text: String?, rate: Rational) -> Int64? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == ";" }).compactMap { Int64($0) }
        guard parts.count == 4 else { return nil }
        let base = max(1, Int64(rate.doubleValue.rounded()))
        return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * base + parts[3]
    }

    /// Atomar schreiben: Ein abgebrochener Export hinterlässt keine halbe Datei.
    public static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
