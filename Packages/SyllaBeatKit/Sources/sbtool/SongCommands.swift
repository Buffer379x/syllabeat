import Foundation
import SyllaBeatAudio
import SyllaBeatCore
import SyllaBeatModels

/// Beat-F-Measure (eins-zu-eins, ±`tolerance`) und mittlerer Zeitfehler der Treffer.
func beatScore(_ found: [Double], _ reference: [Double], tolerance: Double = 0.07) -> (f: Double, meanMs: Double) {
    var used = Set<Int>()
    var errors: [Double] = []
    for time in found {
        let candidates = reference.indices.filter { !used.contains($0) && abs(reference[$0] - time) <= tolerance }
        if let best = candidates.min(by: { abs(reference[$0] - time) < abs(reference[$1] - time) }) {
            used.insert(best)
            errors.append(abs(reference[best] - time))
        }
    }
    let precision = Double(errors.count) / Double(max(1, found.count))
    let recall = Double(errors.count) / Double(max(1, reference.count))
    let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
    return (f, errors.isEmpty ? .nan : errors.reduce(0, +) / Double(errors.count) * 1000)
}

func analyzeSong(_ path: String) async throws {
    let start = now()
    let output = try await SongAnalyzer().analyze(URL(fileURLWithPath: path))
    let analysis = output.analysis
    print(
        String(
            format: "%@: %.1f s, %.1f BPM, %d Beats (%d Taktanfänge), %.2f s Analyse",
            (path as NSString).lastPathComponent,
            analysis.duration, analysis.tempo, analysis.beats.count, analysis.beats.filter(\.isDownbeat).count,
            now() - start))
    for section in analysis.sections {
        print(
            String(
                format: "  %-14@ %6.2f – %6.2f%@", section.label as NSString, section.start, section.end,
                section.repeatOf.map { " (Wiederholung von \($0))" } ?? ""))
    }
}

/// Vergleicht die Analyse mit den `*.truth.json` der synthetischen Songs.
func evaluateSongs(_ folder: String) async throws {
    let base = URL(fileURLWithPath: folder)
    let songs = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
    for song in songs {
        let truthURL = song.deletingPathExtension().appendingPathExtension("truth.json")
        guard let truth = try JSONSerialization.jsonObject(with: Data(contentsOf: truthURL)) as? [String: Any] else {
            continue
        }
        let referenceBeats = truth["beats"] as? [Double] ?? []
        let referenceDownbeats = truth["downbeats"] as? [Double] ?? []
        let audio = try await AudioDecoder.decodeMono(song)
        let start = now()
        let output = SongAnalyzer().analyze(audio)
        let seconds = now() - start
        let raw = SongAnalyzer(refineOnsets: false).analyze(audio).analysis.beats.map(\.time)
        let beats = output.analysis.beats.map(\.time)
        let refined = beatScore(beats, referenceBeats)
        let plain = beatScore(raw, referenceBeats)
        let downbeats = beatScore(output.analysis.beats.filter(\.isDownbeat).map(\.time), referenceDownbeats)
        let referenceSections = (truth["sections"] as? [[String: Any]] ?? []).compactMap { $0["start"] as? Double }
            .filter { $0 > 0 }
        let foundSections = output.analysis.sections.map(\.start).filter { $0 > 0 }
        let beatLength = 60 / max(1, output.analysis.tempo)
        let hits = referenceSections.filter { r in foundSections.contains { abs($0 - r) <= beatLength * 1.1 } }.count
        print(
            String(
                format:
                    "%@: Tempo %.1f (Ref. %d) · Beats F %.2f, Ø %.1f ms (ohne Feinkorrektur F %.2f, Ø %.1f ms) · Takt-F %.2f · "
                    + "Abschnittsgrenzen %d/%d getroffen, %d gefunden · %.2f s",
                song.deletingPathExtension().lastPathComponent, output.analysis.tempo, truth["bpm"] as? Int ?? 0,
                refined.f, refined.meanMs, plain.f, plain.meanMs, downbeats.f, hits, referenceSections.count,
                foundSections.count, seconds))
        func signed(_ found: [Double]) -> String {
            let errors = found.compactMap { f in referenceBeats.min(by: { abs($0 - f) < abs($1 - f) }).map { f - $0 } }
                .filter { abs($0) < 0.07 }.sorted()
            guard !errors.isEmpty else { return "–" }
            return String(format: "Median %+.1f ms", errors[errors.count / 2] * 1000)
        }
        print("  Vorzeichen: verfeinert \(signed(beats)), roh \(signed(raw))")
        print(
            "  "
                + output.analysis.sections.map { "\($0.label)@\(String(format: "%.1f", $0.start))" }.joined(
                    separator: " · "))
    }
}

/// Transkribiert die Songs mit Gesang und vergleicht Wortanfänge mit der Referenz: roh, korrigiert, ausgerichtet.
func evaluateTranscription(_ folder: String) async throws {
    let base = URL(fileURLWithPath: folder)
    let transcriber = try await WhisperTranscriber()
    for song in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        .filter({ $0.pathExtension == "wav" }).sorted(by: { $0.path < $1.path })
    {
        let lyricsURL = song.deletingPathExtension().appendingPathExtension("lyrics.txt")
        guard FileManager.default.fileExists(atPath: lyricsURL.path),
            let truth = try JSONSerialization.jsonObject(
                with: Data(contentsOf: song.deletingPathExtension().appendingPathExtension("truth.json")))
                as? [String: Any],
            let reference = truth["words"] as? [[String: Any]]
        else { continue }
        let referenceWords = reference.map { (WordMatching.normalize($0["word"] as! String), $0["start"] as! Double) }
        let start = now()
        let raw = try await transcriber.transcribe(path: song.path, language: "de")
        let seconds = now() - start
        let audio = try await AudioDecoder.decodeMono(song)
        let corrected = WordTiming.correct(raw, spectrum: Spectrum(audio))
        let lyrics = LyricsText(try String(contentsOf: lyricsURL, encoding: .utf8))
        let aligned = LyricsAligner.align(lyrics, to: corrected, duration: audio.duration)
        func errors(_ words: [(String, Double)]) -> (found: Int, median: Double, p90: Double) {
            var used = Set<Int>()
            var values: [Double] = []
            for (text, time) in referenceWords {
                if let j = words.indices.first(where: {
                    !used.contains($0) && words[$0].0 == text && abs(words[$0].1 - time) < 1.5
                }) {
                    used.insert(j)
                    values.append(abs(words[j].1 - time))
                }
            }
            values.sort()
            guard !values.isEmpty else { return (0, .nan, .nan) }
            return (
                values.count, values[values.count / 2] * 1000,
                values[min(values.count - 1, values.count * 9 / 10)] * 1000
            )
        }
        let r = errors(raw.map { (WordMatching.normalize($0.text), $0.start) })
        let c = errors(corrected.map { (WordMatching.normalize($0.text), $0.start) })
        let a = errors(aligned.words.map { (WordMatching.normalize($0.text), $0.start) })
        let uncertain = aligned.words.filter(\.isUncertain).count
        print(
            String(
                format:
                    "%@: %.1f s Transkription · erkannt %d/%d · roh Median %.0f ms (P90 %.0f) · korrigiert %.0f ms (P90 %.0f) · "
                    + "ausgerichtet %d/%d Wörter, Median %.0f ms (P90 %.0f), %d unsicher, Qualität %.2f",
                song.deletingPathExtension().lastPathComponent, seconds, r.found, referenceWords.count, r.median, r.p90,
                c.median, c.p90, a.found, referenceWords.count, a.median, a.p90, uncertain, aligned.quality))
    }
}
