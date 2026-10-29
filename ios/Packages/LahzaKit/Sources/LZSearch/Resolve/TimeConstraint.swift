import Foundation
import LZGeo

/// What "when" a query means, in each photo's own local time ("wall seconds", ``LocalTime``): absolute ranges,
/// weekdays (judged on the moment day), minute windows and recurring months, plus the fuzz near misses get.
public struct TimeConstraint: Sendable, Hashable {
    /// Wall-second ranges a photo must fall in (any of them). Nil: no absolute limit; empty: nothing can match.
    public var ranges: [Range<Int64>]?
    /// Moment-day weekdays (1 Sunday … 7 Saturday).
    public var weekdays: Set<Int>?
    /// Minutes since local midnight (any of them); a window may wrap past midnight. Near misses fade over 45 minutes.
    public var minuteWindows: [MinuteWindow]?
    /// Recurring months ("June", "summer"), per hemisphere.
    public var months: MonthRule?
    /// Seconds over which a near miss of `ranges` fades: max(10% of the interval, 3 days); 1 day for Hijri events;
    /// 3 days for recurring months and seasons.
    public var tau: Int64
    /// The chip text: "Last summer · Jun – Aug 2026", "Ramadan 1445 · 11 Mar – 9 Apr 2024".
    public var label: String
    /// Every range starts after today ("That's in the future").
    public var isFuture: Bool

    public init(ranges: [Range<Int64>]? = nil, weekdays: Set<Int>? = nil, minuteWindows: [MinuteWindow]? = nil, months: MonthRule? = nil,
                tau: Int64 = TimeResolver.threeDays, label: String, isFuture: Bool = false) {
        self.ranges = ranges
        self.weekdays = weekdays
        self.minuteWindows = minuteWindows
        self.months = months
        self.tau = tau
        self.label = label
        self.isFuture = isFuture
    }

    /// The fuzz for minute windows.
    public static let minuteTau = 45

    /// Whether a photo taken at `wall` local seconds (on moment day `day`, at `latitude`) is inside every part.
    public func contains(wall: Int64, latitude: Double?) -> Bool {
        if let ranges, !ranges.contains(where: { $0.contains(wall) }) { return false }
        let day = LocalTime.momentDay(wallSeconds: wall)
        if let weekdays, !weekdays.contains(LocalTime.weekday(day: day)) { return false }
        if let minuteWindows, !minuteWindows.contains(where: { $0.contains(minute: LocalTime.minuteOfDay(wallSeconds: wall)) }) { return false }
        if let months, !months.months(latitude: latitude).contains(LocalTime.civil(day: day).month) { return false }
        return true
    }
}

/// Recurring months: the same months everywhere ("June"), or a season whose months depend on the hemisphere each
/// photo was taken in (Sydney in January is summer). Photos without a position use the home hemisphere.
public struct MonthRule: Sendable, Hashable {
    public var north: Set<Int>
    public var south: Set<Int>
    public var unlocatedIsSouth: Bool

    public init(north: Set<Int>, south: Set<Int>, unlocatedIsSouth: Bool = false) {
        self.north = north
        self.south = south
        self.unlocatedIsSouth = unlocatedIsSouth
    }

    public init(months: Set<Int>) {
        self.init(north: months, south: months)
    }

    public func months(latitude: Double?) -> Set<Int> {
        guard let latitude, !latitude.isNaN else { return unlocatedIsSouth ? south : north }
        return latitude < 0 ? south : north
    }
}

/// What a time expression resolves to.
public enum TimeResolution: Sendable, Hashable {
    case constraint(TimeConstraint)
    /// Lahza can't tell which dates are meant ("National day of which country?").
    case unsupported(String)

    public var constraint: TimeConstraint? {
        if case .constraint(let constraint) = self { return constraint }
        return nil
    }
}

/// Where and when "now" is for relative dates, and which calendar facts apply (search spec S18).
public struct TimeContext: Sendable {
    public var now: Date
    /// The zone "today" is counted in: the home base's, else the device's.
    public var zone: TimeZone
    /// ISO 3166 alpha-2 of the home base: weekend days, national and founding days.
    public var homeCountry: String?
    /// The home base is south of the equator ("last summer" is Dec–Feb).
    public var homeIsSouth: Bool
    /// The iPhone's region: labels, numeric date order, the first day of the week, and weekends when there is no home.
    public var locale: Locale
    /// The years the library has photos in, for recurring events ("Ramadan", "Christmas").
    public var years: ClosedRange<Int>?

    public init(now: Date, zone: TimeZone, homeCountry: String? = nil, homeIsSouth: Bool = false, locale: Locale = .autoupdatingCurrent,
                years: ClosedRange<Int>? = nil) {
        self.now = now
        self.zone = zone
        self.homeCountry = homeCountry
        self.homeIsSouth = homeIsSouth
        self.locale = locale
        self.years = years
    }

    /// Weekend weekdays (1 Sunday … 7 Saturday) of the home country, else of the iPhone's region: Friday and Saturday in
    /// Saudi Arabia, Saturday and Sunday in the UAE, the UK or Australia.
    public var weekendDays: Set<Int> {
        let region = homeCountry ?? locale.region?.identifier
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = region.map { Locale(identifier: "en_\($0)") } ?? locale
        calendar.timeZone = .gmt
        // 4 January 1970 was a Sunday; noon keeps every check inside its day.
        let days = Set((0..<7).filter { calendar.isDateInWeekend(Date(timeIntervalSince1970: TimeInterval((3 + $0) * 86_400 + 43_200))) }.map { $0 + 1 })
        return days.isEmpty ? [1, 7] : days
    }

    /// 1 Sunday … 7 Saturday: the first day of the week in the iPhone's region.
    public var firstWeekday: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.firstWeekday
    }
}
