import Foundation
import SyllaBeatCore

enum Format {
    /// `1:27,90` – Minuten, Sekunden, Hundertstel.
    static func time(_ seconds: Double) -> String {
        let total = max(0, (seconds * 100).rounded())
        let minutes = Int(total / 6000)
        let rest = total - Double(minutes) * 6000
        return String(format: "%d:%05.2f", minutes, rest / 100).replacingOccurrences(of: ".", with: ",")
    }

    /// `10,0 s`
    static func duration(_ seconds: Double) -> String {
        seconds.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "de_DE"))) + " s"
    }

    /// `25`, `29,97`, `23,976` – mit Bruch, wenn die Rate nicht ganzzahlig ist.
    static func fps(_ rate: Rational) -> String {
        let value = rate.doubleValue
        let text = value.formatted(.number.precision(.fractionLength(0...3)).locale(Locale(identifier: "de_DE")))
        return rate.denominator == 1 ? text : "\(text) (\(rate))"
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }
}
