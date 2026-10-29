import Foundation

/// Zufällige, aber gültige Projekte für Property-Tests und Messungen der Engine (`sbtool bench-cut`).
public enum SyntheticProject {
    public static func make(
        seed: UInt64, clips clipRange: ClosedRange<Int> = 3...30, duration durationRange: ClosedRange<Double> = 25...240
    ) -> Project {
        var random = SeededRandom(seed: seed)
        func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(random.next() % UInt64(range.count)) }
        func double(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + random.unit() * (range.upperBound - range.lowerBound)
        }

        let rates = [Rational(24000, 1001), Rational(25), Rational(30000, 1001), Rational(50), Rational(60000, 1001)]
        let tempo = double(70...180)
        let duration = double(durationRange)
        let phase = int(0...3)
        var beats: [Beat] = []
        var time = double(0.05...0.8)
        var index = 0
        while time < duration - 0.05 {
            beats.append(Beat(time: (time * 1000).rounded() / 1000, isDownbeat: (index - phase) % 4 == 0))
            time += 60 / tempo * double(0.97...1.03)
            index += 1
        }
        // Abschnitte: Strophe/Refrain abwechselnd, Refrains gleich lang (Familien), Rest frei.
        var sections: [SongSection] = []
        var start = 0.0
        let barLength = 4 * 60 / tempo
        let chorusBars = int(2...6)
        var number = 0
        while start < duration - 1 {
            let chorus = number % 2 == 1
            let bars = chorus ? chorusBars : int(2...8)
            let end = min(duration, start + Double(bars) * barLength)
            let first = sections.first { $0.kind == .chorus }
            sections.append(
                SongSection(
                    id: "s\(number)", kind: chorus ? .chorus : .verse, label: chorus ? "Refrain" : "Strophe",
                    start: start, end: end, repeatOf: chorus && first != nil && random.unit() < 0.8 ? first!.id : nil))
            start = end
            number += 1
        }
        sections[sections.count - 1].end = duration
        let words = (0..<int(0...60)).map { i in
            let t = double(0...(duration - 1))
            return Word(id: "w\(i)", text: "wort", start: t, end: t + 0.3, confidence: random.unit())
        }.sorted { $0.start < $1.start }
        var analysis = SongAnalysis(
            duration: duration, tempo: tempo, beats: beats, words: words, sections: sections,
            energy: beats.map { _ in Float(random.unit()) })
        analysis.lines = [LyricLine(id: "l0", text: "Zeile", start: 1, end: 5)]
        var clips: [Clip] = []
        for c in 0..<int(clipRange) {
            let rate = rates[int(0...rates.count - 1)]
            let length = double(3...45)
            var scenes: [ClipScene] = []
            var s = 0.0
            var n = 0
            while s < length - 0.5 {
                let e = min(length, s + double(0.8...9))
                scenes.append(
                    ClipScene(
                        id: "c\(c)-s\(n)", start: s, end: e,
                        features: SceneFeatures(
                            aesthetics: double(-1...1), isUtility: random.unit() < 0.05, faceCount: int(0...2),
                            shotSize: ShotSize.allCases[int(0...2)], sharpness: double(0...500), motion: random.unit()),
                        continuesPrevious: n > 0 && random.unit() < 0.3))
                s = e
                n += 1
            }
            clips.append(
                Clip(
                    id: "c\(c)", media: MediaRef(path: "/tmp/c\(c).mov"),
                    meta: ClipMetadata(
                        duration: length, fps: rate, frameCount: (Rational(seconds: length) * rate).roundedHalfUp(),
                        width: 1920, height: 1080),
                    scenes: scenes, rating: random.unit() < 0.2 ? int(1...5) : nil, excluded: random.unit() < 0.1))
        }
        if clips.allSatisfy(\.excluded) { clips[0].excluded = false }
        var style = CutStyle(preset: CutStyle.Preset.allCases[int(0...3)], seed: random.next() % 1000)
        style.variation = CutStyle.Variation.allCases[int(0...2)]
        style.refrainMode = CutStyle.RefrainMode.allCases[int(0...2)]
        style.alignToWords = random.unit() < 0.5
        let fps = [Rational(25), Rational(24000, 1001), Rational(30), Rational(60000, 1001)][int(0...3)]
        // Jedes dritte Projekt mit Storyboard (Schnitttempo je Abschnitt).
        let storyboard: Storyboard? =
            random.unit() < 0.33
            ? Storyboard(
                idea: "Test",
                sections: sections.map { section in
                    Storyboard.SectionPlan(
                        sectionID: section.id, mood: "ruhig", imageIdea: "", searchTerms: ["Meer"],
                        pace: Storyboard.Pace.allCases[int(0...2)])
                }, model: "Zufall", brief: "")
            : nil
        var project = Project(
            name: "Zufall \(seed)", timeline: TimelineSettings(fps: fps), clips: clips, analysis: analysis, style: style
        )
        project.storyboard = storyboard
        return project
    }
}
