import Foundation

/// JavaScript `Date` semantics: integer millisecond time values, `toISOString()` and
/// `Date.parse` for the ISO forms.
public enum JSDate {
    /// Largest magnitude of a valid JS time value (±100,000,000 days).
    public static let maxTimeValue: Int64 = 8_640_000_000_000_000
    static let msPerDay: Int64 = 86_400_000
    /// Milliseconds from 1970-01-01 to Foundation's 2001-01-01 reference date.
    static let referenceDateOffset: Int64 = 978_307_200_000

    // MARK: Time values

    /// ECMAScript `TimeClip`: nil (NaN) unless finite and within ±8.64e15, else truncated toward zero.
    public static func timeClip(_ milliseconds: Double) -> Int64? {
        guard milliseconds.isFinite, milliseconds.magnitude <= Double(maxTimeValue) else { return nil }
        return Int64(milliseconds.rounded(.towardZero))
    }

    /// The JS time value (`date.getTime()`) of a Foundation `Date`.
    ///
    /// A `Date` built from JS milliseconds round-trips exactly. Sub-millisecond instants floor to
    /// their millisecond, like `Date.now()`. Values beyond the JS range are clamped to ±8.64e15.
    public static func milliseconds(from date: Date) -> Int64 {
        let interval = date.timeIntervalSinceReferenceDate
        guard !interval.isNaN else { return 0 }
        let limit = Double(maxTimeValue + referenceDateOffset) / 1000 + 1
        guard interval.magnitude < limit else { return interval < 0 ? -maxTimeValue : maxTimeValue }
        let whole = interval.rounded(.down)
        let fraction = (interval - whole) * 1000
        let nearest = fraction.rounded()
        // A Date made from whole milliseconds lands within a few ulps of the boundary; snap those.
        let tolerance = max(1e-4, interval.ulp * 1000)
        let millis = (fraction - nearest).magnitude <= tolerance ? nearest : fraction.rounded(.down)
        let value = Int64(whole) * 1000 + Int64(millis) + referenceDateOffset
        return min(max(value, -maxTimeValue), maxTimeValue)
    }

    /// The `Date` for a JS time value.
    public static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(milliseconds - referenceDateOffset) / 1000)
    }

    // MARK: toISOString

    /// `new Date(ms).toISOString()`: `YYYY-MM-DDTHH:mm:ss.sssZ`, with `±YYYYYY` years outside
    /// 0…9999. Nil where JS throws `RangeError` (beyond ±8.64e15).
    public static func isoString(milliseconds: Int64) -> String? {
        guard milliseconds.magnitude <= UInt64(maxTimeValue) else { return nil }
        return format(milliseconds)
    }

    /// `date.toISOString()`. Dates beyond the JS range are clamped to it (JS would throw).
    public static func isoString(_ date: Date) -> String {
        format(milliseconds(from: date))
    }

    private static func format(_ milliseconds: Int64) -> String {
        let days = floorDiv(milliseconds, msPerDay)
        let msOfDay = milliseconds - days * msPerDay
        let (year, month, day) = civil(fromDays: days)
        var out = ""
        out.reserveCapacity(27)
        if (0...9999).contains(year) {
            out += pad(year, 4)
        } else {
            out += year < 0 ? "-" : "+"
            out += pad(year.magnitude, 6)
        }
        out += "-" + pad(month, 2) + "-" + pad(day, 2)
        out += "T" + pad(msOfDay / 3_600_000, 2)
        out += ":" + pad(msOfDay / 60_000 % 60, 2)
        out += ":" + pad(msOfDay / 1000 % 60, 2)
        out += "." + pad(msOfDay % 1000, 3) + "Z"
        return out
    }

    private static func pad<T: BinaryInteger>(_ value: T, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    // MARK: Date.parse (ISO forms)

    /// `Date.parse(text)` for the ECMAScript date-time string format as V8 reads it; nil means NaN.
    ///
    /// Accepted: `YYYY`, `YYYY-MM`, `YYYY-MM-DD` (or `±YYYYYY…`, never `-000000`), optionally
    /// followed by `T`/`t`/space and `HH:mm`, `HH:mm:ss` or `HH:mm:ss.f…`, then `Z`/`z`, `±HH:mm` or
    /// `±HHmm`; or a date followed directly by `Z`/`z`. Day 1–31 is accepted for every month and
    /// rolls over (`2024-02-30` is 1 March), as in V8.
    /// A date alone (or with `Z`) is UTC; a date-time without an offset is local time in
    /// `timeZone`, with skipped and repeated local times resolved with the offset in force
    /// before the transition (as V8 does).
    ///
    /// V8 details reproduced exactly:
    /// - Fractional seconds follow V8's `ReadMilliseconds`: leading zeros are skipped, at most 9
    ///   significant digits are read, and the value is scaled by the total digit count capped at 9.
    ///   So `.0191535216` is 191 ms in V8 (and here), not 19.
    /// - `24:00` is allowed only as exactly midnight. After `T`, any non-zero fraction digit rejects
    ///   it; after a space, only a fraction of at least 1 ms does (`24:00:00.0001` is accepted).
    /// - A space separator and a date followed directly by `Z` are not ES date-time forms: V8 hands
    ///   them to its legacy parser, which reads the date fields as `[a, b, c]` and, when `a` is
    ///   1–31, as month `a`, day `b`, year `c`, and then maps years 0–49 to 2000–2049 and 50–99 to
    ///   1950–1999. So `0009-04-03Z` is 2003-09-04 and `0023-05-17z` is NaN, as in V8. Years of
    ///   100 and above are unaffected.
    ///
    /// Not supported: other V8 legacy formats (`2024-1-2`, `Jan 2 2024`, `2024-01-02 03:04-05`,
    /// leading spaces…), which return nil here.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Int64? {
        var scanner = ISOScanner(Array(text.utf8))
        return scanner.parse(timeZone: timeZone)
    }

    /// ``parse(_:timeZone:)`` as a `Date`.
    public static func parseDate(_ text: String, timeZone: TimeZone = .current) -> Date? {
        parse(text, timeZone: timeZone).map(date(milliseconds:))
    }

    /// A strict UTC instant, `YYYY-MM-DDTHH:mm:ss[.s{1,3}]Z`, that also passes `Date.parse`.
    public static func isBackendInstant(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let shape: [UInt8] = Array("dddd-dd-ddTdd:dd:dd".utf8)
        guard bytes.count >= shape.count + 1, bytes.last == UInt8(ascii: "Z") else { return false }
        for (index, expected) in shape.enumerated() {
            let byte = bytes[index]
            if expected == UInt8(ascii: "d") {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return false }
            } else if byte != expected {
                return false
            }
        }
        let tail = bytes[shape.count..<(bytes.count - 1)]
        if !tail.isEmpty {
            guard tail.first == UInt8(ascii: "."), (2...4).contains(tail.count),
                  tail.dropFirst().allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return false }
        }
        return parse(text, timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt) != nil
    }

    // MARK: Calendar arithmetic (proleptic Gregorian, year 0 exists)

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }

    /// Days since 1970-01-01 for a civil date; days past the month's end roll over (`MakeDay`).
    static func days(fromCivilYear year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civil(fromDays days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// UTC time value for a local wall-clock time value in `zone` (ES `UTC(t)`): for skipped or
    /// repeated local times, the offset before the transition wins.
    static func utc(fromLocal local: Int64, in zone: TimeZone) -> Int64 {
        func offset(_ utc: Int64) -> Int64 { Int64(zone.secondsFromGMT(for: date(milliseconds: utc))) * 1000 }
        let before = offset(local - msPerDay)
        let candidate = local - before
        if offset(candidate) == before { return candidate }
        let after = offset(local + msPerDay)
        let alternative = local - after
        if offset(alternative) == after { return alternative }
        return candidate
    }
}

private struct ISOScanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func digits(_ count: Int) -> Int64? {
        guard index + count <= bytes.count else { return nil }
        var value: Int64 = 0
        for offset in 0..<count {
            let byte = bytes[index + offset]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int64(byte - UInt8(ascii: "0"))
        }
        index += count
        return value
    }

    private mutating func consume(_ ascii: Unicode.Scalar) -> Bool {
        guard current == UInt8(ascii: ascii) else { return false }
        index += 1
        return true
    }

    mutating func parse(timeZone: TimeZone) -> Int64? {
        // Year.
        var year: Int64
        if let sign = current, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
            index += 1
            guard let magnitude = digits(6) else { return nil }
            if sign == UInt8(ascii: "-") && magnitude == 0 { return nil }
            year = sign == UInt8(ascii: "-") ? -magnitude : magnitude
        } else {
            guard let plain = digits(4) else { return nil }
            year = plain
        }
        // Month and day.
        var month: Int64 = 1
        var day: Int64 = 1
        if consume("-") {
            guard let m = digits(2), (1...12).contains(m) else { return nil }
            month = m
            if consume("-") {
                guard let d = digits(2), (1...31).contains(d) else { return nil }
                day = d
            }
        }
        // Time. A space separator is V8's legacy parser; `T`/`t` is the ES format.
        var hasTime = false
        var legacy = false
        var hour: Int64 = 0, minute: Int64 = 0, second: Int64 = 0, millisecond: Int64 = 0
        var fractionIsNonZero = false
        if let separator = current, separator == UInt8(ascii: "T") || separator == UInt8(ascii: "t") || separator == UInt8(ascii: " ") {
            legacy = separator == UInt8(ascii: " ")
            index += 1
            guard let h = digits(2), (0...24).contains(h), consume(":"), let m = digits(2), (0...59).contains(m) else { return nil }
            hour = h
            minute = m
            if consume(":") {
                guard let s = digits(2), (0...59).contains(s) else { return nil }
                second = s
                if consume(".") {
                    guard let fraction = readMilliseconds() else { return nil }
                    millisecond = fraction.milliseconds
                    fractionIsNonZero = fraction.isNonZero
                }
            }
            if hour == 24 {
                // ES path: V8 rejects any non-zero numeral after 24; legacy checks the result.
                let fractionRejects = legacy ? millisecond != 0 : fractionIsNonZero
                if minute != 0 || second != 0 || fractionRejects { return nil }
            }
            hasTime = true
        }
        // Zone designator.
        var offset: Int64?
        if let byte = current {
            if byte == UInt8(ascii: "Z") || byte == UInt8(ascii: "z") {
                index += 1
                offset = 0
                if !hasTime { legacy = true }
            } else if hasTime, byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") {
                index += 1
                guard let h = digits(2), (0...23).contains(h) else { return nil }
                _ = consume(":")
                guard let m = digits(2), (0...59).contains(m) else { return nil }
                offset = (byte == UInt8(ascii: "-") ? -1 : 1) * (h * 60 + m) * 60_000
            } else {
                return nil
            }
        }
        guard index == bytes.count else { return nil }

        if legacy {
            // V8 `DayComposer::Write` without `is_iso_date_`: fields [year, month, day].
            if (1...31).contains(year) {
                guard (1...12).contains(year) else { return nil }
                (year, month, day) = (day, year, month)
            }
            if (0...49).contains(year) {
                year += 2000
            } else if (50...99).contains(year) {
                year += 1900
            }
        }

        let local = JSDate.days(fromCivilYear: year, month: month, day: day) * JSDate.msPerDay
            + ((hour * 60 + minute) * 60 + second) * 1000 + millisecond
        let utc: Int64
        if let offset {
            utc = local - offset
        } else if hasTime {
            utc = JSDate.utc(fromLocal: local, in: timeZone)
        } else {
            utc = local
        }
        guard utc.magnitude <= UInt64(JSDate.maxTimeValue) else { return nil }
        return utc
    }

    /// V8's `ReadUnsignedNumeral` + `ReadMilliseconds` for the digits after the `.`: leading
    /// zeros are skipped, up to 9 significant digits are kept, and the numeral is scaled to
    /// milliseconds by its total length (capped at 9). Nil when there are no digits.
    private mutating func readMilliseconds() -> (milliseconds: Int64, isNonZero: Bool)? {
        let start = index
        while current == UInt8(ascii: "0") { index += 1 }
        var numeral: Int64 = 0
        var significant = 0
        while let byte = current, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            if significant < 9 { numeral = numeral * 10 + Int64(byte - UInt8(ascii: "0")) }
            significant += 1
            index += 1
        }
        var length = index - start
        guard length > 0 else { return nil }
        var milliseconds = numeral
        switch length {
        case 1: milliseconds *= 100
        case 2: milliseconds *= 10
        case 3: break
        default:
            length = min(length, 9)
            var factor: Int64 = 1
            while length > 3 {
                factor *= 10
                length -= 1
            }
            milliseconds /= factor
        }
        return (milliseconds, numeral > 0)
    }
}

extension Date {
    /// The `Date` for a JS time value (`new Date(ms)`).
    public init(jsMilliseconds: Int64) {
        self = JSDate.date(milliseconds: jsMilliseconds)
    }

    /// The JS time value (`getTime()`); see ``JSDate/milliseconds(from:)``.
    public var jsMilliseconds: Int64 { JSDate.milliseconds(from: self) }

    /// `toISOString()`, e.g. `2026-09-24T08:30:00.000Z`.
    public var jsISOString: String { JSDate.isoString(self) }
}
