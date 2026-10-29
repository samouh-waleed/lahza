import Foundation

/// The one way Lahza writes local dates: moment and trip titles, search chips, reasons and headers. Dates follow the
/// iPhone's region ("Sat, 22 Aug 2026" in the UK, "Sat, Aug 22, 2026" in the US), always in the Gregorian calendar,
/// so they agree with the year strip and the day numbers of ``LocalTime``. Interval formats put thin spaces
/// (U+2009) around their en dash.
public enum LocalDateFormat {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// A day number as its UTC midnight; formatted in UTC, it stays that day everywhere.
    private static func date(_ day: Int32) -> Date { Date(timeIntervalSince1970: TimeInterval(day) * 86_400) }

    private static func style(_ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: utcCalendar, timeZone: .gmt)
    }

    private static func intervalStyle(_ locale: Locale) -> Date.IntervalFormatStyle {
        Date.IntervalFormatStyle(locale: locale, calendar: utcCalendar, timeZone: .gmt)
    }

    /// "Sat, 22 Aug 2026" (UK), "Sat, Aug 22, 2026" (US).
    public static func dayTitle(_ day: Int32, locale: Locale = .autoupdatingCurrent) -> String {
        date(day).formatted(style(locale).weekday(.abbreviated).day().month(.abbreviated).year())
    }

    /// "Sat 22 Aug" (UK), "Sat, Aug 22" (US).
    public static func shortDay(_ day: Int32, locale: Locale = .autoupdatingCurrent) -> String {
        date(day).formatted(style(locale).weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Saturday, 22 August 2026", for VoiceOver.
    public static func spokenDay(_ day: Int32, locale: Locale = .autoupdatingCurrent) -> String {
        date(day).formatted(style(locale).weekday(.wide).day().month(.wide).year())
    }

    /// "22 Aug 2026" (UK), "Aug 22, 2026" (US).
    public static func day(_ day: Int32, locale: Locale = .autoupdatingCurrent) -> String {
        date(day).formatted(style(locale).day().month(.abbreviated).year())
    }

    /// "August 2026".
    public static func monthTitle(year: Int, month: Int, locale: Locale = .autoupdatingCurrent) -> String {
        date(LocalTime.day(year: year, month: month, day: 1)).formatted(style(locale).month(.wide).year())
    }

    /// "Aug 2026".
    public static func shortMonth(year: Int, month: Int, locale: Locale = .autoupdatingCurrent) -> String {
        date(LocalTime.day(year: year, month: month, day: 1)).formatted(style(locale).month(.abbreviated).year())
    }

    /// "2–8 Jul 2023" (UK), "Jul 2–8, 2023" (US); one date for a single day. Both days are included.
    public static func dayRange(_ first: Int32, _ last: Int32, locale: Locale = .autoupdatingCurrent) -> String {
        guard first < last else { return day(first, locale: locale) }
        return (date(first)..<date(last)).formatted(intervalStyle(locale).day().month(.abbreviated).year())
    }

    /// "Jun – Aug 2026", "Dec 2025 – Feb 2026"; one month for a single month. Both months are included.
    public static func monthRange(from first: (year: Int, month: Int), to last: (year: Int, month: Int),
                                  locale: Locale = .autoupdatingCurrent) -> String {
        let start = LocalTime.day(year: first.year, month: first.month, day: 1)
        let end = LocalTime.day(year: last.year, month: last.month, day: 1)
        guard start < end else { return shortMonth(year: first.year, month: first.month, locale: locale) }
        return (date(start)..<date(end)).formatted(intervalStyle(locale).month(.abbreviated).year())
    }

    /// "June": a month's name in the region's language.
    public static func monthName(_ month: Int, locale: Locale = .autoupdatingCurrent) -> String {
        date(LocalTime.day(year: 2001, month: min(max(1, month), 12), day: 1)).formatted(style(locale).month(.wide))
    }

    /// "Saturday" (1 Sunday … 7 Saturday).
    public static func weekdayName(_ weekday: Int, locale: Locale = .autoupdatingCurrent) -> String {
        // 7 January 2001 was a Sunday.
        date(LocalTime.day(year: 2001, month: 1, day: 6 + min(max(1, weekday), 7))).formatted(style(locale).weekday(.wide))
    }

    /// Whether the region writes the month before the day ("June 14", US) rather than after it ("14 June", UK).
    public static func monthComesFirst(_ locale: Locale = .autoupdatingCurrent) -> Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "dMMMM", options: 0, locale: locale) ?? "d MMMM"
        guard let month = pattern.firstIndex(of: "M"), let day = pattern.firstIndex(of: "d") else { return false }
        return month < day
    }

    /// Whether numeric dates put the month first ("3/14/2024", US) rather than the day ("14/03/2024", UK).
    public static func numericMonthComesFirst(_ locale: Locale = .autoupdatingCurrent) -> Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? "d/M/y"
        guard let month = pattern.firstIndex(of: "M"), let day = pattern.firstIndex(of: "d") else { return false }
        return month < day
    }
}
