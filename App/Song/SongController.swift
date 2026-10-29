import AVFoundation
import Foundation
import Observation
import SyllaBeatAI
import SyllaBeatAudio
import SyllaBeatCore

/// Song eines Dokumentfensters: Analyse (Beats, Takte, Energie, Abschnitte), Wellenform, Gesangserkennung,
/// Songtext-Ausrichtung und Wiedergabe. Ergebnisse landen ohne Undo-Schritt im Dokument.
@MainActor
@Observable
final class SongController {
    @ObservationIgnored private weak var document: ProjectDocument?
    @ObservationIgnored private let services: AppServices
    let playback = Playback()

    private(set) var waveform: Waveform?
    private(set) var analyzing = false
    private(set) var transcribing = false
    var message: String?

    init(document: ProjectDocument, services: AppServices) {
        self.document = document
        self.services = services
    }

    private var project: Project? { document?.project }

    static var transcriptionInstalled: Bool { TranscriptionModel.isInstalled }

    /// Beim Öffnen und nach einem Songwechsel: Wiedergabe vorbereiten, Wellenform laden, fehlende Analyse starten.
    func songChanged() {
        guard let song = project?.song else {
            playback.load(nil)
            waveform = nil
            return
        }
        let url = URL(fileURLWithPath: song.path)
        playback.load(FileManager.default.fileExists(atPath: url.path) ? url : nil)
        if let fingerprint = song.fingerprint,
            let data = try? Data(contentsOf: MediaCache().waveform(fingerprint: fingerprint))
        {
            waveform = Waveform(encoded: data)
        } else {
            waveform = nil
        }
        if project?.analysis == nil {
            analyze()
        } else if waveform == nil {
            // Analyse vorhanden (z. B. aus 0.2.0 übernommen): nur die Wellenform nachberechnen, Beats bleiben.
            loadWaveform(url: url, fingerprint: song.fingerprint)
        }
    }

    private func loadWaveform(url: URL, fingerprint: String?) {
        services.jobs.submit("Wellenform berechnen", resource: .io, priority: .userInitiated) { [weak self] _ in
            let owner = self
            let audio = try await AudioDecoder.decodeMono(url)
            let waveform = Waveform(audio)
            if let fingerprint {
                let cache = MediaCache()
                _ = try? cache.prepare(fingerprint: fingerprint)
                try? waveform.encoded().write(to: cache.waveform(fingerprint: fingerprint))
            }
            await MainActor.run { owner?.waveform = waveform }
        }
    }

    /// Beats, Takte, Energie und Abschnitte; behält Transkript und Songtext-Ausrichtung, sofern vorhanden.
    func analyze() {
        guard let song = project?.song, !analyzing else { return }
        analyzing = true
        let url = URL(fileURLWithPath: song.path)
        let fingerprint = song.fingerprint
        services.jobs.submit("Song analysieren", resource: .io, priority: .userInitiated) { [weak self] context in
            let owner = self
            defer { Task { @MainActor in owner?.analyzing = false } }
            await context.progress(nil, detail: "Beats und Abschnitte")
            let output = try await SongAnalyzer().analyze(url)
            if let fingerprint {
                let cache = MediaCache()
                _ = try? cache.prepare(fingerprint: fingerprint)
                try? output.waveform.encoded().write(to: cache.waveform(fingerprint: fingerprint))
            }
            let previous = await MainActor.run { owner?.project?.analysis }
            let lyrics = await MainActor.run { owner?.project?.lyricsText ?? "" }
            var analysis = output.analysis
            if let previous, !previous.transcript.isEmpty, abs(previous.duration - analysis.duration) < 0.5 {
                analysis = LyricsWorkflow.apply(
                    transcript: previous.transcript, lyrics: lyrics, to: analysis, audioSections: analysis.sections)
                analysis.language = previous.language
                analysis.transcriptionModel = previous.transcriptionModel
            }
            let result = analysis
            await MainActor.run {
                owner?.waveform = output.waveform
                owner?.document?.applyAnalysis { $0.analysis = result }
                owner?.message =
                    "Song analysiert: \(Int(result.tempo.rounded())) BPM, \(result.beats.count) Beats, \(result.sections.count) Abschnitte."
                if result.transcript.isEmpty, Self.transcriptionInstalled,
                    UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true
                {
                    owner?.transcribe()
                }
            }
        }
    }

    /// Gesang erkennen (WhisperKit im Inferenzdienst), Wortzeiten an Gesangseinsätzen ausrichten, Songtext zuordnen.
    func transcribe() {
        guard let song = project?.song, project?.analysis != nil, !transcribing else { return }
        guard Self.transcriptionInstalled else {
            message = "Für die Gesangserkennung zuerst das Modell laden (Einstellungen → Modelle)."
            return
        }
        transcribing = true
        let path = song.path
        let language = UserDefaults.standard.string(forKey: "transcriptionLanguage").flatMap { $0.isEmpty ? nil : $0 }
        let client = services.inference
        services.jobs.submit("Gesang erkennen", resource: .inference) { [weak self] context in
            let owner = self
            defer { Task { @MainActor in owner?.transcribing = false } }
            await context.progress(nil, detail: "Transkription (Whisper)")
            let raw = try await client.transcribe(path: path, language: language)
            await context.progress(0.8, detail: "Wortzeiten ausrichten")
            let audio = try await AudioDecoder.decodeMono(URL(fileURLWithPath: path))
            let spectrum = Spectrum(audio)
            let corrected = WordTiming.correct(raw, spectrum: spectrum)
            await MainActor.run {
                guard let owner, let analysis = owner.project?.analysis else { return }
                let lyrics = owner.project?.lyricsText ?? ""
                var updated = LyricsWorkflow.apply(transcript: corrected, lyrics: lyrics, to: analysis)
                updated.language = language ?? "auto"
                updated.transcriptionModel = TranscriptionModel.title
                owner.document?.applyAnalysis { $0.analysis = updated }
                let uncertain = updated.words.filter(\.isUncertain).count
                owner.message =
                    raw.isEmpty
                    ? "Kein Gesang erkannt. Abschnitte bleiben aus der Audio-Struktur."
                    : "\(updated.words.count) Wörter erkannt"
                        + (uncertain > 0 ? ", \(uncertain) unsicher (orange)." : ".")
            }
        }
    }

    /// Richtet einen geänderten Songtext neu am vorhandenen Transkript aus (ohne neue Transkription).
    func alignLyrics() {
        guard let analysis = project?.analysis else { return }
        guard !analysis.transcript.isEmpty else {
            transcribe()
            return
        }
        let lyrics = project?.lyricsText ?? ""
        let updated = LyricsWorkflow.apply(transcript: analysis.transcript, lyrics: lyrics, to: analysis)
        document?.applyAnalysis { $0.analysis = updated }
        let uncertain = updated.words.filter(\.isUncertain).count
        message = "Songtext ausgerichtet: \(updated.lines.count) Zeilen, \(uncertain) unsichere Wörter."
    }
}

/// Transkriptionsmodell (WhisperKit large-v3 turbo); liegt im Modellordner, geladen wird es im Inferenzdienst.
enum TranscriptionModel {
    static let title = "Whisper large-v3 turbo"
    static let downloadBytes: Int64 = 632_000_000

    static var folder: URL {
        Locations.models.appendingPathComponent(
            "transcription/whisperkit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo_632MB")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }
}

/// Wiedergabe für Timeline und Vorschau: der Song allein oder, sobald es einen Schnitt gibt, die Vorschau-Komposition
/// (Bild plus Song). Beim Austausch bleiben Abspielposition und Abspielzustand erhalten.
@MainActor
@Observable
final class Playback {
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    /// Die Komposition mit Bild ist geladen (sonst nur der Song).
    private(set) var hasVideo = false
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var songURL: URL?

    init() {
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem != nil else { return }
                self.time = time.seconds
                self.isPlaying = self.player.rate > 0
            }
        }
    }

    /// Neuer Song: Wiedergabe beginnt wieder am Anfang, ohne Bild bis zur nächsten Komposition.
    func load(_ url: URL?) {
        player.pause()
        isPlaying = false
        time = 0
        songURL = url
        hasVideo = false
        replace(url.map { AVPlayerItem(url: $0) })
    }

    /// Vorschau mit Bild; Position und Abspielzustand bleiben.
    func show(_ composition: AVComposition, video: AVVideoComposition) {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = video
        hasVideo = true
        replace(item)
    }

    /// Zurück zum Song allein (z. B. wenn der Schnitt fehlt oder nicht kompiliert).
    func showSongOnly() {
        guard hasVideo else { return }
        hasVideo = false
        replace(songURL.map { AVPlayerItem(url: $0) })
    }

    private func replace(_ item: AVPlayerItem?) {
        let wasPlaying = player.rate > 0
        player.replaceCurrentItem(with: item)
        isReady = item != nil
        guard item != nil else { return }
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    func toggle() {
        guard isReady else { return }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        time = max(0, seconds)
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
