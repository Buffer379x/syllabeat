import Foundation

/// Was der Dateiname eines Clips über seinen Inhalt verrät. KI-Generatoren und Ablagen benennen Clips oft nach dem
/// Motiv (`farm_family_with_goats_1080p_wan (2).mp4`); Technik wie Auflösung, Generator, Wasserzeichen und Kopiezähler
/// wird abgetrennt, damit Takes desselben Motivs denselben Schlüssel haben.
public struct FileNameMotif: Sendable, Equatable {
    /// Gemeinsames Präfix mehrerer Dateien, z. B. „farm“.
    public var group: String?
    /// Motiv ohne Technik, z. B. „family with goats“.
    public var key: String
    public var words: [String]
    /// Kopiezähler „ (2)“; 1 ohne Zähler.
    public var copy: Int
    public var generator: String?
    /// `true` mit Wasserzeichen, `false` ausdrücklich ohne, `nil` unbekannt.
    public var watermark: Bool?
    /// „Tag“, „Abend“ oder „Nacht“, falls der Name es nennt.
    public var timeOfDay: String?

    static let generators: Set<String> = [
        "wan", "veo", "kling", "runway", "sora", "pika", "luma", "hailuo", "minimax",
    ]
    static let timeWords: [String: String] = [
        "evening": "Abend", "sunset": "Abend", "dusk": "Abend", "abend": "Abend", "dämmerung": "Abend",
        "sonnenuntergang": "Abend", "night": "Nacht", "nacht": "Nacht", "morning": "Tag", "day": "Tag",
        "daylight": "Tag", "tag": "Tag", "morgen": "Tag",
    ]

    public static func parse(_ fileName: String, groups: Set<String> = []) -> FileNameMotif {
        var name = (fileName as NSString).deletingPathExtension.lowercased()
        var copy = 1
        if let range = name.range(of: #"\s*\((\d+)\)$"#, options: .regularExpression) {
            copy = Int(name[range].filter(\.isNumber)) ?? 1
            name.removeSubrange(range)
        }
        let tokens = name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " || $0 == "." }).map(String.init)
        var words: [String] = []
        var generator: String?
        var watermark: Bool?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "no", index + 1 < tokens.count, tokens[index + 1] == "watermark" {
                watermark = false
                index += 2
                continue
            }
            if token == "watermark" {
                watermark = true
            } else if generators.contains(token) {
                generator = token
            } else if token.range(of: #"^\d{3,4}p$"#, options: .regularExpression) != nil
                || token.allSatisfy(\.isNumber)
            {
                // Auflösung oder Variantennummer.
            } else {
                words.append(token)
            }
            index += 1
        }
        var group: String?
        if let first = words.first, groups.contains(first), words.count > 1 {
            group = first
            words.removeFirst()
        }
        let timeOfDay = words.compactMap { timeWords[$0] }.max { rank($0) < rank($1) }
        return FileNameMotif(
            group: group, key: words.joined(separator: " "), words: words, copy: copy, generator: generator,
            watermark: watermark, timeOfDay: timeOfDay)
    }

    /// Präfixe, die mindestens drei, aber nicht alle Dateien teilen.
    public static func groups(in fileNames: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for name in fileNames {
            let base = (name as NSString).deletingPathExtension.lowercased()
            guard let separator = base.firstIndex(where: { $0 == "_" || $0 == "-" }) else { continue }
            counts[String(base[..<separator]), default: 0] += 1
        }
        return Set(counts.filter { $0.value >= 3 && $0.value < fileNames.count }.keys)
    }

    static func rank(_ value: String) -> Int {
        ["Tag": 0, "Abend": 1, "Nacht": 2][value] ?? 0
    }
}

extension Project {
    /// Motiv je Clip-ID; Gruppen ergeben sich aus allen Dateinamen des Projekts.
    public func motifs() -> [String: FileNameMotif] {
        let groups = FileNameMotif.groups(in: clips.map(\.name))
        return Dictionary(
            clips.map { ($0.id, FileNameMotif.parse($0.name, groups: groups)) }, uniquingKeysWith: { first, _ in first }
        )
    }
}
