import Foundation
import LZGeo

/// Hijri events on the Umm al-Qura calendar, as day numbers (``LocalTime``). The only place search uses `Calendar`
/// for dates.
enum HijriCalendar {
    /// One occurrence of an event: its Hijri year and its first and last days (inclusive).
    struct Occurrence: Sendable, Hashable {
        var event: HijriEvent
        var hijriYear: Int
        var first: Int32
        var last: Int32

        /// The Islamic day starts at sunset: 18:00 local on the eve, to the 04:00 day break after the last day (S17).
        var wallRange: Range<Int64> {
            (Int64(first) - 1) * 86_400 + 18 * 3_600..<(Int64(last) + 1) * 86_400 + LocalTime.dayBreak
        }
    }

    /// The years Umm al-Qura covers.
    static let supportedYears = 1300...1600

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// The day number of a Hijri date (nil outside the calendar's range).
    static func day(hijriYear: Int, month: Int, day: Int) -> Int32? {
        guard supportedYears.contains(hijriYear),
              let date = calendar.date(from: DateComponents(year: hijriYear, month: month, day: day)) else { return nil }
        return Int32((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// The occurrences of `event` in Hijri year `hijriYear` (two for "Eid": al-Fitr, then al-Adha).
    static func occurrences(_ event: HijriEvent, hijriYear: Int) -> [Occurrence] {
        switch event {
        case .ramadan:
            guard let first = day(hijriYear: hijriYear, month: 9, day: 1), let next = day(hijriYear: hijriYear, month: 10, day: 1) else { return [] }
            return [Occurrence(event: .ramadan, hijriYear: hijriYear, first: first, last: next - 1)]
        case .eidAlFitr:
            guard let first = day(hijriYear: hijriYear, month: 10, day: 1) else { return [] }
            return [Occurrence(event: .eidAlFitr, hijriYear: hijriYear, first: first, last: first + 2)]
        case .eidAlAdha:
            guard let first = day(hijriYear: hijriYear, month: 12, day: 10) else { return [] }
            return [Occurrence(event: .eidAlAdha, hijriYear: hijriYear, first: first, last: first + 3)]
        case .hajj:
            guard let first = day(hijriYear: hijriYear, month: 12, day: 8) else { return [] }
            return [Occurrence(event: .hajj, hijriYear: hijriYear, first: first, last: first + 5)]
        case .eid:
            return occurrences(.eidAlFitr, hijriYear: hijriYear) + occurrences(.eidAlAdha, hijriYear: hijriYear)
        }
    }

    /// Every occurrence of `event` that starts in one of these Gregorian years, oldest first.
    static func occurrences(_ event: HijriEvent, startingIn years: ClosedRange<Int>) -> [Occurrence] {
        // A Hijri year is about 354 days: 33 of them per 32 Gregorian years, counted from 622.
        let low = Int((Double(years.lowerBound - 622) * 33 / 32).rounded(.down)) - 1
        let high = Int((Double(years.upperBound - 622) * 33 / 32).rounded(.up)) + 1
        let first = LocalTime.day(year: years.lowerBound, month: 1, day: 1), last = LocalTime.day(year: years.upperBound + 1, month: 1, day: 1)
        return (max(low, supportedYears.lowerBound)...min(high, supportedYears.upperBound))
            .flatMap { occurrences(event, hijriYear: $0) }
            .filter { $0.first >= first && $0.first < last }
            .sorted { $0.first < $1.first }
    }
}
