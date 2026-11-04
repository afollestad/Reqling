/// The JSON forms of `Timestamp` (RFC 3339) and `Duration` (`"1.5s"`). Hand-rolled rather than built on
/// `ISO8601DateFormatter`, which neither keeps nanoseconds nor spans protobuf's full year range of 1 through 9999.
enum ProtoTime {
    /// `0001-01-01T00:00:00Z` and `9999-12-31T23:59:59Z`, the range `timestamp.proto` allows.
    static let timestampSeconds: ClosedRange<Int64> = -62_135_596_800...253_402_300_799
    /// About 10,000 years either way, the range `duration.proto` allows.
    static let maxDurationSeconds: Int64 = 315_576_000_000
    private static let secondsPerDay: Int64 = 86_400
    private static let nanosPerSecond: Int32 = 1_000_000_000

    struct Instant: Equatable {
        let seconds: Int64
        let nanos: Int32
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`, with up to nine fractional digits; an offset is folded into UTC.
    static func parseTimestamp(_ text: String) throws(GRPCCodecError) -> Instant {
        let failure = GRPCCodecError("`\(text)` is not an RFC 3339 timestamp such as 1970-01-01T00:00:00Z")
        let bytes = Array(text.utf8)
        guard bytes.count >= 20, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = number(bytes, 0..<4), let month = number(bytes, 5..<7), let day = number(bytes, 8..<10),
              let hour = number(bytes, 11..<13), let minute = number(bytes, 14..<16), let second = number(bytes, 17..<19),
              (1...12).contains(month), (1...daysInMonth(month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60, year > 0
        else {
            throw failure
        }
        var index = 19
        let nanos = try fraction(bytes, at: &index, failure: failure)
        guard let offset = utcOffset(bytes[index...]) else {
            throw failure
        }
        let days = Int64(daysFromCivil(year: year, month: month, day: day))
        let seconds = days * secondsPerDay + Int64(hour * 3600 + minute * 60 + second) - Int64(offset)
        guard timestampSeconds.contains(seconds) else {
            throw GRPCCodecError("`\(text)` is outside the timestamp range of years 1 through 9999")
        }
        return Instant(seconds: seconds, nanos: nanos)
    }

    /// UTC with `Z`, and 0, 3, 6, or 9 fractional digits as precision requires, as protobuf writes it.
    static func formatTimestamp(_ instant: Instant) throws(GRPCCodecError) -> String {
        guard timestampSeconds.contains(instant.seconds), (0..<nanosPerSecond).contains(instant.nanos) else {
            throw GRPCCodecError("Timestamp \(instant.seconds)s \(instant.nanos)ns is outside the valid range")
        }
        let days = floorDivide(instant.seconds, secondsPerDay)
        let secondOfDay = Int(instant.seconds - days * secondsPerDay)
        let date = civilFromDays(Int(days))
        let datePart = "\(pad(date.year, 4))-\(pad(date.month, 2))-\(pad(date.day, 2))"
        let timePart = "\(pad(secondOfDay / 3600, 2)):\(pad(secondOfDay / 60 % 60, 2)):\(pad(secondOfDay % 60, 2))"
        return "\(datePart)T\(timePart)\(fractionText(instant.nanos))Z"
    }

    /// Seconds with up to nine fractional digits and an `s` suffix, such as `-1.5s`; `nanos` takes the sign too.
    static func parseDuration(_ text: String) throws(GRPCCodecError) -> Instant {
        let failure = GRPCCodecError("`\(text)` is not a duration such as 1.5s")
        var bytes = Array(text.utf8)
        guard bytes.last == UInt8(ascii: "s") else {
            throw failure
        }
        bytes.removeLast()
        let isNegative = bytes.first == UInt8(ascii: "-")
        let start = isNegative ? 1 : 0
        var index = start
        while index < bytes.count, isDigit(bytes[index]) {
            index += 1
        }
        guard index > start, let whole = number(bytes, start..<index) else {
            throw failure
        }
        let nanos = try fraction(bytes, at: &index, failure: failure)
        guard index == bytes.count else {
            throw failure
        }
        guard Int64(whole) <= maxDurationSeconds else {
            throw GRPCCodecError("`\(text)` is outside the duration range of ±\(maxDurationSeconds)s")
        }
        let seconds = Int64(whole)
        return isNegative ? Instant(seconds: -seconds, nanos: -nanos) : Instant(seconds: seconds, nanos: nanos)
    }

    static func formatDuration(_ duration: Instant) throws(GRPCCodecError) -> String {
        let signsAgree = (duration.seconds >= 0 && duration.nanos >= 0) || (duration.seconds <= 0 && duration.nanos <= 0)
        guard duration.seconds.magnitude <= UInt64(maxDurationSeconds), duration.nanos.magnitude < nanosPerSecond.magnitude,
              signsAgree
        else {
            throw GRPCCodecError("Duration \(duration.seconds)s \(duration.nanos)ns is outside the valid range")
        }
        let sign = duration.seconds < 0 || duration.nanos < 0 ? "-" : ""
        return "\(sign)\(duration.seconds.magnitude)\(fractionText(Int32(duration.nanos.magnitude)))s"
    }

    /// An optional `.` and one to nine digits at `index`, as nanoseconds.
    private static func fraction(
        _ bytes: [UInt8],
        at index: inout Int,
        failure: GRPCCodecError
    ) throws(GRPCCodecError) -> Int32 {
        guard index < bytes.count, bytes[index] == UInt8(ascii: ".") else {
            return 0
        }
        index += 1
        let start = index
        while index < bytes.count, isDigit(bytes[index]) {
            index += 1
        }
        let count = index - start
        guard (1...9).contains(count), let digits = number(bytes, start..<index) else {
            throw failure
        }
        var scale = 1
        for _ in count..<9 {
            scale *= 10
        }
        return Int32(digits * scale)
    }

    private static func fractionText(_ nanos: Int32) -> String {
        if nanos == 0 {
            return ""
        }
        if nanos % 1_000_000 == 0 {
            return "." + pad(Int(nanos / 1_000_000), 3)
        }
        if nanos % 1000 == 0 {
            return "." + pad(Int(nanos / 1000), 6)
        }
        return "." + pad(Int(nanos), 9)
    }

    /// `Z` or `±HH:MM` as seconds east of UTC, or `nil` for anything else, including RFC 3339's lowercase `z`, which
    /// protobuf rejects.
    private static func utcOffset(_ bytes: ArraySlice<UInt8>) -> Int? {
        let suffix = Array(bytes)
        if suffix == [UInt8(ascii: "Z")] {
            return 0
        }
        guard suffix.count == 6, suffix[0] == UInt8(ascii: "+") || suffix[0] == UInt8(ascii: "-"),
              suffix[3] == UInt8(ascii: ":"), let hours = number(suffix, 1..<3), let minutes = number(suffix, 4..<6),
              hours < 24, minutes < 60
        else {
            return nil
        }
        let offset = hours * 3600 + minutes * 60
        return suffix[0] == UInt8(ascii: "-") ? -offset : offset
    }

    /// The decimal digits in `range`, or `nil` for a non-digit or a value past `Int.max`.
    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        guard range.upperBound <= bytes.count else {
            return nil
        }
        var value = 0
        for byte in bytes[range] {
            guard isDigit(byte) else {
                return nil
            }
            let (shifted, overflowA) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflowB) = shifted.addingReportingOverflow(Int(byte - UInt8(ascii: "0")))
            guard !overflowA, !overflowB else {
                return nil
            }
            value = sum
        }
        return value
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func floorDivide(_ dividend: Int64, _ divisor: Int64) -> Int64 {
        let quotient = dividend / divisor
        return dividend % divisor < 0 ? quotient - 1 : quotient
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11:
            30
        default:
            31
        }
    }

    private struct CivilDate {
        let year: Int
        let month: Int
        let day: Int
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's `days_from_civil`).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The inverse of `daysFromCivil` (Howard Hinnant's `civil_from_days`).
    private static func civilFromDays(_ days: Int) -> CivilDate {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return CivilDate(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }
}
