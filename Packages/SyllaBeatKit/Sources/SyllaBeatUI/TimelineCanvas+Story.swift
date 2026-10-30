import AppKit
import SyllaBeatCore

/// Kapitel einer Einstellung in der Spur „Kapitel“.
public struct TimelineChapterBar: Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// Index in `ChapterPalette`.
    public var color: Int
    public var name: String

    public init(start: Double, end: Double, color: Int, name: String) {
        self.start = start
        self.end = end
        self.color = color
        self.name = name
    }
}

/// Ungereimtheit an einer Stelle der Bildspur.
public struct TimelineMarker: Equatable, Sendable {
    public var time: Double
    public var message: String

    public init(time: Double, message: String) {
        self.time = time
        self.message = message
    }
}

/// Farben der Kapitel: bewusst andere als die Abschnittsfarben (Blau, Violett, Mint, Pink, Grau).
public enum ChapterPalette {
    static let colors: [NSColor] = [
        .systemOrange, .systemTeal, .systemIndigo, .systemBrown, .systemYellow, .systemGreen, .systemRed, .systemCyan,
    ]

    public static func color(_ index: Int) -> NSColor { colors[((index % colors.count) + colors.count) % colors.count] }
}

extension TimelineCanvas {
    /// Spur „Kapitel“: Farbbalken je Einstellung, Name bei genug Platz.
    func drawChapters(_ area: NSRect, _ visible: ClosedRange<Double>) {
        for bar in content.chapterBars where bar.end >= visible.lowerBound && bar.start <= visible.upperBound {
            let box = NSRect(
                x: x(bar.start), y: area.minY + 3, width: max(1, x(bar.end) - x(bar.start)), height: area.height - 6)
            ChapterPalette.color(bar.color).withAlphaComponent(0.75).setFill()
            box.fill()
            if box.width > 60 {
                drawText(
                    bar.name, in: box.insetBy(dx: 4, dy: -2), font: .systemFont(ofSize: 9, weight: .semibold),
                    color: .white)
            }
        }
    }

    /// Ungereimtheiten als orange Dreiecke oben in der Bildspur.
    func drawMarkers(_ area: NSRect, _ visible: ClosedRange<Double>) {
        NSColor.systemOrange.setFill()
        for marker in content.markers where visible.contains(marker.time) {
            let tip = NSPoint(x: x(marker.time) + 6, y: area.minY + 2)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: tip.x - 5, y: tip.y))
            path.line(to: NSPoint(x: tip.x + 5, y: tip.y))
            path.line(to: NSPoint(x: tip.x, y: tip.y + 8))
            path.close()
            path.fill()
        }
    }
}
