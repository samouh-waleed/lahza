import Foundation

/// Which occurrence of a recurring date the query means.
public enum Qualifier: Sendable, Hashable, Codable {
    /// Every occurrence ("June", "Saturdays", "Ramadan").
    case every
    /// The most recent one that has ended ("last June").
    case last
    /// This year's, or the current or upcoming one ("this summer").
    case this
    /// The one in (or starting in) this Gregorian year ("June 2023", "Ramadan 2024").
    case year(Int)
}

/// When the photos were taken, as the query says it. Pure values: ``TimeResolver`` turns them into ranges of local
/// time. `Codable`, so a Foundation Models parser can emit the same values later.
public indirect enum TimeExpression: Sendable, Hashable, Codable {
    case year(Int)
    /// "june" `.every` · "june 2023" `.year` · "last june" `.last`.
    case month(Int, Qualifier)
    /// `year` nil: the most recent occurrence on or before today.
    case date(day: Int, month: Int, year: Int?)
    /// 0 today, −1 yesterday.
    case relativeDay(Int)
    /// This (0) or last (−1) week, month or year.
    case calendarUnit(TimeUnit, offset: Int)
    /// The past N units up to today; "recently" is 30 days.
    case rolling(TimeUnit, count: Int)
    /// "3 years ago" (the calendar year), "3 years ago today" (±3 days around that date). `count` 0 with
    /// `onThisDay` is "on this day" in every earlier year.
    case ago(TimeUnit, count: Int, onThisDay: Bool)
    case season(Season, Qualifier)
    /// 1 Sunday … 7 Saturday, judged on the moment day.
    case weekday(Int, Qualifier)
    case weekend(Qualifier)
    case workdays
    case partOfDay(PartOfDay)
    /// `hijriYear` (1300–1600) names the Hijri year ("Ramadan 1445").
    case hijri(HijriEvent, Qualifier, hijriYear: Int?)
    case holiday(Holiday, Qualifier)
    /// between/from–to, since, before, after.
    case range(from: TimeExpression?, to: TimeExpression?)
    /// Every part must hold ("Saturday evening in July 2023").
    case all([TimeExpression])
}

public enum TimeUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case day, week, month, year
}

/// Meteorological seasons: in the north winter is Dec–Feb, spring Mar–May, summer Jun–Aug and autumn Sep–Nov;
/// the south is flipped.
public enum Season: String, Sendable, Hashable, Codable, CaseIterable {
    case winter, spring, summer, autumn

    /// The months in the northern hemisphere, in order.
    public var northernMonths: [Int] {
        switch self {
        case .winter: [12, 1, 2]
        case .spring: [3, 4, 5]
        case .summer: [6, 7, 8]
        case .autumn: [9, 10, 11]
        }
    }

    /// The months in the southern hemisphere, in order.
    public var southernMonths: [Int] { opposite.northernMonths }

    public var opposite: Season {
        switch self {
        case .winter: .summer
        case .spring: .autumn
        case .summer: .winter
        case .autumn: .spring
        }
    }
}

/// Parts of the day, in local time: morning 05–12, noon 11–14, afternoon 12–17, evening 17–21, night 21–04 (the
/// 04:00 day break keeps Friday night on Friday), late night 00–04, tonight 17–04.
public enum PartOfDay: String, Sendable, Hashable, Codable, CaseIterable {
    case morning, noon, afternoon, evening, night, lateNight, tonight

    /// Minutes since local midnight; the end may be before the start (the window wraps past midnight).
    public var window: MinuteWindow {
        switch self {
        case .morning: MinuteWindow(start: 5 * 60, end: 12 * 60)
        case .noon: MinuteWindow(start: 11 * 60, end: 14 * 60)
        case .afternoon: MinuteWindow(start: 12 * 60, end: 17 * 60)
        case .evening: MinuteWindow(start: 17 * 60, end: 21 * 60)
        case .night: MinuteWindow(start: 21 * 60, end: 4 * 60)
        case .lateNight: MinuteWindow(start: 0, end: 4 * 60)
        case .tonight: MinuteWindow(start: 17 * 60, end: 4 * 60)
        }
    }
}

/// Events of the Hijri calendar (Umm al-Qura).
public enum HijriEvent: String, Sendable, Hashable, Codable, CaseIterable {
    /// The month of Ramadan.
    case ramadan
    /// 1–3 Shawwal.
    case eidAlFitr
    /// 10–13 Dhu al-Hijjah.
    case eidAlAdha
    /// Both Eids.
    case eid
    /// 8–13 Dhu al-Hijjah.
    case hajj
}

public enum Holiday: String, Sendable, Hashable, Codable, CaseIterable {
    /// 24–26 December.
    case christmas
    /// 31 December 18:00 → 1 January 04:00.
    case newYearsEve
    /// 1 January.
    case newYearsDay
    /// The home country's national day (Saudi Arabia 23 September, UAE 2 December).
    case nationalDay
    /// Saudi Founding Day, 22 February.
    case foundingDay
}

/// Minutes since local midnight, `start` inclusive, `end` exclusive; wraps past midnight when `end <= start`.
public struct MinuteWindow: Sendable, Hashable, Codable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var wraps: Bool { end <= start }

    public func contains(minute: Int) -> Bool {
        wraps ? minute >= start || minute < end : minute >= start && minute < end
    }

    /// Minutes from `minute` to the nearest edge of the window, 0 inside (around the clock, so 23:50 is 10 minutes
    /// from a window starting at midnight).
    public func distance(minute: Int) -> Int {
        guard !contains(minute: minute) else { return 0 }
        func around(_ a: Int, _ b: Int) -> Int {
            let d = abs(a - b) % 1_440
            return min(d, 1_440 - d)
        }
        return min(around(minute, start), around(minute, end))
    }
}
