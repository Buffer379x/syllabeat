import AppKit
import SyllaBeatAudio
import SyllaBeatCore
import SyllaBeatUI

/// Misst das Zeichnen der Timeline: 6 min Song, 720 Beats, 12 Abschnitte, 600 Wörter, 300 Einstellungen.
@MainActor
func benchTimeline() {
    let duration = 360.0
    let beats = (0..<720).map { Beat(time: 0.25 + Double($0) * 0.5, isDownbeat: $0 % 4 == 0) }
    var sections: [SongSection] = []
    for i in 0..<12 {
        let chorus = i % 2 == 1
        let start = Double(i) * 30
        sections.append(
            SongSection(
                id: "s\(i)", kind: chorus ? .chorus : .verse, label: chorus ? "Refrain" : "Strophe", start: start,
                end: start + 30, repeatOf: chorus && i > 1 ? "s1" : nil))
    }
    let texts = ["Meer", "Strand", "Himmel", "Wellen", "Nacht"]
    var words: [Word] = []
    for i in 0..<600 {
        let start = 2 + Double(i) * 0.58
        words.append(
            Word(id: "w\(i)", text: texts[i % 5], start: start, end: start + 0.4, confidence: i % 9 == 0 ? 0.3 : 0.9))
    }
    let lines = stride(from: 0, to: 600, by: 6).map { i in
        LyricLine(id: "l\(i)", text: "Zeile \(i / 6)", start: words[i].start, end: words[min(599, i + 5)].end)
    }
    let shots = (0..<300).map { (i: Int) -> TimelineShot in
        let start = Double(i) * 1.2
        return TimelineShot(
            id: "shot-\(i + 1)", start: start, end: start + 1.2, name: "clip_\(i % 40).mov", locked: i % 10 == 0,
            copied: i % 7 == 0)
    }
    var samples = [Float](repeating: 0, count: Int(duration * 22_050))
    for i in samples.indices { samples[i] = Float(sin(Double(i) * 0.05) * 0.5 * sin(Double(i) / 9000)) }
    let waveform = Waveform(MonoAudio(samples: samples, sampleRate: 22_050))
    let canvas = TimelineCanvas()
    canvas.content = TimelineContent(
        duration: duration, beats: beats, meter: 4, sections: sections, words: words, lines: lines, shots: shots,
        waveform: waveform)
    let viewWidth: CGFloat = 1600
    for zoom in [viewWidth / duration, 20, 80, 250, 800] {
        canvas.pixelsPerSecond = zoom
        canvas.frame = NSRect(
            x: 0, y: 0, width: max(viewWidth, CGFloat(duration * zoom)), height: TimelineCanvas.totalHeight)
        guard
            let bitmap = canvas.bitmapImageRepForCachingDisplay(
                in: NSRect(x: 0, y: 0, width: viewWidth, height: TimelineCanvas.totalHeight))
        else { continue }
        var times: [Double] = []
        // Durch die Timeline scrollen und jeweils einen fenstergroßen Ausschnitt zeichnen.
        let steps = 40
        for step in 0..<steps {
            let maxX = max(0, canvas.frame.width - viewWidth)
            let rect = NSRect(
                x: maxX * CGFloat(step) / CGFloat(steps - 1), y: 0, width: viewWidth, height: TimelineCanvas.totalHeight
            )
            canvas.playhead = Double(rect.midX) / zoom
            let start = now()
            canvas.cacheDisplay(in: rect, to: bitmap)
            times.append((now() - start) * 1000)
        }
        times.sort()
        print(
            String(
                format: "Zoom %6.1f px/s: Median %.1f ms, schlechtester %.1f ms je Bild (%.0f px breit)", zoom,
                times[times.count / 2], times.last!, viewWidth))
    }
}
