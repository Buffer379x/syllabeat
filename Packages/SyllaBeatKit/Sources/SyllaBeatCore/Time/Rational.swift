import Foundation

/// Exakte Bruchzahl für Bildraten und Zeitpunkte. Zähler und Nenner sind immer gekürzt, der Nenner ist positiv.
public struct Rational: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let numerator: Int64
    public let denominator: Int64

    public init(_ numerator: Int64, _ denominator: Int64 = 1) {
        precondition(denominator != 0, "Nenner 0")
        self.init(reducing: Int128(numerator), Int128(denominator))
    }

    public init(_ value: Int) {
        self.init(Int64(value), 1)
    }

    private init(reducing numerator: Int128, _ denominator: Int128) {
        let sign: Int128 = denominator < 0 ? -1 : 1
        let divisor = Self.gcd(numerator.magnitude, denominator.magnitude)
        let n = sign * numerator / Int128(divisor)
        let d = sign * denominator / Int128(divisor)
        guard let n64 = Int64(exactly: n), let d64 = Int64(exactly: d) else {
            preconditionFailure("Rational-Überlauf: \(n)/\(d)")
        }
        self.numerator = n64
        self.denominator = d64
    }

    /// Wandelt Sekunden so um wie `Fraction(str(x))` in Python: über die kürzeste Dezimaldarstellung.
    /// Damit rundet die Swift-Kompilierung exakt wie 0.2.0.
    public init(seconds: Double) {
        precondition(seconds.isFinite, "Zeit muss endlich sein")
        guard let value = Rational(decimal: "\(seconds)") else {
            preconditionFailure("Nicht darstellbar: \(seconds)")
        }
        self = value
    }

    /// Liest eine Dezimalzahl wie `0.23`, `-1.5`, `1e-05` oder `1.2345e+16`.
    /// Sehr feine Nachkommastellen (über 18) werden auf 18 Stellen gerundet.
    public init?(decimal text: String) {
        var mantissa = Substring(text)
        var exponent = 0
        if let e = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let value = Int(mantissa[mantissa.index(after: e)...]) else { return nil }
            exponent = value
            mantissa = mantissa[..<e]
        }
        var negative = false
        if mantissa.first == "-" || mantissa.first == "+" {
            negative = mantissa.first == "-"
            mantissa = mantissa.dropFirst()
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !mantissa.isEmpty else { return nil }
        let whole = parts[0]
        let fraction = parts.count == 2 ? parts[1] : ""
        var digits = Array(whole + fraction)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return nil }
        var scale = fraction.count - exponent
        // Führende Nullen entfernen, damit die Ziffernfolge in Int128 passt.
        while digits.count > 1, digits.first == "0" { digits.removeFirst() }
        while scale > 18, digits.count > 1 {
            let last = digits.removeLast()
            scale -= 1
            if last >= "5" { digits = Self.incremented(digits) }
        }
        if scale > 18 {
            // Wert ist kleiner als 1e-18 und für Zeiten bedeutungslos.
            digits = ["0"]
            scale = 0
        }
        guard digits.count <= 36, let magnitude = Int128(String(digits)) else { return nil }
        var numerator = negative ? -magnitude : magnitude
        var denominator: Int128 = 1
        if scale >= 0 {
            denominator = Self.power10(scale)
        } else {
            guard -scale <= 18 else { return nil }
            numerator *= Self.power10(-scale)
        }
        let divisor = Int128(Self.gcd(numerator.magnitude, denominator.magnitude))
        guard Int64(exactly: numerator / divisor) != nil, Int64(exactly: denominator / divisor) != nil else {
            return nil
        }
        self.init(reducing: numerator, denominator)
    }

    /// `"24000/1001"` oder `"25"`.
    public init?(string: String) {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 1, let n = Int64(parts[0]) {
            self.init(n, 1)
        } else if parts.count == 2, let n = Int64(parts[0]), let d = Int64(parts[1]), d != 0 {
            self.init(n, d)
        } else {
            return nil
        }
    }

    public static let zero = Rational(0, 1)

    public var doubleValue: Double { Double(numerator) / Double(denominator) }

    public var description: String { denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)" }

    /// Rundet einmal und ab halb aufwärts: `floor(x + 1/2)`, auch für negative Werte (wie 0.2.0).
    public func roundedHalfUp() -> Int64 {
        let n = Int128(numerator) * 2 + Int128(denominator)
        let d = Int128(denominator) * 2
        var q = n / d
        if n % d != 0, n < 0 { q -= 1 }
        guard let result = Int64(exactly: q) else { preconditionFailure("Rundungsüberlauf") }
        return result
    }

    public static func + (a: Rational, b: Rational) -> Rational {
        Rational(
            reducing: Int128(a.numerator) * Int128(b.denominator) + Int128(b.numerator) * Int128(a.denominator),
            Int128(a.denominator) * Int128(b.denominator))
    }

    public static func - (a: Rational, b: Rational) -> Rational {
        a + Rational(reducing: -Int128(b.numerator), Int128(b.denominator))
    }

    public static func * (a: Rational, b: Rational) -> Rational {
        Rational(
            reducing: Int128(a.numerator) * Int128(b.numerator), Int128(a.denominator) * Int128(b.denominator))
    }

    public static func / (a: Rational, b: Rational) -> Rational {
        precondition(b.numerator != 0, "Division durch 0")
        return Rational(
            reducing: Int128(a.numerator) * Int128(b.denominator), Int128(a.denominator) * Int128(b.numerator))
    }

    public static func < (a: Rational, b: Rational) -> Bool {
        Int128(a.numerator) * Int128(b.denominator) < Int128(b.numerator) * Int128(a.denominator)
    }

    private static func gcd(_ a: UInt128, _ b: UInt128) -> UInt128 {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }

    private static func power10(_ exponent: Int) -> Int128 {
        (0..<exponent).reduce(Int128(1)) { value, _ in value * 10 }
    }

    private static func incremented(_ digits: [Character]) -> [Character] {
        var result = digits
        var index = result.count - 1
        while index >= 0 {
            if result[index] == "9" {
                result[index] = "0"
                index -= 1
            } else {
                result[index] = Character(String(result[index].wholeNumberValue! + 1))
                return result
            }
        }
        return ["1"] + result
    }
}

extension Rational: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard let value = Rational(string: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Ungültige Bruchzahl „\(text)“")
            }
            self = value
        } else {
            self.init(seconds: try container.decode(Double.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Zeitrechnung mit Bildraten. Jede Grenze wird genau einmal auf Frames gerundet.
public enum FrameMath {
    public static func frame(atSeconds seconds: Double, rate: Rational) -> Int64 {
        (Rational(seconds: seconds) * rate).roundedHalfUp()
    }

    public static func frame(at time: Rational, rate: Rational) -> Int64 {
        (time * rate).roundedHalfUp()
    }

    public static func seconds(ofFrames frames: Int64, rate: Rational) -> Rational {
        Rational(frames) / rate
    }
}
