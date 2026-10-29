import Foundation
import SyllaBeatCore

/// Songtext in Blöcken: Absätze bzw. `[Refrain]`-Überschriften (Logik aus 0.2.0).
public struct LyricsText: Sendable, Equatable {
    public struct Block: Sendable, Equatable {
        public var label: String?
        public var lines: [String]
    }

    public var blocks: [Block]

    public init(_ text: String) {
        var blocks: [Block] = []
        var current = Block(label: nil, lines: [])
        func close() {
            if !current.lines.isEmpty { blocks.append(current) }
            current = Block(label: nil, lines: [])
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
            } else if line.hasPrefix("["), line.hasSuffix("]") {
                close()
                current.label = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            } else {
                current.lines.append(line)
            }
        }
        close()
        self.blocks = blocks
    }

    public var isEmpty: Bool { blocks.isEmpty }
}

/// Vergleich von Wörtern: Normalisierung, Levenshtein-Ähnlichkeit und Kölner Phonetik.
public enum WordMatching {
    public static func normalize(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter || $0.isNumber }
    }

    public static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { !normalize($0).isEmpty }
    }

    /// Ähnlichkeit 0…1: Levenshtein, Kölner Phonetik zählt als 0,85.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a)
        let y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }
        let edit = 1 - Double(levenshtein(Array(x), Array(y))) / Double(max(x.count, y.count))
        let phonetic = colognePhonetic(x) == colognePhonetic(y) && !colognePhonetic(x).isEmpty ? 0.85 : 0
        return max(edit, phonetic)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return a.isEmpty ? b.count : previous[b.count]
    }

    /// Kölner Phonetik (Postel 1969): Ziffernfolge, gleiche Ziffern zusammengefasst, Nullen außer am Anfang entfernt.
    public static func colognePhonetic(_ word: String) -> String {
        let letters = Array(normalize(word).uppercased().replacingOccurrences(of: "PH", with: "F"))
        var codes: [Character] = []
        for (i, c) in letters.enumerated() {
            let previous = i > 0 ? letters[i - 1] : " "
            let next = i + 1 < letters.count ? letters[i + 1] : " "
            let code: Character?
            switch c {
            case "A", "E", "I", "J", "O", "U", "Y": code = "0"
            case "H": code = nil
            case "B": code = "1"
            case "P": code = next == "H" ? "3" : "1"
            case "D", "T": code = "CSZ".contains(next) ? "8" : "2"
            case "F", "V", "W": code = "3"
            case "G", "K", "Q": code = "4"
            case "C":
                if i == 0 {
                    code = "AHKLOQRUX".contains(next) ? "4" : "8"
                } else {
                    code = "SZ".contains(previous) || !"AHKOQUX".contains(next) ? "8" : "4"
                }
            case "X": code = "CKQ".contains(previous) ? "8" : nil
            case "L": code = "5"
            case "M", "N": code = "6"
            case "R": code = "7"
            case "S", "Z": code = "8"
            default: code = nil
            }
            if c == "X", code == nil {
                codes.append("4")
                codes.append("8")
            } else if let code {
                codes.append(code)
            }
        }
        var result: [Character] = []
        for code in codes where result.last != code { result.append(code) }
        return String(result.enumerated().filter { $0.offset == 0 || $0.element != "0" }.map(\.element))
    }
}

/// Richtet einen eigenen Songtext an den erkannten Wörtern aus (Needleman-Wunsch mit unscharfem Vergleich).
/// Nicht gefundene Wörter werden zwischen den Ankern nach Silbengewicht verteilt und als geschätzt markiert.
public enum LyricsAligner {
    public struct Result: Sendable {
        public var words: [Word]
        public var lines: [LyricLine]
        /// Zeilenbereiche (Indizes in `lines`) je Block des Songtexts.
        public var blockLines: [Range<Int>]
        /// Anteil der Textwörter mit sicherer Zuordnung.
        public var quality: Double
    }

    public static func align(_ lyrics: LyricsText, to recognized: [RecognizedWord], duration: Double) -> Result {
        var tokens: [(text: String, line: Int)] = []
        var lineTexts: [String] = []
        var blockLines: [Range<Int>] = []
        for block in lyrics.blocks {
            let first = lineTexts.count
            for line in block.lines {
                for token in WordMatching.tokens(line) { tokens.append((token, lineTexts.count)) }
                lineTexts.append(line)
            }
            blockLines.append(first..<lineTexts.count)
        }
        let pairs = needlemanWunsch(tokens.map(\.text), recognized.map(\.text))
        var timed: [(start: Double, end: Double, confidence: Double)?] = Array(repeating: nil, count: tokens.count)
        for (i, j, similarity) in pairs {
            timed[i] = (recognized[j].start, recognized[j].end, similarity * recognized[j].probability)
        }
        // Lücken zwischen Ankern nach Silbengewicht füllen.
        var index = 0
        while index < tokens.count {
            guard timed[index] == nil else {
                index += 1
                continue
            }
            var stop = index
            while stop < tokens.count, timed[stop] == nil { stop += 1 }
            let from =
                index > 0 ? timed[index - 1]!.end : max(0, (timed[stop < tokens.count ? stop : 0]?.start ?? 0) - 2)
            let to = stop < tokens.count ? timed[stop]!.start : min(duration, from + Double(stop - index) * 0.5)
            let weights = tokens[index..<stop].map { Double(max(1, Syllables.split($0.text).count)) }
            let total = weights.reduce(0, +)
            var cursor = from
            for (offset, weight) in weights.enumerated() {
                let length = max(0, to - from) * weight / max(1, total)
                timed[index + offset] = (cursor, cursor + length, 0.2)
                cursor += length
            }
            index = stop
        }
        var words: [Word] = []
        for (i, token) in tokens.enumerated() {
            let time = timed[i]!
            let anchored = pairs.contains { $0.0 == i }
            words.append(
                Word(
                    id: "w\(i + 1)", text: token.text, start: time.start, end: max(time.start, time.end),
                    confidence: time.confidence, estimated: !anchored))
        }
        var lines: [LyricLine] = []
        for (number, text) in lineTexts.enumerated() {
            let members = words.indices.filter { tokens[$0].line == number }.map { words[$0] }
            guard let first = members.first, let last = members.last else { continue }
            let confidence = members.compactMap(\.confidence).reduce(0, +) / Double(members.count)
            lines.append(
                LyricLine(
                    id: String(format: "line_%04d", number + 1), text: text, start: first.start, end: last.end,
                    confidence: confidence, needsReview: members.contains(where: \.isUncertain),
                    wordIDs: members.map(\.id)))
        }
        let quality = Double(pairs.filter { $0.2 >= 0.75 }.count) / Double(max(1, tokens.count))
        return Result(words: words, lines: lines, blockLines: blockLines, quality: quality)
    }

    /// Globale Ausrichtung; liefert Paare (Textwort, erkanntes Wort, Ähnlichkeit) ab Ähnlichkeit 0,6.
    static func needlemanWunsch(_ a: [String], _ b: [String]) -> [(Int, Int, Double)] {
        let n = a.count
        let m = b.count
        guard n > 0, m > 0 else { return [] }
        let gap = -0.4
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var move = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            score[i][0] = Double(i) * gap
            move[i][0] = 1
        }
        for j in 1...m {
            score[0][j] = Double(j) * gap
            move[0][j] = 2
        }
        var similarities = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for i in 0..<n { for j in 0..<m { similarities[i][j] = WordMatching.similarity(a[i], b[j]) } }
        for i in 1...n {
            for j in 1...m {
                let s = similarities[i - 1][j - 1]
                let diagonal = score[i - 1][j - 1] + (s >= 0.6 ? 2 * s : -1)
                let up = score[i - 1][j] + gap
                let left = score[i][j - 1] + gap
                if diagonal >= up, diagonal >= left {
                    score[i][j] = diagonal
                    move[i][j] = 0
                } else if up >= left {
                    score[i][j] = up
                    move[i][j] = 1
                } else {
                    score[i][j] = left
                    move[i][j] = 2
                }
            }
        }
        var pairs: [(Int, Int, Double)] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, move[i][j] == 0 {
                let s = similarities[i - 1][j - 1]
                if s >= 0.6 { pairs.append((i - 1, j - 1, s)) }
                i -= 1
                j -= 1
            } else if i > 0, j == 0 || move[i][j] == 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    /// Zeilen aus der Transkription ohne eigenen Text: Pausen über 0,8 s oder Satzzeichen trennen.
    public static func lines(from recognized: [RecognizedWord]) -> (words: [Word], lines: [LyricLine]) {
        var words: [Word] = []
        var lines: [LyricLine] = []
        var current: [Word] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(
                LyricLine(
                    id: String(format: "line_%04d", lines.count + 1),
                    text: current.map(\.text).joined(separator: " "), start: first.start, end: last.end,
                    confidence: current.compactMap(\.confidence).reduce(0, +) / Double(current.count),
                    needsReview: current.contains(where: \.isUncertain), wordIDs: current.map(\.id)))
            current = []
        }
        for (index, item) in recognized.enumerated() {
            let text = item.text.trimmingCharacters(in: .whitespaces)
            guard !WordMatching.normalize(text).isEmpty else { continue }
            if let last = current.last, item.start - last.end > 0.8 || current.count >= 12 { close() }
            let word = Word(
                id: "w\(index + 1)", text: text, start: item.start, end: max(item.start, item.end),
                confidence: item.probability)
            words.append(word)
            current.append(word)
            if let mark = text.last, ".!?".contains(mark) { close() }
        }
        close()
        return (words, lines)
    }
}

/// Silbentrennung über die Systemfunktion (deutsch), Dauer nach Vokalgewicht verteilt.
public enum Syllables {
    public static func split(_ word: String) -> [String] {
        let locale = Locale(identifier: "de_DE") as CFLocale
        let string = word as NSString
        guard string.length > 3, CFStringIsHyphenationAvailableForLocale(locale) else { return [word] }
        var points: [Int] = []
        var index = string.length
        while index > 0 {
            let location = CFStringGetHyphenationLocationBeforeIndex(
                string as CFString, index, CFRange(location: 0, length: string.length), 0, locale, nil)
            guard location != kCFNotFound, location > 0, location < index else { break }
            points.append(location)
            index = location
        }
        let cuts = [0] + points.reversed() + [string.length]
        return zip(cuts, cuts.dropFirst()).map { string.substring(with: NSRange(location: $0, length: $1 - $0)) }
    }

    /// Verteilt die Wortdauer auf die Silben: Gewicht = Anzahl Vokale + 1 (Diphthonge und lange Vokale zählen mehr).
    public static func timed(_ word: Word) -> [Syllable] {
        let parts = split(word.text)
        guard parts.count > 1 else {
            return [Syllable(id: "\(word.id).1", text: word.text, start: word.start, end: word.end)]
        }
        let weights = parts.map { part in Double(part.lowercased().filter { "aeiouäöüy".contains($0) }.count + 1) }
        let total = weights.reduce(0, +)
        var cursor = word.start
        return parts.enumerated().map { index, part in
            let length = (word.end - word.start) * weights[index] / total
            defer { cursor += length }
            return Syllable(
                id: "\(word.id).\(index + 1)", text: part, start: cursor,
                end: index == parts.count - 1 ? word.end : cursor + length)
        }
    }
}

/// Whisper setzt Wortanfänge zu früh und staucht die Zeiten innerhalb einer Zeile (M0: −180…−200 ms im Mittel,
/// am Zeilenende bis −450 ms). Korrektur: Jedes Wort erhält per Viterbi einen Gesangseinsatz im Fenster
/// −0,15…+0,6 s; starke Einsätze im Stimmband werden bevorzugt, die Reihenfolge bleibt erhalten. Ohne passenden
/// Einsatz bleibt die erkannte Zeit (um den Median-Versatz verschoben).
public enum WordTiming {
    public static func correct(
        _ words: [RecognizedWord], spectrum: Spectrum, window: ClosedRange<Double> = -0.15...0.6
    )
        -> [RecognizedWord]
    {
        guard words.count >= 2 else { return words }
        let peaks = onsetPeaks(spectrum)
        guard !peaks.isEmpty else { return words }
        let strongest = peaks.map(\.strength).max() ?? 1
        // Kandidaten je Wort: Einsätze im Fenster, dazu „unverändert“ (Index −1).
        let candidates = words.map { word in
            peaks.indices.filter { window.contains(peaks[$0].time - word.start) }
        }
        func emission(_ word: Int, _ peak: Int) -> Double {
            guard peak >= 0 else { return 0.15 }
            let delta = peaks[peak].time - words[word].start
            return Double(peaks[peak].strength / strongest) - 0.4 * abs(delta - 0.2)
        }
        // Viterbi über Wörter; Zustand = gewählter Einsatz, strikt aufsteigend.
        var score: [[Double]] = []
        var back: [[Int]] = []
        for (w, options) in candidates.enumerated() {
            let states = [-1] + options
            var rowScore: [Double] = []
            var rowBack: [Int] = []
            for state in states {
                var best = w == 0 ? 0.0 : -Double.infinity
                var link = -1
                if w > 0 {
                    let previous = [-1] + candidates[w - 1]
                    for (k, earlier) in previous.enumerated() {
                        let allowed = state < 0 || earlier < 0 || peaks[earlier].time < peaks[state].time - 0.04
                        if allowed, score[w - 1][k] > best {
                            best = score[w - 1][k]
                            link = k
                        }
                    }
                }
                rowScore.append(best + emission(w, state))
                rowBack.append(link)
            }
            score.append(rowScore)
            back.append(rowBack)
        }
        var choice = [Int](repeating: -1, count: words.count)
        var k = score.last!.indices.max { score.last![$0] < score.last![$1] } ?? 0
        for w in stride(from: words.count - 1, through: 0, by: -1) {
            let states = [-1] + candidates[w]
            choice[w] = states[k]
            k = max(0, back[w][k])
        }
        let deltas = words.indices.compactMap { choice[$0] >= 0 ? peaks[choice[$0]].time - words[$0].start : nil }
            .sorted()
        let offset = deltas.isEmpty ? 0 : deltas[deltas.count / 2]
        var result = words
        for index in result.indices {
            let start = choice[index] >= 0 ? peaks[choice[index]].time : result[index].start + offset
            result[index].end = max(start + 0.05, result[index].end + (start - result[index].start))
            result[index].start = start
            if index > 0, result[index].start <= result[index - 1].start {
                result[index].start = result[index - 1].start + 0.02
            }
        }
        return result
    }

    /// Spitzen der Stimmband-Onset-Hüllkurve über dem gleitenden Mittel (±0,5 s).
    static func onsetPeaks(_ spectrum: Spectrum) -> [(time: Double, strength: Float)] {
        let envelope = spectrum.vocal
        guard envelope.count > 2 else { return [] }
        let radius = Int(spectrum.frameRate * 0.5)
        var prefix = [Float](repeating: 0, count: envelope.count + 1)
        for i in envelope.indices { prefix[i + 1] = prefix[i] + envelope[i] }
        var peaks: [(Double, Float)] = []
        for i in 1..<(envelope.count - 1) where envelope[i] > envelope[i - 1] && envelope[i] >= envelope[i + 1] {
            let lo = max(0, i - radius)
            let hi = min(envelope.count, i + radius)
            let mean = (prefix[hi] - prefix[lo]) / Float(hi - lo)
            if envelope[i] > mean * 1.3 {
                peaks.append(
                    (spectrum.time(ofFrame: BeatTracker.refinedPeak(envelope, near: i, radius: 1)), envelope[i] - mean))
            }
        }
        return peaks
    }
}

/// Fügt Transkript und Songtext in die Analyse ein: Wörter mit Silben, Zeilen und – bei eigenem Text – Abschnitte
/// aus dem Text (der Text gewinnt gegenüber der Audio-Struktur).
public enum LyricsWorkflow {
    public static func apply(
        transcript: [RecognizedWord], lyrics: String, to analysis: SongAnalysis, audioSections: [SongSection]? = nil
    ) -> SongAnalysis {
        var result = analysis
        result.transcript = transcript
        let text = LyricsText(lyrics)
        let words: [Word]
        if text.isEmpty {
            let lines = LyricsAligner.lines(from: transcript)
            words = lines.words
            result.lines = lines.lines
            if let audioSections { result.sections = audioSections }
        } else {
            let aligned = LyricsAligner.align(text, to: transcript, duration: analysis.duration)
            words = aligned.words
            result.lines = aligned.lines
            let fromText = SongStructure.sections(lyrics: text, aligned: aligned, analysis: analysis)
            if !fromText.isEmpty { result.sections = fromText }
        }
        result.words = words.map { word in
            var timed = word
            timed.syllables = Syllables.timed(word)
            return timed
        }
        return result
    }
}
