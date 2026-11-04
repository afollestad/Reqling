/// A JSON number split into its parts, so integer fields can tell `1e3` and `1000.0` (integral, accepted) from `1.5`
/// exactly, without rounding through `Double`. proto3 JSON accepts numbers in quoted strings too, with the same grammar.
struct ProtoJSONNumber {
    let isNegative: Bool
    /// The significant digits of integer and fraction parts, leading zeros stripped.
    private let digits: [UInt8]
    /// The power of ten `digits` is scaled by.
    private let exponent: Int

    /// The integer a number spells, if it spells one.
    enum Integer {
        case exact(isNegative: Bool, magnitude: UInt64)
        case fractional
        case outOfRange
    }

    /// Parses RFC 8259 number grammar: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`. Anything else, including the
    /// hex, `inf`, and `nan` spellings `Double(_:)` would accept, is `nil`.
    init?(_ text: String) {
        var bytes = Array(text.utf8)[...]
        isNegative = bytes.first == UInt8(ascii: "-")
        if isNegative {
            bytes = bytes.dropFirst()
        }
        let integerPart = bytes.prefix(while: Self.isDigit)
        bytes = bytes.dropFirst(integerPart.count)
        guard !integerPart.isEmpty, integerPart.count == 1 || integerPart.first != UInt8(ascii: "0") else {
            return nil
        }
        var fractionPart: ArraySlice<UInt8> = []
        if bytes.first == UInt8(ascii: ".") {
            fractionPart = bytes.dropFirst().prefix(while: Self.isDigit)
            guard !fractionPart.isEmpty else {
                return nil
            }
            bytes = bytes.dropFirst(fractionPart.count + 1)
        }
        var explicitExponent = 0
        if bytes.first == UInt8(ascii: "e") || bytes.first == UInt8(ascii: "E") {
            guard let parsed = Self.parseExponent(bytes.dropFirst()) else {
                return nil
            }
            explicitExponent = parsed
        } else if !bytes.isEmpty {
            return nil
        }
        var significant = Array(integerPart) + Array(fractionPart)
        let leadingZeros = significant.prefix { $0 == UInt8(ascii: "0") }.count
        significant.removeFirst(leadingZeros)
        digits = significant
        exponent = explicitExponent - fractionPart.count
    }

    var integer: Integer {
        var significant = digits[...]
        var scale = exponent
        while scale < 0, significant.last == UInt8(ascii: "0") {
            significant = significant.dropLast()
            scale += 1
        }
        guard !significant.isEmpty else {
            return .exact(isNegative: false, magnitude: 0)
        }
        guard scale >= 0 else {
            return .fractional
        }
        // UInt64.max has 20 digits.
        guard significant.count + scale <= 20 else {
            return .outOfRange
        }
        var magnitude: UInt64 = 0
        for digit in significant {
            let (shifted, overflowA) = magnitude.multipliedReportingOverflow(by: 10)
            let (sum, overflowB) = shifted.addingReportingOverflow(UInt64(digit - UInt8(ascii: "0")))
            guard !overflowA, !overflowB else {
                return .outOfRange
            }
            magnitude = sum
        }
        for _ in 0..<scale {
            let (shifted, overflow) = magnitude.multipliedReportingOverflow(by: 10)
            guard !overflow else {
                return .outOfRange
            }
            magnitude = shifted
        }
        return .exact(isNegative: isNegative, magnitude: magnitude)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// The signed exponent, clamped well past any representable scale so `1e999999999999` cannot overflow `Int`.
    private static func parseExponent(_ bytes: ArraySlice<UInt8>) -> Int? {
        var rest = bytes
        let isNegative = rest.first == UInt8(ascii: "-")
        if isNegative || rest.first == UInt8(ascii: "+") {
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty, rest.allSatisfy(isDigit) else {
            return nil
        }
        var value = 0
        for digit in rest {
            value = min(value * 10 + Int(digit - UInt8(ascii: "0")), 100_000)
        }
        return isNegative ? -value : value
    }
}
