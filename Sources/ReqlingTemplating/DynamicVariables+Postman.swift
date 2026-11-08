import Foundation

/// Postman's random built-ins that need no word lists, each in the shape Postman writes it.
extension DynamicVariables {
    static let postmanGenerators: [Generator] = [
        Generator("$randomAlphaNumeric") { $0.characters(1, from: lowercaseAlphanumerics) },
        Generator("$randomBoolean") { $0.random(0..<2) == 1 ? "true" : "false" },
        Generator("$randomPassword") { $0.characters(15, from: alphanumerics) },
        Generator("$randomHexColor") { "#" + $0.hex(digits: 6) },
        Generator("$randomIP") { variables in (0..<4).map { _ in String(variables.random(0..<256)) }.joined(separator: ".") },
        Generator("$randomIPV6") { variables in (0..<8).map { _ in variables.hex(digits: 4) }.joined(separator: ":") },
        Generator("$randomMACAddress") { variables in (0..<6).map { _ in variables.hex(digits: 2) }.joined(separator: ":") },
        Generator("$randomSemver") { variables in (0..<3).map { _ in String(variables.random(0..<10)) }.joined(separator: ".") },
        Generator("$randomLatitude") { $0.decimal(in: -90...90, places: 4) },
        Generator("$randomLongitude") { $0.decimal(in: -180...180, places: 4) },
        Generator("$randomPrice") { $0.decimal(in: 1...1000, places: 2) },
        Generator("$randomDateFuture") { $0.javaScriptDate(offsetBy: $0.seconds(upTo: secondsPerYear)) },
        Generator("$randomDatePast") { $0.javaScriptDate(offsetBy: -$0.seconds(upTo: secondsPerYear)) },
        Generator("$randomDateRecent") { $0.javaScriptDate(offsetBy: -$0.seconds(upTo: secondsPerDay)) }
    ]

    private static let lowercaseAlphanumerics = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    private static let alphanumerics = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    private static let hexDigits = Array("0123456789abcdef")
    private static let secondsPerDay = 86_400
    private static let secondsPerYear = 365 * secondsPerDay

    func characters(_ count: Int, from alphabet: [Character]) -> String {
        String((0..<count).map { _ in alphabet[random(0..<alphabet.count)] })
    }

    /// Lowercase hex, as Postman writes colors and addresses.
    func hex(digits: Int) -> String {
        characters(digits, from: Self.hexDigits)
    }

    /// A number in `range` with exactly `places` decimals, chosen in steps of the last place, so every value is equally
    /// likely and none has a float's rounding error.
    func decimal(in range: ClosedRange<Int>, places: Int) -> String {
        let scale = Int(pow(10, Double(places)))
        let steps = random((range.lowerBound * scale)..<(range.upperBound * scale + 1))
        let sign = steps < 0 ? "-" : ""
        let whole = abs(steps) / scale
        let fraction = String(abs(steps) % scale)
        return "\(sign)\(whole).\(String(repeating: "0", count: places - fraction.count))\(fraction)"
    }

    func seconds(upTo limit: Int) -> TimeInterval {
        TimeInterval(random(1..<(limit + 1)))
    }

    /// `now` moved by `offset`, written as JavaScript's `Date.toString()` writes a date, which is what Postman's
    /// `$randomDate…` built-ins give: `Tue Mar 17 2026 13:11:50 GMT+0530 (India Standard Time)`.
    func javaScriptDate(offsetBy offset: TimeInterval) -> String {
        let formatter = DateFormatter()
        // English names whatever the Mac's language, as JavaScript writes them.
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT'xx '('zzzz')'"
        return formatter.string(from: now().addingTimeInterval(offset))
    }
}
