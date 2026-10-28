import Foundation

/// Local wall time as plain integers, so moment, day and weekday rules need no `Calendar` in loops.
///
/// "Wall seconds" are UTC seconds plus the zone's offset at that instant: a photo taken at 21:00 in
/// Riyadh has wall seconds of 21:00 on that date counted as if it were UTC. A **moment day** runs
/// from 04:00 to 04:00 local time, so a party that goes on past midnight stays on its evening's day.
/// Day numbers count days since 1970-01-01 (negative before).
public enum LocalTime {
    /// The day breaks at 04:00 local time.
    public static let dayBreak: Int64 = 4 * 3600
    static let secondsPerDay: Int64 = 86_400

    /// UTC seconds (rounded down) plus `zone`'s offset at that instant.
    public static func wallSeconds(_ utc: Date, in zone: TimeZone) -> Int64 {
        Int64(utc.timeIntervalSince1970.rounded(.down)) + Int64(zone.secondsFromGMT(for: utc))
    }

    /// The moment day: the civil date whose 04:00 starts the 24 hours holding this wall time.
    public static func momentDay(wallSeconds: Int64) -> Int32 {
        Int32(floorDivide(wallSeconds - dayBreak, secondsPerDay))
    }

    /// Minutes since local midnight (0…1439).
    public static func minuteOfDay(wallSeconds: Int64) -> Int {
        Int(floorModulo(wallSeconds, secondsPerDay) / 60)
    }

    /// 1 = Sunday … 7 = Saturday (1970-01-01 was a Thursday).
    public static func weekday(day: Int32) -> Int {
        Int(floorModulo(Int64(day) + 4, 7)) + 1
    }

    /// The proleptic Gregorian date of a day number (Howard Hinnant's `civil_from_days`).
    public static func civil(day: Int32) -> (year: Int, month: Int, day: Int) {
        let z = Int64(day) + 719_468
        let era = floorDivide(z, 146_097)
        let dayOfEra = z - era * 146_097                                               // [0, 146096]
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365   // [0, 399]
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)   // [0, 365], from 1 March
        let shiftedMonth = (5 * dayOfYear + 2) / 153                                   // [0, 11], March = 0
        let dayOfMonth = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (Int(year), Int(month), Int(dayOfMonth))
    }

    /// The day number of a proleptic Gregorian date (Hinnant's `days_from_civil`).
    public static func day(year: Int, month: Int, day: Int) -> Int32 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = floorDivide(y, 400)
        let yearOfEra = y - era * 400
        let m = Int64(month)
        let dayOfYear = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int32(era * 146_097 + dayOfEra - 719_468)
    }

    /// The fixed-offset zone for a position no gazetteer record is near: `Etc/GMT∓n` with
    /// n = round(longitude / 15). Etc signs are inverted, so UTC+3 is `Etc/GMT-3`.
    public static func etcZoneIdentifier(longitude: Double) -> String {
        let hours = Int((longitude / 15).rounded())
        switch hours {
        case 0: return "Etc/GMT"
        case 1...: return "Etc/GMT-\(hours)"
        default: return "Etc/GMT+\(-hours)"
        }
    }

    static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }

    static func floorModulo(_ a: Int64, _ b: Int64) -> Int64 {
        a - floorDivide(a, b) * b
    }
}
