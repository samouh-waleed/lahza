import Foundation
import LZGeo

/// Turns time expressions into a ``TimeConstraint`` (search spec §6.4): pure integer civil math on day numbers and
/// wall seconds, with `Calendar` only for the Hijri calendar and region facts. A day runs from 04:00 to 04:00 local
/// time, so "Saturday" and "1 Jun" keep the small hours after their evening.
public struct TimeResolver: Sendable {
    public var context: TimeContext

    public static let day: Int64 = 86_400
    public static let threeDays: Int64 = 3 * 86_400

    public init(context: TimeContext) {
        self.context = context
    }

    /// The constraint every expression must hold (they come from separate time slots of one query).
    public func resolve(_ expressions: [TimeExpression]) -> TimeResolution {
        guard !expressions.isEmpty else { return .constraint(TimeConstraint(label: "")) }
        return resolve(expressions.count == 1 ? expressions[0] : .all(expressions))
    }

    public func resolve(_ expression: TimeExpression) -> TimeResolution {
        let part = resolvePart(expression)
        if let unsupported = part.unsupported { return .unsupported(unsupported) }
        let finite = (part.ranges ?? []).filter { $0.lowerBound > Self.openStart && $0.upperBound < Self.openEnd }
        let longest = finite.map { $0.upperBound - $0.lowerBound }.max() ?? 0
        let tau = part.hijri ? Self.day : max(longest / 10, Self.threeDays)
        let tomorrow = Self.start(today + 1)
        let isFuture = part.ranges.map { !$0.isEmpty && $0.allSatisfy { $0.lowerBound >= tomorrow } } ?? false
        return .constraint(TimeConstraint(ranges: part.ranges, weekdays: part.weekdays, minuteWindows: part.windows, months: part.months,
                                          tau: tau, label: label(expression), isFuture: isFuture))
    }

    // MARK: Now

    /// Today's moment day in the home zone.
    var today: Int32 { LocalTime.momentDay(wallSeconds: LocalTime.wallSeconds(context.now, in: context.zone)) }

    var todayDate: (year: Int, month: Int, day: Int) { LocalTime.civil(day: today) }

    /// The wall second a moment day starts at (04:00).
    static func start(_ day: Int32) -> Int64 { Int64(day) * Self.day + LocalTime.dayBreak }

    /// Days `first...last` as wall seconds, 04:00 to 04:00.
    static func days(_ first: Int32, _ last: Int32) -> Range<Int64> { start(first)..<start(last + 1) }

    static let openStart = Int64.min / 4
    static let openEnd = Int64.max / 4

    // MARK: Parts

    /// One expression's constraint before the label and fuzz.
    struct Part {
        var ranges: [Range<Int64>]?
        var weekdays: Set<Int>?
        var windows: [MinuteWindow]?
        var months: MonthRule?
        var hijri = false
        var unsupported: String?

        static func range(_ range: Range<Int64>) -> Part { Part(ranges: [range]) }

        /// Both must hold.
        func intersected(with other: Part) -> Part {
            var result = Part(hijri: hijri || other.hijri, unsupported: unsupported ?? other.unsupported)
            switch (ranges, other.ranges) {
            case (let a?, let b?):
                result.ranges = a.flatMap { first in b.compactMap { second -> Range<Int64>? in
                    let lower = max(first.lowerBound, second.lowerBound), upper = min(first.upperBound, second.upperBound)
                    return lower < upper ? lower..<upper : nil
                } }
            case (let a, let b): result.ranges = a ?? b
            }
            switch (weekdays, other.weekdays) {
            case (let a?, let b?): result.weekdays = a.intersection(b)
            case (let a, let b): result.weekdays = a ?? b
            }
            // Two parts of the day: the later, more specific one ("evening" in "Saturday evening at night" is rare).
            result.windows = other.windows ?? windows
            switch (months, other.months) {
            case (let a?, let b?):
                result.months = MonthRule(north: a.north.intersection(b.north), south: a.south.intersection(b.south), unlocatedIsSouth: a.unlocatedIsSouth)
            case (let a, let b): result.months = a ?? b
            }
            return result
        }
    }

    func resolvePart(_ expression: TimeExpression) -> Part {
        let now = todayDate
        switch expression {
        case .year(let year):
            return .range(yearRange(year))
        case .month(let month, let qualifier):
            switch qualifier {
            case .every: return Part(months: MonthRule(months: [month]))
            case .year(let year): return .range(monthRange(year, month))
            case .last: return .range(monthRange(month < now.month ? now.year : now.year - 1, month))
            case .this: return .range(monthRange(now.year, month))
            }
        case .date(let day, let month, let year):
            let resolvedYear = year ?? ((month, day) <= (now.month, now.day) ? now.year : now.year - 1)
            let date = Self.clampedDay(year: resolvedYear, month: month, day: day)
            return .range(Self.days(date, date))
        case .relativeDay(let offset):
            return .range(Self.days(today + Int32(offset), today + Int32(offset)))
        case .calendarUnit(let unit, let offset):
            return .range(calendarUnit(unit, offset: offset))
        case .rolling(let unit, let count):
            let first = shifted(today, unit, by: -count) + 1
            return .range(Self.days(min(first, today), today))
        case .ago(let unit, let count, let onThisDay):
            return ago(unit, count: count, onThisDay: onThisDay)
        case .season(let season, let qualifier):
            if qualifier == .every {
                return Part(months: MonthRule(north: Set(season.northernMonths), south: Set(season.southernMonths), unlocatedIsSouth: context.homeIsSouth))
            }
            guard let (first, last) = seasonDays(season, qualifier) else { return Part(ranges: []) }
            return .range(Self.days(first, last))
        case .weekday(let weekday, let qualifier):
            switch qualifier {
            case .every, .year: return Part(weekdays: [weekday])
            case .last:
                var day = today - Int32((LocalTime.weekday(day: today) - weekday + 7) % 7)
                if day >= today { day -= 7 }
                return .range(Self.days(day, day))
            case .this:
                let day = weekStart(today) + Int32((weekday - context.firstWeekday + 7) % 7)
                return .range(Self.days(day, day))
            }
        case .weekend(let qualifier):
            return weekend(qualifier)
        case .workdays:
            return Part(weekdays: Set(1...7).subtracting(context.weekendDays))
        case .partOfDay(let part):
            return Part(windows: [part.window])
        case .hijri(let event, let qualifier, let hijriYear):
            var part = Part(ranges: hijriOccurrences(event, qualifier, hijriYear: hijriYear).map(\.wallRange))
            part.hijri = true
            return part
        case .holiday(let holiday, let qualifier):
            return self.holiday(holiday, qualifier)
        case .range(let from, let to):
            let start = from.flatMap { interval(of: $0)?.lowerBound } ?? Self.openStart
            // "before 2020" ends where 2020 starts; "between March and May" includes May.
            let end = to.flatMap { interval(of: $0).map { from == nil ? $0.lowerBound : $0.upperBound } } ?? Self.openEnd
            return Part(ranges: start < end ? [start..<end] : [])
        case .all(let parts):
            return parts.map(resolvePart).reduce(Part()) { $0.intersected(with: $1) }
        }
    }

    // MARK: Calendar arithmetic

    func yearRange(_ year: Int) -> Range<Int64> {
        Self.days(LocalTime.day(year: year, month: 1, day: 1), LocalTime.day(year: year + 1, month: 1, day: 1) - 1)
    }

    func monthRange(_ year: Int, _ month: Int) -> Range<Int64> {
        let (nextYear, nextMonth) = month == 12 ? (year + 1, 1) : (year, month + 1)
        return Self.days(LocalTime.day(year: year, month: month, day: 1), LocalTime.day(year: nextYear, month: nextMonth, day: 1) - 1)
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        let (nextYear, nextMonth) = month == 12 ? (year + 1, 1) : (year, month + 1)
        return Int(LocalTime.day(year: nextYear, month: nextMonth, day: 1) - LocalTime.day(year: year, month: month, day: 1))
    }

    /// The day number of a date, with the day clamped to the month (30 February → 28 or 29).
    static func clampedDay(year: Int, month: Int, day: Int) -> Int32 {
        LocalTime.day(year: year, month: month, day: min(max(1, day), daysInMonth(year: year, month: month)))
    }

    /// `day` moved by whole units: weeks are 7 days; months and years keep the day of the month where it exists.
    func shifted(_ day: Int32, _ unit: TimeUnit, by count: Int) -> Int32 {
        let date = LocalTime.civil(day: day)
        switch unit {
        case .day: return day + Int32(count)
        case .week: return day + Int32(count * 7)
        case .month:
            let total = date.year * 12 + (date.month - 1) + count
            return Self.clampedDay(year: Int((Double(total) / 12).rounded(.down)), month: ((total % 12) + 12) % 12 + 1, day: date.day)
        case .year:
            return Self.clampedDay(year: date.year + count, month: date.month, day: date.day)
        }
    }

    /// The first day of the week holding `day`, in the region's week.
    func weekStart(_ day: Int32) -> Int32 {
        day - Int32((LocalTime.weekday(day: day) - context.firstWeekday + 7) % 7)
    }

    /// This (0) week, month or year up to today; last (−1) the whole previous one.
    func calendarUnit(_ unit: TimeUnit, offset: Int) -> Range<Int64> {
        let now = todayDate
        let first: Int32, last: Int32
        switch unit {
        case .day:
            first = today + Int32(offset)
            last = first
        case .week:
            first = weekStart(today) + Int32(offset * 7)
            last = offset == 0 ? today : first + 6
        case .month:
            let total = now.year * 12 + (now.month - 1) + offset
            let year = Int((Double(total) / 12).rounded(.down)), month = ((total % 12) + 12) % 12 + 1
            first = LocalTime.day(year: year, month: month, day: 1)
            last = offset == 0 ? today : first + Int32(Self.daysInMonth(year: year, month: month)) - 1
        case .year:
            first = LocalTime.day(year: now.year + offset, month: 1, day: 1)
            last = offset == 0 ? today : LocalTime.day(year: now.year + offset + 1, month: 1, day: 1) - 1
        }
        return Self.days(first, last)
    }

    /// "3 years ago" is that calendar year, "2 months ago" that month, "1 week ago" that week, "3 days ago" that day;
    /// with "today", ±3 days around the date (every earlier year for a bare "on this day").
    func ago(_ unit: TimeUnit, count: Int, onThisDay: Bool) -> Part {
        let now = todayDate
        if onThisDay {
            if unit == .year, count == 0 {
                let first = (context.years?.lowerBound ?? now.year - 30)
                guard first < now.year else { return Part(ranges: []) }
                return Part(ranges: (first..<now.year).map { year in
                    let day = Self.clampedDay(year: year, month: now.month, day: now.day)
                    return Self.days(day - 3, day + 3)
                })
            }
            let day = shifted(today, unit, by: -count)
            return .range(Self.days(day - 3, day + 3))
        }
        switch unit {
        case .year: return .range(yearRange(now.year - count))
        case .month: return .range(calendarUnit(.month, offset: -count))
        case .week: return .range(calendarUnit(.week, offset: -count))
        case .day: return .range(Self.days(today - Int32(count), today - Int32(count)))
        }
    }

    /// The first and last days of a season "of" a year in the home hemisphere: in the north winter 2025 starts in
    /// December 2025; in the south summer 2023 is the one holding January 2023.
    func seasonDays(_ season: Season, year: Int) -> (Int32, Int32) {
        let start: (year: Int, month: Int)
        if context.homeIsSouth {
            start = switch season {
            case .summer: (year - 1, 12)
            case .autumn: (year, 3)
            case .winter: (year, 6)
            case .spring: (year, 9)
            }
        } else {
            start = switch season {
            case .winter: (year, 12)
            case .spring: (year, 3)
            case .summer: (year, 6)
            case .autumn: (year, 9)
            }
        }
        let first = LocalTime.day(year: start.year, month: start.month, day: 1)
        let total = start.year * 12 + start.month - 1 + 3
        let last = LocalTime.day(year: total / 12, month: total % 12 + 1, day: 1) - 1
        return (first, last)
    }

    /// "summer 2023"; "last summer", the latest that has fully ended; "this summer", the current or upcoming one.
    func seasonDays(_ season: Season, _ qualifier: Qualifier) -> (Int32, Int32)? {
        let year = todayDate.year
        switch qualifier {
        case .year(let named): return seasonDays(season, year: named)
        case .last: return (year - 1...year + 1).reversed().map { seasonDays(season, year: $0) }.first { $0.1 < today }
        case .this: return (year - 1...year + 2).map { seasonDays(season, year: $0) }.first { $0.1 >= today }
        case .every: return nil
        }
    }

    /// Weekend days come from the home country: "last weekend" is the latest that has fully ended, "this weekend"
    /// the current or upcoming one.
    func weekend(_ qualifier: Qualifier) -> Part {
        let days = context.weekendDays
        guard qualifier == .last || qualifier == .this else { return Part(weekdays: days) }
        // The weekend's last day: a weekend day followed by a working day.
        let last = days.first { !days.contains($0 % 7 + 1) } ?? 7
        let length = Int32(days.count)
        var end: Int32
        if qualifier == .last {
            end = today - Int32((LocalTime.weekday(day: today) - last + 7) % 7)
            if end >= today { end -= 7 }
        } else {
            end = today + Int32((last - LocalTime.weekday(day: today) + 7) % 7)
        }
        return .range(Self.days(end - length + 1, end))
    }

    /// The years recurring events are looked for in: the library's, else the 30 years up to next year.
    var eventYears: ClosedRange<Int> {
        let year = todayDate.year
        guard let years = context.years else { return year - 30...year + 1 }
        return min(years.lowerBound, year)...max(years.upperBound, year)
    }

    func hijriOccurrences(_ event: HijriEvent, _ qualifier: Qualifier, hijriYear: Int?) -> [HijriCalendar.Occurrence] {
        if let hijriYear { return HijriCalendar.occurrences(event, hijriYear: hijriYear) }
        let year = todayDate.year
        switch qualifier {
        case .year(let named): return HijriCalendar.occurrences(event, startingIn: named...named)
        case .this: return HijriCalendar.occurrences(event, startingIn: year...year)
        case .every: return HijriCalendar.occurrences(event, startingIn: eventYears)
        case .last:
            let nowWall = LocalTime.wallSeconds(context.now, in: context.zone)
            return HijriCalendar.occurrences(event, startingIn: year - 2...year).last { $0.wallRange.upperBound <= nowWall }.map { [$0] } ?? []
        }
    }

    /// A holiday's wall-second range in one Gregorian year (nil when it doesn't apply to the home country).
    func holidayRange(_ holiday: Holiday, year: Int) -> Range<Int64>? {
        switch holiday {
        case .christmas:
            return Self.days(LocalTime.day(year: year, month: 12, day: 24), LocalTime.day(year: year, month: 12, day: 26))
        case .newYearsEve:
            return Int64(LocalTime.day(year: year, month: 12, day: 31)) * Self.day + 18 * 3_600..<Self.start(LocalTime.day(year: year + 1, month: 1, day: 1))
        case .newYearsDay:
            let day = LocalTime.day(year: year, month: 1, day: 1)
            return Self.days(day, day)
        case .nationalDay, .foundingDay:
            guard let (month, day) = Self.countryDays[holiday]?[context.homeCountry ?? ""] else { return nil }
            let date = LocalTime.day(year: year, month: month, day: day)
            return Self.days(date, date)
        }
    }

    /// National and founding days by home country.
    static let countryDays: [Holiday: [String: (Int, Int)]] = [
        .nationalDay: ["SA": (9, 23), "AE": (12, 2)],
        .foundingDay: ["SA": (2, 22)],
    ]

    func holiday(_ holiday: Holiday, _ qualifier: Qualifier) -> Part {
        guard holidayRange(holiday, year: 2000) != nil else {
            return Part(unsupported: holiday == .nationalDay ? "National day of which country?" : "Founding day of which country?")
        }
        let year = todayDate.year
        switch qualifier {
        case .year(let named): return Part(ranges: holidayRange(holiday, year: named).map { [$0] } ?? [])
        case .this: return Part(ranges: holidayRange(holiday, year: year).map { [$0] } ?? [])
        case .every: return Part(ranges: eventYears.compactMap { holidayRange(holiday, year: $0) })
        case .last:
            let nowWall = LocalTime.wallSeconds(context.now, in: context.zone)
            let latest = (year - 2...year).compactMap { holidayRange(holiday, year: $0) }.last { $0.upperBound <= nowWall }
            return Part(ranges: latest.map { [$0] } ?? [])
        }
    }

    /// The span an expression covers, for the ends of a range: recurring ones mean their most recent start
    /// ("since June" is since this year's June once it has begun).
    func interval(of expression: TimeExpression) -> Range<Int64>? {
        let now = todayDate
        let anchored: TimeExpression
        switch expression {
        case .month(let month, .every): anchored = .month(month, .year(month <= now.month ? now.year : now.year - 1))
        case .season(let season, .every): anchored = .season(season, .year(seasonDays(season, year: now.year).0 <= today ? now.year : now.year - 1))
        case .weekday(let weekday, .every):
            let day = today - Int32((LocalTime.weekday(day: today) - weekday + 7) % 7)
            return Self.days(day, day)
        case .hijri(let event, .every, nil):
            let nowWall = LocalTime.wallSeconds(context.now, in: context.zone)
            return HijriCalendar.occurrences(event, startingIn: now.year - 2...now.year).last { $0.wallRange.lowerBound <= nowWall }?.wallRange
        case .holiday(let holiday, .every):
            let nowWall = LocalTime.wallSeconds(context.now, in: context.zone)
            return (now.year - 1...now.year).compactMap { holidayRange(holiday, year: $0) }.last { $0.lowerBound <= nowWall }
        default: anchored = expression
        }
        guard let ranges = resolvePart(anchored).ranges, !ranges.isEmpty else { return nil }
        return ranges.map(\.lowerBound).min()!..<ranges.map(\.upperBound).max()!
    }
}
