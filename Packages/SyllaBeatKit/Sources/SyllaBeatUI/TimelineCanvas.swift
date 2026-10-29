import AppKit
import SyllaBeatAudio
import SyllaBeatCore

/// Daten, die die Timeline zeichnet (Werttyp; jede Änderung zeichnet neu).
public struct TimelineContent: Equatable {
    public var duration: Double
    public var beats: [Beat]
    public var meter: Int
    public var sections: [SongSection]
    public var words: [Word]
    public var lines: [LyricLine]
    public var shots: [(start: Double, end: Double, name: String)]
    public var waveform: Waveform?

    public init(
        duration: Double, beats: [Beat], meter: Int, sections: [SongSection], words: [Word], lines: [LyricLine] = [],
        shots: [(start: Double, end: Double, name: String)], waveform: Waveform? = nil
    ) {
        self.duration = duration
        self.beats = beats
        self.meter = meter
        self.sections = sections
        self.words = words
        self.lines = lines
        self.shots = shots
        self.waveform = waveform
    }

    public static func == (a: TimelineContent, b: TimelineContent) -> Bool {
        a.duration == b.duration && a.beats == b.beats && a.meter == b.meter && a.sections == b.sections
            && a.words == b.words && a.lines == b.lines && a.waveform == b.waveform && a.shots.count == b.shots.count
            && zip(a.shots, b.shots).allSatisfy { $0.start == $1.start && $0.end == $1.end && $0.name == $1.name }
    }
}

/// Aktionen der Timeline; das Fenster setzt sie in Befehle mit Undo um.
public struct TimelineActions {
    public var seek: (Double) -> Void
    public var run: (any EditCommand) -> Void
    public var zoom: (Double, Double) -> Void

    public init(
        seek: @escaping (Double) -> Void = { _ in }, run: @escaping (any EditCommand) -> Void = { _ in },
        zoom: @escaping (Double, Double) -> Void = { _, _ in }
    ) {
        self.seek = seek
        self.run = run
        self.zoom = zoom
    }
}

/// Zeichenfläche der Timeline: vier Spuren, nur der sichtbare Bereich wird gezeichnet.
public final class TimelineCanvas: NSView {
    public enum Track: Int, CaseIterable, Sendable {
        case sections, text, song, image

        public var height: CGFloat {
            switch self {
            case .sections: 28
            case .text: 34
            case .song: 72
            case .image: 48
            }
        }

        public var title: String {
            switch self {
            case .sections: "Abschnitte"
            case .text: "Text"
            case .song: "Song"
            case .image: "Bild"
            }
        }
    }

    public static var totalHeight: CGFloat { Track.allCases.reduce(0) { $0 + $1.height } }

    public var content = TimelineContent(duration: 1, beats: [], meter: 4, sections: [], words: [], shots: []) {
        didSet { if content != oldValue { needsDisplay = true } }
    }
    public var pixelsPerSecond: Double = 20 {
        didSet { if pixelsPerSecond != oldValue { needsDisplay = true } }
    }
    public var playhead: Double = 0 {
        didSet {
            guard playhead != oldValue else { return }
            let oldX = x(oldValue)
            let newX = x(playhead)
            setNeedsDisplay(NSRect(x: min(oldX, newX) - 2, y: 0, width: abs(newX - oldX) + 4, height: bounds.height))
        }
    }
    public var actions = TimelineActions()

    private var draggedBoundary: (sectionID: String, time: Double)?
    private var editor: NSTextField?
    private var editedWordID: String?

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    public func x(_ time: Double) -> CGFloat { CGFloat(time * pixelsPerSecond) }
    public func time(_ x: CGFloat) -> Double { Double(x) / pixelsPerSecond }

    func rect(of track: Track) -> NSRect {
        let y = Track.allCases.prefix(track.rawValue).reduce(0) { $0 + $1.height }
        return NSRect(x: 0, y: y, width: bounds.width, height: track.height)
    }

    func track(at point: NSPoint) -> Track? {
        Track.allCases.first { rect(of: $0).minY <= point.y && point.y < rect(of: $0).maxY }
    }

    // MARK: Zeichnen

    override public func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let visible = time(dirtyRect.minX - 2)...time(dirtyRect.maxX + 2)
        for track in Track.allCases {
            let area = rect(of: track)
            guard area.intersects(dirtyRect) else { continue }
            if track.rawValue % 2 == 1 {
                NSColor.labelColor.withAlphaComponent(0.035).setFill()
                area.intersection(dirtyRect).fill()
            }
            switch track {
            case .sections: drawSections(area, visible)
            case .text: drawWords(area, visible)
            case .song: drawSong(area, visible)
            case .image: drawShots(area, visible)
            }
            NSColor.separatorColor.setFill()
            NSRect(x: dirtyRect.minX, y: area.maxY - 1, width: dirtyRect.width, height: 1).fill()
        }
        let playheadX = x(playhead)
        if dirtyRect.minX - 2 <= playheadX, playheadX <= dirtyRect.maxX + 2 {
            NSColor.controlAccentColor.setFill()
            NSRect(x: playheadX - 1, y: 0, width: 2, height: bounds.height).fill()
        }
    }

    private func drawSections(_ area: NSRect, _ visible: ClosedRange<Double>) {
        let families = Dictionary(grouping: content.sections, by: { $0.repeatOf ?? $0.id }).mapValues(\.count)
        for section in content.sections where section.end >= visible.lowerBound && section.start <= visible.upperBound {
            var start = section.start
            if let dragged = draggedBoundary, dragged.sectionID == section.id { start = dragged.time }
            var end = section.end
            if let dragged = draggedBoundary, let next = content.sections.first(where: { $0.start == section.end }),
                dragged.sectionID == next.id
            {
                end = dragged.time
            }
            let box = NSRect(
                x: x(start) + 1, y: area.minY + 3, width: max(1, x(end) - x(start) - 2), height: area.height - 6)
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            section.kind.nsColor.withAlphaComponent(0.35).setFill()
            path.fill()
            if section.needsReview {
                section.kind.nsColor.withAlphaComponent(0.8).setStroke()
                path.setLineDash([3, 2], count: 2, phase: 0)
                path.lineWidth = 1
                path.stroke()
            }
            let count = families[section.repeatOf ?? section.id] ?? 1
            let title = count > 1 ? "\(section.label) ●×\(count)" : section.label
            drawText(
                title, in: box.insetBy(dx: 5, dy: 0), font: .systemFont(ofSize: 11, weight: .medium), color: .labelColor
            )
        }
    }

    /// Gesamtansicht: ganze Zeilen; vergrößert: Wörter (Text bis zum nächsten Wort gekürzt), ab 160 px/s mit Silben.
    private func drawWords(_ area: NSRect, _ visible: ClosedRange<Double>) {
        let averageWidth =
            content.words.isEmpty
            ? 0 : content.words.reduce(0) { $0 + x($1.end) - x($1.start) } / CGFloat(content.words.count)
        if averageWidth < 34, !content.lines.isEmpty {
            for (index, line) in content.lines.enumerated()
            where line.end >= visible.lowerBound && line.start <= visible.upperBound {
                let box = NSRect(
                    x: x(line.start), y: area.minY + 4, width: max(2, x(line.end) - x(line.start)),
                    height: area.height - 8)
                let color: NSColor = line.needsReview ? .systemOrange : .labelColor
                color.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
                color.setFill()
                NSRect(x: box.minX, y: box.minY, width: 1.5, height: box.height).fill()
                // Der Text darf bis zur nächsten Zeile laufen.
                let next = index + 1 < content.lines.count ? x(content.lines[index + 1].start) : box.maxX + 200
                drawText(
                    line.text,
                    in: NSRect(x: box.minX + 4, y: box.minY, width: max(0, next - box.minX - 8), height: box.height),
                    font: .systemFont(ofSize: 11), color: .labelColor)
            }
            return
        }
        let showSyllables = pixelsPerSecond >= 160
        for (index, word) in content.words.enumerated()
        where word.end >= visible.lowerBound && word.start <= visible.upperBound {
            let left = x(word.start)
            let width = max(2, x(word.end) - left)
            let next = index + 1 < content.words.count ? x(content.words[index + 1].start) : left + max(width, 60)
            let color: NSColor = word.isUncertain ? .systemOrange : .labelColor
            color.withAlphaComponent(0.14).setFill()
            NSRect(x: left, y: area.minY + 4, width: width, height: area.height - 8).fill()
            color.setFill()
            NSRect(x: left, y: area.minY + 4, width: 1.5, height: area.height - 8).fill()
            if showSyllables, word.syllables.count > 1 {
                NSColor.tertiaryLabelColor.setFill()
                for syllable in word.syllables.dropFirst() {
                    NSRect(x: x(syllable.start), y: area.maxY - 10, width: 1, height: 6).fill()
                }
            }
            let label =
                showSyllables && word.syllables.count > 1
                ? word.syllables.map(\.text).joined(separator: "·") : word.text
            drawText(
                label, in: NSRect(x: left + 3, y: area.minY, width: max(0, next - left - 5), height: area.height),
                font: .systemFont(ofSize: 11), color: color)
        }
    }

    private func drawSong(_ area: NSRect, _ visible: ClosedRange<Double>) {
        let middle = area.midY
        if let waveform = content.waveform, !waveform.minimum.isEmpty {
            NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
            let firstPixel = max(0, Int(x(visible.lowerBound)))
            let lastPixel = min(Int(bounds.width), Int(x(visible.upperBound)) + 1)
            let binsPerPixel = Waveform.binsPerSecond / pixelsPerSecond
            if firstPixel < lastPixel {
                for pixel in firstPixel..<lastPixel {
                    let a = Int(Double(pixel) * binsPerPixel)
                    let b = max(a + 1, Int(Double(pixel + 1) * binsPerPixel))
                    guard a < waveform.minimum.count else { break }
                    var low: Float = 0
                    var high: Float = 0
                    for bin in a..<min(b, waveform.minimum.count) {
                        low = min(low, waveform.minimum[bin])
                        high = max(high, waveform.maximum[bin])
                    }
                    let scale = (area.height - 8) / 2
                    let top = middle - CGFloat(high) * scale
                    let bottom = middle - CGFloat(low) * scale
                    NSRect(x: CGFloat(pixel), y: top, width: 1, height: max(1, bottom - top)).fill()
                }
            }
        }
        let range = beatRange(visible)
        let crowded = pixelsPerSecond * 60 / max(1, tempo) < 4
        for index in range {
            let beat = content.beats[index]
            if crowded, !beat.isDownbeat { continue }
            (beat.isDownbeat
                ? NSColor.labelColor.withAlphaComponent(0.75) : NSColor.secondaryLabelColor.withAlphaComponent(0.6))
                .setFill()
            let height = beat.isDownbeat ? area.height - 6 : area.height * 0.45
            NSRect(x: x(beat.time) - 0.5, y: middle - height / 2, width: beat.isDownbeat ? 1.5 : 1, height: height)
                .fill()
        }
    }

    private func drawShots(_ area: NSRect, _ visible: ClosedRange<Double>) {
        if content.shots.isEmpty {
            let visibleArea = NSRect(
                x: max(area.minX, visibleRect.minX), y: area.minY, width: visibleRect.width, height: area.height)
            drawText(
                "Noch kein Schnitt", in: visibleArea.insetBy(dx: 12, dy: 0), font: .systemFont(ofSize: 11),
                color: .tertiaryLabelColor)
            return
        }
        for (index, shot) in content.shots.enumerated()
        where shot.end >= visible.lowerBound && shot.start <= visible.upperBound {
            let box = NSRect(
                x: x(shot.start) + 0.5, y: area.minY + 4, width: max(1, x(shot.end) - x(shot.start) - 1),
                height: area.height - 8)
            NSColor.controlAccentColor.withAlphaComponent(index.isMultiple(of: 2) ? 0.45 : 0.28).setFill()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
            if box.width > 30 {
                drawText(shot.name, in: box.insetBy(dx: 4, dy: 0), font: .systemFont(ofSize: 10), color: .labelColor)
            }
        }
    }

    private var tempo: Double {
        guard content.beats.count > 1 else { return 120 }
        return 60 * Double(content.beats.count - 1) / (content.beats.last!.time - content.beats.first!.time)
    }

    /// Beats im sichtbaren Bereich (binäre Suche, Beats sind sortiert).
    func beatRange(_ visible: ClosedRange<Double>) -> Range<Int> {
        func firstIndex(atLeast time: Double) -> Int {
            var low = 0
            var high = content.beats.count
            while low < high {
                let mid = (low + high) / 2
                if content.beats[mid].time < time { low = mid + 1 } else { high = mid }
            }
            return low
        }
        return firstIndex(atLeast: visible.lowerBound)..<firstIndex(atLeast: visible.upperBound)
    }

    private func drawText(_ text: String, in box: NSRect, font: NSFont, color: NSColor) {
        guard box.width > 8 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: box.minX, y: box.midY - size.height / 2, width: box.width, height: size.height)
        (text as NSString).draw(
            with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    // MARK: Bedienung

    private func boundary(near point: NSPoint) -> SongSection? {
        guard track(at: point) == .sections else { return nil }
        return content.sections.dropFirst().first { abs(x($0.start) - point.x) <= 5 }
    }

    private func nearestBeat(to time: Double) -> Int? {
        content.beats.indices.min { abs(content.beats[$0].time - time) < abs(content.beats[$1].time - time) }
    }

    override public func resetCursorRects() {
        let area = rect(of: .sections)
        for section in content.sections.dropFirst() {
            addCursorRect(
                NSRect(x: x(section.start) - 4, y: area.minY, width: 8, height: area.height), cursor: .resizeLeftRight)
        }
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, track(at: point) == .text, let word = word(at: point) {
            beginEditing(word)
            return
        }
        if let section = boundary(near: point) {
            draggedBoundary = (section.id, section.start)
            return
        }
        actions.seek(max(0, min(content.duration, time(point.x))))
    }

    override public func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let dragged = draggedBoundary {
            // Grenzen rasten an Beats ein; mit ⌥ frei.
            var target = time(point.x)
            if !event.modifierFlags.contains(.option), let beat = nearestBeat(to: target) {
                target = content.beats[beat].time
            }
            draggedBoundary = (dragged.sectionID, target)
            needsDisplay = true
            return
        }
        actions.seek(max(0, min(content.duration, time(point.x))))
        autoscroll(with: event)
    }

    override public func mouseUp(with event: NSEvent) {
        guard let dragged = draggedBoundary else { return }
        draggedBoundary = nil
        needsDisplay = true
        if let section = content.sections.first(where: { $0.id == dragged.sectionID }),
            abs(section.start - dragged.time) > 0.001
        {
            actions.run(MoveSectionBoundary(sectionID: dragged.sectionID, time: dragged.time))
        }
    }

    override public func magnify(with event: NSEvent) {
        let anchor = time(convert(event.locationInWindow, from: nil).x)
        actions.zoom(pixelsPerSecond * (1 + event.magnification), anchor)
    }

    private func word(at point: NSPoint) -> Word? {
        let t = time(point.x)
        return content.words.first { $0.start - 0.05 <= t && t <= max($0.end, $0.start + 0.3) }
    }

    override public func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let at = time(point.x)
        let menu = NSMenu()
        switch track(at: point) {
        case .song:
            if let index = nearestBeat(to: at), abs(content.beats[index].time - at) < 0.25 {
                menu.addItem(
                    item("Taktanfang hier") { [weak self] in self?.actions.run(SetDownbeat(beatIndex: index)) })
                menu.addItem(item("Beat löschen") { [weak self] in self?.actions.run(DeleteBeat(beatIndex: index)) })
            }
            menu.addItem(item("Beat hier einfügen") { [weak self] in self?.actions.run(InsertBeat(time: at)) })
        case .sections:
            guard let section = content.sections.first(where: { $0.start <= at && at < $0.end }) else { return nil }
            let kinds = NSMenu()
            for kind in SongSection.Kind.allCases {
                kinds.addItem(
                    item(kind.title, checked: kind == section.kind) { [weak self] in
                        self?.actions.run(SetSectionKind(sectionID: section.id, kind: kind, label: kind.title))
                    })
            }
            let kindItem = NSMenuItem(title: "Typ", action: nil, keyEquivalent: "")
            kindItem.submenu = kinds
            menu.addItem(kindItem)
            let repeats = NSMenu()
            repeats.addItem(
                item("Keine", checked: section.repeatOf == nil) { [weak self] in
                    self?.actions.run(SetSectionRepeat(sectionID: section.id, repeatOf: nil))
                })
            for earlier in content.sections where earlier.start < section.start && earlier.repeatOf == nil {
                repeats.addItem(
                    item("\(earlier.label) ab \(Format.time(earlier.start))", checked: section.repeatOf == earlier.id) {
                        [weak self] in
                        self?.actions.run(SetSectionRepeat(sectionID: section.id, repeatOf: earlier.id))
                    })
            }
            let repeatItem = NSMenuItem(title: "Wiederholung von", action: nil, keyEquivalent: "")
            repeatItem.submenu = repeats
            menu.addItem(repeatItem)
            menu.addItem(.separator())
            menu.addItem(item("Hier teilen") { [weak self] in self?.actions.run(SplitSection(time: at)) })
            if section.start > 0 {
                menu.addItem(
                    item("Mit vorigem verbinden") { [weak self] in
                        self?.actions.run(MergeSectionWithPrevious(sectionID: section.id))
                    })
            }
        case .text:
            guard let word = word(at: point) else { return nil }
            menu.addItem(item("„\(word.text)“ korrigieren …") { [weak self] in self?.beginEditing(word) })
        default:
            return nil
        }
        return menu
    }

    private func item(_ title: String, checked: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: action)
        item.state = checked ? .on : .off
        return item
    }

    // MARK: Wort korrigieren

    private func beginEditing(_ word: Word) {
        editor?.removeFromSuperview()
        let area = rect(of: .text)
        let field = NSTextField(string: word.text)
        field.frame = NSRect(
            x: x(word.start), y: area.minY + 5, width: max(90, x(word.end) - x(word.start) + 30), height: 22)
        field.target = self
        field.action = #selector(commitWord(_:))
        field.focusRingType = .exterior
        field.setAccessibilityLabel("Wort korrigieren")
        addSubview(field)
        window?.makeFirstResponder(field)
        editor = field
        editedWordID = word.id
    }

    @objc private func commitWord(_ sender: NSTextField) {
        let text = sender.stringValue
        let id = editedWordID
        sender.removeFromSuperview()
        editor = nil
        editedWordID = nil
        window?.makeFirstResponder(self)
        if let id, let word = content.words.first(where: { $0.id == id }), word.text != text {
            actions.run(EditWord(wordID: id, text: text))
        }
    }

    override public func cancelOperation(_ sender: Any?) {
        editor?.removeFromSuperview()
        editor = nil
        editedWordID = nil
    }

    // MARK: Barrierefreiheit

    override public func isAccessibilityElement() -> Bool { true }
    override public func accessibilityRole() -> NSAccessibility.Role? { .group }
    override public func accessibilityLabel() -> String? {
        "Timeline: \(content.sections.count) Abschnitte, \(content.words.count) Wörter, \(content.beats.count) Beats, \(content.shots.count) Einstellungen"
    }
}

/// Menüeintrag mit Closure statt Target/Action.
public final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    public init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    public required init(coder: NSCoder) { fatalError("nicht unterstützt") }

    @objc private func fire() { handler() }
}

extension SongSection.Kind {
    public var title: String {
        switch self {
        case .intro: "Intro"
        case .verse: "Strophe"
        case .preChorus: "Pre-Chorus"
        case .chorus: "Refrain"
        case .bridge: "Bridge"
        case .instrumental: "Zwischenspiel"
        case .outro: "Outro"
        case .other: "Sonstiges"
        }
    }

    public var nsColor: NSColor {
        switch self {
        case .verse: .systemBlue
        case .preChorus: .systemPurple
        case .chorus: .systemMint
        case .bridge: .systemPink
        case .intro, .outro: .systemGray
        case .instrumental: .systemTeal
        case .other: .secondaryLabelColor
        }
    }
}
