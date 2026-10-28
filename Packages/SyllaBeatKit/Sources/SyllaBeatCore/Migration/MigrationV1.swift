import Foundation

/// Überführt ein 0.2.0-Projekt verlustarm ins Format v2.
///
/// Erhalten bleiben Clips mit Szenen und Beschreibungen, Beats, Textzeilen, Wörter, Abschnitte, Schnittstil und
/// der Schnittplan. Beat-IDs werden zu Schnittpunkten mit `beat(i)`-Anker. Base64-Vorschaubilder entfallen;
/// sie werden aus den Medien neu erzeugt, und die Sicherungskopie im alten Format behält sie.
enum MigrationV1 {
    static func migrate(_ old: LegacyV1.Project) throws -> Project {
        var notes: [String] = []
        var project = Project(name: old.name?.nonEmpty ?? "Neues Musikvideo")
        if let timeline = old.timeline {
            guard timeline.fpsNum > 0, timeline.fpsDen > 0 else {
                throw ProjectFileError.invalid("Die Timeline-Bildrate ist ungültig.")
            }
            project.timeline = TimelineSettings(
                fps: Rational(Int64(timeline.fpsNum), Int64(timeline.fpsDen)), width: timeline.width,
                height: timeline.height)
        }
        if let path = old.audioPath?.nonEmpty {
            project.song = MediaRef(path: path)
        }
        project.lyricsText = old.lyrics ?? ""
        project.clips = try (old.clips ?? []).map(migrate)
        if let audio = old.audio, let duration = audio.duration, duration > 0 {
            project.analysis = migrate(audio, duration: duration)
        }
        if let style = old.cutStyle {
            project.style = migrate(style)
        }
        if let plan = old.plan {
            if let analysis = project.analysis {
                do {
                    project.cut = try migrate(plan, analysis: analysis, clips: project.clips, seed: project.style.seed)
                } catch let ProjectFileError.invalid(reason) {
                    notes.append("Der Schnittplan aus 0.2.0 wurde nicht übernommen: \(reason)")
                }
            } else {
                notes.append("Der Schnittplan aus 0.2.0 wurde nicht übernommen, weil die Songanalyse fehlt.")
            }
        }
        project.legacy = LegacyInfo(
            sourceVersion: old.version, videoFolder: old.videoDir ?? "", planDraft: old.planDraft?.nonEmpty,
            notes: notes)
        return project
    }

    private static func migrate(_ clip: LegacyV1.Clip) throws -> Clip {
        guard clip.fpsNum > 0, clip.fpsDen > 0 else {
            throw ProjectFileError.invalid("Clip „\(clip.name)“ hat eine ungültige Bildrate.")
        }
        let rotation = ((Int((clip.rotation ?? 0).rounded()) % 360) + 360) % 360
        let meta = ClipMetadata(
            duration: clip.duration, fps: Rational(Int64(clip.fpsNum), Int64(clip.fpsDen)),
            frameCount: (clip.frameCount ?? 0) > 0 ? clip.frameCount : nil, width: clip.width, height: clip.height,
            rotation: rotation, codec: clip.codec?.nonEmpty, isVFR: clip.isVFR, sizeBytes: clip.sizeBytes,
            warnings: clip.metadataWarnings ?? [])
        let scenes = (clip.segments ?? []).enumerated().map { index, segment in
            ClipScene(
                id: "\(clip.id)-s\(index + 1)", start: segment.start, end: segment.end,
                description: segment.description ?? "")
        }
        let vision = clip.vision
        let description = clip.description?.nonEmpty ?? vision?.description?.nonEmpty ?? ""
        return Clip(
            id: clip.id, media: MediaRef(path: clip.path, fingerprint: clip.fingerprint?.nonEmpty), meta: meta,
            scenes: scenes, description: description, tags: clip.tags ?? vision?.tags ?? [],
            mood: vision?.mood?.nonEmpty, visionModel: clip.visionModel?.nonEmpty,
            filenameSuggestion: clip.suggestedFilename?.nonEmpty ?? vision?.filenameSuggestion?.nonEmpty,
            originalName: clip.originalName?.nonEmpty)
    }

    /// Beats wie `beat_boundaries` in 0.2.0: sortiert, streng innerhalb des Songs, ohne Dubletten.
    static func interiorBeats(_ beats: [Double], duration: Double) -> [Double] {
        var result: [Double] = []
        var previous = 0.0
        for beat in beats.filter({ $0.isFinite && $0 > 0 && $0 < duration }).sorted()
        where beat - previous > 0.000001 && duration - beat > 0.000001 {
            result.append(beat)
            previous = beat
        }
        return result
    }

    private static func migrate(_ audio: LegacyV1.Audio, duration: Double) -> SongAnalysis {
        let beats = interiorBeats(audio.beats ?? [], duration: duration).map { Beat(time: $0) }
        let words = (audio.words ?? []).enumerated().map { index, word in
            Word(
                id: "w\(index + 1)", text: word.word ?? "", start: word.start, end: word.end,
                confidence: word.probability, estimated: word.estimated ?? false)
        }
        let lines = (audio.lines ?? []).enumerated().map { index, line in
            LyricLine(
                id: line.id?.nonEmpty ?? String(format: "line_%04d", index + 1), text: line.text ?? "",
                start: line.start, end: line.end, confidence: line.confidence, needsReview: line.needsReview ?? false)
        }
        let sections = (audio.sections ?? []).map { section in
            SongSection(
                id: section.id, kind: SongSection.Kind(label: section.label ?? ""), label: section.label ?? "",
                start: section.start, end: section.end, repeatOf: section.repeatOf?.nonEmpty,
                needsReview: section.needsReview ?? false)
        }
        return SongAnalysis(
            duration: duration, sampleRate: audio.sampleRate ?? 48000, channels: audio.channels ?? 2,
            tempo: audio.tempo ?? 0, beats: beats, words: words, lines: lines, sections: sections,
            language: audio.language?.nonEmpty, transcriptionModel: audio.whisperModel?.nonEmpty,
            warnings: audio.warnings ?? [])
    }

    private static func migrate(_ style: LegacyV1.CutStyle) -> CutStyle {
        let verse = min(max(style.verseBeats ?? 4, 1), 64)
        var result = CutStyle(preset: .nearest(verseBeats: verse), seed: UInt64(max(style.seed ?? 1, 0)))
        result.verseBeats = verse
        result.chorusBeats = min(max(style.chorusBeats ?? 2, 1), 64)
        result.chorusFaster = style.chorusFaster ?? true
        switch style.variation {
        case "gleichmaessig": result.variation = .low
        case "wild": result.variation = .high
        default: result.variation = .medium
        }
        return result
    }

    private static func migrate(
        _ plan: LegacyV1.Plan, analysis: SongAnalysis, clips: [Clip], seed: UInt64
    ) throws
        -> Cut
    {
        guard plan.version == 1 else { throw ProjectFileError.invalid("unbekannte Planversion \(plan.version)") }
        let boundaries = analysis.boundaries
        let last = boundaries.count - 1
        let clipsByID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func point(_ index: Int) -> CutPoint {
            let anchor: Anchor = index == 0 ? .songStart : index == last ? .songEnd : .beat(index - 1)
            return CutPoint(time: boundaries[index], anchor: anchor)
        }
        var shots: [Shot] = []
        for (number, old) in plan.shots.enumerated() {
            guard 0 <= old.startBeat, old.startBeat < old.endBeat, old.endBeat <= last else {
                throw ProjectFileError.invalid("Shot \(number + 1) verweist auf ungültige Beat-IDs.")
            }
            guard let clip = clipsByID[old.clipID] else {
                throw ProjectFileError.invalid("Shot \(number + 1) verweist auf den unbekannten Clip „\(old.clipID)“.")
            }
            let scene = clip.scenes.first { $0.start <= old.sourceIn && old.sourceIn < $0.end }
            shots.append(
                Shot(
                    id: "shot-\(number + 1)", start: point(old.startBeat), end: point(old.endBeat), clipID: old.clipID,
                    sceneID: scene?.id, sourceIn: Rational(seconds: old.sourceIn)))
        }
        return Cut(id: "legacy", name: "Schnitt aus 0.2", seed: seed, origin: .legacyPlan, shots: shots)
    }
}

extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
