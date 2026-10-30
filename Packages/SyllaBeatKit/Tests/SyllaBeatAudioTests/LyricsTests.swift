import Foundation
import Testing

@testable import SyllaBeatAudio
@testable import SyllaBeatCore

@Suite struct LyricsTests {
    let text = """
        [Strophe]
        Ich lauf am Strand entlang
        die Wellen rufen meinen Namen

        [Refrain]
        Und das Meer singt mit
        jeden Schritt

        Neue Zeile ohne Titel
        """

    @Test func parsesBlocksAndHeaders() {
        let lyrics = LyricsText(text)
        #expect(lyrics.blocks.count == 3)
        #expect(lyrics.blocks.map(\.label) == ["Strophe", "Refrain", nil])
        #expect(lyrics.blocks[1].lines == ["Und das Meer singt mit", "jeden Schritt"])
    }

    /// Referenzbeispiele der Kölner Phonetik.
    @Test(arguments: [("Müller-Lüdenscheidt", "65752682"), ("Wikipedia", "3412"), ("Breschnew", "17863")])
    func colognePhonetic(word: String, code: String) {
        #expect(WordMatching.colognePhonetic(word) == code)
    }

    @Test func fuzzySimilarity() {
        #expect(WordMatching.similarity("Straße", "strasse") == 1)
        #expect(WordMatching.similarity("Meer", "mehr") >= 0.75)
        #expect(WordMatching.similarity("Wellen", "Welle") >= 0.8)
        #expect(WordMatching.similarity("Himmel", "Strand") < 0.6)
    }

    @Test func alignsAndMarksUncertainWords() {
        let lyrics = LyricsText(text)
        // Erkannt: „Strand“ fehlt, „Wellen“ falsch gehört, ein Füllwort zu viel; letzte Zeile gar nicht gesungen.
        let spoken: [(String, Double)] = [
            ("Ich", 1.0), ("lauf", 1.3), ("am", 1.6), ("entlang", 2.4), ("die", 3.0), ("Welle", 3.2), ("rufen", 3.6),
            ("meinen", 4.0), ("Namen", 4.4), ("oh", 5.0), ("und", 6.0), ("das", 6.2), ("Meer", 6.4), ("singt", 6.8),
            ("mit", 7.1), ("jeden", 7.6), ("Schritt", 8.0),
        ]
        let recognized = spoken.map { RecognizedWord(text: $0.0, start: $0.1, end: $0.1 + 0.25, probability: 0.9) }
        let result = LyricsAligner.align(lyrics, to: recognized, duration: 12)
        #expect(result.words.count == 21)
        let strand = result.words[3]
        #expect(strand.text == "Strand" && strand.estimated)
        #expect(strand.start >= 1.6 && strand.end <= 2.4)
        #expect(result.words[6].text == "Wellen" && !result.words[6].estimated && result.words[6].start == 3.2)
        #expect(result.lines.count == 5)
        #expect(result.lines[0].needsReview)
        #expect(!result.lines[2].needsReview)
        #expect(result.lines[4].needsReview)
        #expect(result.blockLines == [0..<2, 2..<4, 4..<5])
        #expect(result.quality > 0.7)
        // Zeiten bleiben aufsteigend.
        #expect(zip(result.words, result.words.dropFirst()).allSatisfy { $0.start <= $1.start })
    }

    @Test func linesFromTranscriptionWithoutLyrics() {
        let recognized = [
            RecognizedWord(text: "Hallo", start: 1, end: 1.4, probability: 0.9),
            RecognizedWord(text: "Welt.", start: 1.5, end: 1.9, probability: 0.3),
            RecognizedWord(text: "Neue", start: 4, end: 4.3, probability: 0.9),
            RecognizedWord(text: "Zeile", start: 4.4, end: 4.8, probability: 0.9),
        ]
        let result = LyricsAligner.lines(from: recognized)
        #expect(result.lines.map(\.text) == ["Hallo Welt.", "Neue Zeile"])
        #expect(result.lines[0].needsReview && !result.lines[1].needsReview)
    }

    @Test func syllablesFollowHyphenation() {
        #expect(Syllables.split("Morgen") == ["Mor", "gen"])
        #expect(Syllables.split("Wellen").count == 2)
        #expect(Syllables.split("Meer") == ["Meer"])
        let word = Word(id: "w1", text: "Morgen", start: 1, end: 2)
        let timed = Syllables.timed(word)
        #expect(timed.map(\.id) == ["w1.1", "w1.2"])
        #expect(timed.first?.start == 1 && timed.last?.end == 2)
        #expect(abs(timed[0].end - timed[1].start) < 1e-9)
    }

    @Test func textSectionsFollowBlocksAndRepeats() {
        let lyrics = LyricsText("[Strophe]\nA b c\n\n[Refrain]\nD e f\n\n[Strophe]\nG h i\n\n[Refrain]\nD e f")
        let words = ["A", "b", "c", "D", "e", "f", "G", "h", "i", "D", "e", "f"]
        let starts = [6.0, 6.5, 7, 14, 14.5, 15, 22, 22.5, 23, 30, 30.5, 31]
        let recognized = zip(words, starts).map { RecognizedWord(text: $0, start: $1, end: $1 + 0.3, probability: 1) }
        let aligned = LyricsAligner.align(lyrics, to: recognized, duration: 44)
        let beats = stride(from: 0.0, to: 44, by: 0.5).enumerated().map {
            Beat(time: $0.element, isDownbeat: $0.offset % 4 == 0)
        }
        let analysis = SongAnalysis(duration: 44, tempo: 120, beats: Array(beats.dropFirst()))
        let sections = SongStructure.sections(lyrics: lyrics, aligned: aligned, analysis: analysis)
        #expect(sections.map(\.kind) == [.intro, .verse, .chorus, .verse, .chorus, .outro])
        #expect(sections[1].start == 6 && sections[2].start == 14)
        #expect(sections[4].repeatOf == sections[2].id)
        #expect(sections.last?.end == 44)
    }
}

@Suite struct WordTimingTests {
    /// Gesangsartige Einsätze (Tonstöße 400–2400 Hz) zu bekannten Zeiten; die „erkannten“ Zeiten sind wie bei
    /// Whisper zu früh und innerhalb der Zeile gestaucht.
    @Test func snapsCompressedWhisperTimesToVocalOnsets() {
        let rate = 22_050.0
        let truth = [1.0, 1.5, 2.1, 2.6, 3.3, 5.0, 5.6, 6.1, 6.8]
        var samples = [Float](repeating: 0, count: Int(8 * rate))
        for (n, start) in truth.enumerated() {
            for i in 0..<Int(0.3 * rate) {
                let t = Double(i) / rate
                let frequency = 400.0 + Double(n % 4) * 500
                // Weicher Ausklang, sonst erzeugt der Abbruch einen zweiten Einsatz.
                let release = min(1, (0.3 - t) * 20)
                samples[Int(start * rate) + i] += Float(0.4 * sin(2 * .pi * frequency * t) * min(1, t * 200) * release)
            }
        }
        let spectrum = Spectrum(MonoAudio(samples: samples, sampleRate: rate))
        let recognized = truth.enumerated().map { index, time in
            let lineStart = index < 5 ? 1.0 : 5.0
            let early = time - 0.1 - (time - lineStart) * 0.12
            return RecognizedWord(text: "w\(index)", start: early, end: early + 0.25, probability: 0.9)
        }
        let corrected = WordTiming.correct(recognized, spectrum: spectrum)
        let errors = zip(corrected, truth).map { abs($0.start - $1) }.sorted()
        // Scharfe Einsätze nach Stille erkennt das zentrierte FFT-Fenster bis zu ~30 ms früh (Auflösung 11,6 ms).
        #expect(errors[errors.count / 2] < 0.04, "Median \(errors[errors.count / 2])")
        #expect(errors.last! < 0.06, "größter Fehler \(errors.last!)")
        #expect(zip(corrected, corrected.dropFirst()).allSatisfy { $0.start < $1.start })
    }
}

/// Whisper setzt manchmal die Wörter eines ganzen Abschnitts auf dieselbe Sekunde (gemessen im Bauernhof-Song).
@Suite struct CollapsedTimingTests {
    static func words(_ starts: [Double]) -> [RecognizedWord] {
        starts.enumerated().map {
            RecognizedWord(text: "w\($0.offset)", start: $0.element, end: $0.element + 0.02, probability: 1)
        }
    }

    @Test func collapsedTimestampsAreDropped() {
        let normal = (0..<10).map { Double($0) * 2 }
        let collapsed = (0..<30).map { 30 + Double($0) / 30 }
        let after = (0..<5).map { 40 + Double($0) * 0.4 }
        let kept = WordTiming.dropCollapsed(Self.words(normal + collapsed + after))
        #expect(kept.count == 15)
        #expect(kept.allSatisfy { $0.start < 30 || $0.start >= 40 })
    }

    @Test func fastRapIsKept() {
        let kept = WordTiming.dropCollapsed(Self.words((0..<32).map { Double($0) * 0.125 }))
        #expect(kept.count == 32)
    }

    @Test func collapsedLinesAreInterpolatedAndMarked() {
        let lyrics = """
            eins zwei drei vier fünf sechs
            sieben acht neun zehn elf zwölf
            dreizehn vierzehn fünfzehn sechzehn siebzehn achtzehn
            neunzehn
            """
        let texts = lyrics.split(whereSeparator: \.isWhitespace).map(String.init)
        var recognized: [RecognizedWord] = []
        for (index, word) in texts.enumerated() {
            let start: Double
            switch index {
            case 0..<6: start = Double(index) * 0.5
            case 6..<18: start = 20 + Double(index - 6) * 0.05
            default: start = 30
            }
            recognized.append(RecognizedWord(text: word, start: start, end: start + 0.04, probability: 1))
        }
        let analysis = LyricsWorkflow.apply(transcript: recognized, lyrics: lyrics, to: SongAnalysis(duration: 40))
        #expect(analysis.lines.count == 4)
        for line in analysis.lines[1...2] {
            #expect(line.end - line.start >= 3, "\(line.text): \(line.start)–\(line.end)")
            #expect(line.needsReview)
        }
        #expect(!analysis.lines[0].needsReview)
    }

    @Test func parenthesizedLinesAreIgnored() {
        let text = LyricsText("[Outro]\nWir fahren nach Haus\n(End)\n(Instrumental)")
        #expect(text.blocks.flatMap(\.lines) == ["Wir fahren nach Haus"])
    }
}
