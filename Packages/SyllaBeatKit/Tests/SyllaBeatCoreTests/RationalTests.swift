import Foundation
import Testing

@testable import SyllaBeatCore

@Suite struct RationalTests {
    @Test(arguments: [
        ("0.23", 23, 100), ("100.0", 100, 1), ("-1.5", -3, 2), ("1e-05", 1, 100_000), ("2.5e+3", 2500, 1),
        ("6.006", 3003, 500), ("0", 0, 1), ("12.400000000000002", 6_200_000_000_000_001, 500_000_000_000_000),
    ])
    func parsesDecimals(text: String, numerator: Int64, denominator: Int64) throws {
        let value = try #require(Rational(decimal: text))
        #expect(value == Rational(numerator, denominator))
    }

    /// Entspricht `Fraction(str(x))` in Python: kürzeste Dezimaldarstellung, nicht der binäre Wert.
    @Test func secondsUseShortestDecimal() {
        #expect(Rational(seconds: 0.1) == Rational(1, 10))
        #expect(Rational(seconds: 0.1 + 0.2) == Rational(7_500_000_000_000_001, 25_000_000_000_000_000))
        #expect(Rational(seconds: 8.73) == Rational(873, 100))
    }

    @Test func roundsHalfUpOnce() {
        #expect(Rational(1, 2).roundedHalfUp() == 1)
        #expect(Rational(3, 2).roundedHalfUp() == 2)
        #expect(Rational(5, 2).roundedHalfUp() == 3)
        #expect(Rational(-1, 2).roundedHalfUp() == 0)
        #expect(Rational(-3, 2).roundedHalfUp() == -1)
        #expect(Rational(49, 100).roundedHalfUp() == 0)
    }

    @Test func framesAtNTSCRates() {
        let ntsc = Rational(24000, 1001)
        #expect(FrameMath.frame(atSeconds: 1, rate: ntsc) == 24)
        #expect(FrameMath.frame(atSeconds: 60, rate: ntsc) == 1439)
        #expect(FrameMath.frame(atSeconds: 0.020_854_166, rate: Rational(48)) == 1)
        #expect(FrameMath.seconds(ofFrames: 1001, rate: Rational(30000, 1001)) == Rational(1001 * 1001, 30000))
    }

    @Test func arithmeticStaysReduced() {
        let sum = Rational(1, 6) + Rational(1, 3)
        #expect(sum.numerator == 1 && sum.denominator == 2)
        #expect(Rational(2, -4) == Rational(-1, 2))
        #expect(Rational(3, 4) - Rational(1, 4) == Rational(1, 2))
        #expect(Rational(3, 4) / Rational(3, 2) == Rational(1, 2))
        #expect(Rational(1, 3) < Rational(1, 2))
    }

    /// Große Zähler aus 17-stelligen Dezimalzahlen mal NTSC-Rate dürfen nicht überlaufen.
    @Test func largeIntermediateValues() {
        let time = Rational(seconds: 123.456_789_012_345_67)
        let frame = FrameMath.frame(at: time, rate: Rational(30000, 1001))
        #expect(frame == 3700)
    }

    @Test func codableAsText() throws {
        let data = try JSONEncoder().encode(["fps": Rational(24000, 1001), "whole": Rational(25)])
        #expect(String(decoding: data, as: UTF8.self).contains("\"24000\\/1001\""))
        let decoded = try JSONDecoder().decode([String: Rational].self, from: data)
        #expect(decoded["fps"] == Rational(24000, 1001))
        #expect(decoded["whole"] == Rational(25))
        let number = try JSONDecoder().decode([Rational].self, from: Data("[1.25]".utf8))
        #expect(number == [Rational(5, 4)])
        #expect(Rational(string: "1/0") == nil)
        #expect(Rational(string: "abc") == nil)
    }
}
