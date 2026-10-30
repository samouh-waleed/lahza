import Foundation
import LZGeo
import LZIndex

/// Search's words: reasons, section titles, coverage lines and no-match copy, from fixed English templates. Dates
/// follow the iPhone's region through ``LocalDateFormat`` (shared with the Moments tab); distances are metres and
/// kilometres in the region's number format.
struct SearchCopy {
    var locale: Locale
    var resolver: TimeResolver

    // MARK: Names

    /// A time slot in a sentence: "December 2025", "Ramadan 2024", "summer 2026", "2023", "last weekend".
    func sentenceName(_ expression: TimeExpression) -> String {
        let now = resolver.todayDate
        switch expression {
        case .year(let year): return String(year)
        case .ago(.year, let count, false): return String(now.year - count)
        case .month(let month, .last): return LocalDateFormat.monthTitle(year: month < now.month ? now.year : now.year - 1, month: month, locale: locale)
        case .month(let month, .this): return LocalDateFormat.monthTitle(year: now.year, month: month, locale: locale)
        case .month(let month, .year(let year)): return LocalDateFormat.monthTitle(year: year, month: month, locale: locale)
        case .month(let month, .every): return LocalDateFormat.monthName(month, locale: locale)
        case .season(let season, .year(let year)): return "\(season.rawValue) \(year)"
        case .season(let season, .every): return season.rawValue
        case .season(let season, let qualifier):
            guard let days = resolver.seasonDays(season, qualifier),
                  let year = (now.year - 1...now.year + 1).first(where: { resolver.seasonDays(season, year: $0) == days }) else {
                return resolver.label(expression, detailed: false).lowercasedFirstIfWord
            }
            return "\(season.rawValue) \(year)"
        case .hijri(let event, .year(let year), nil): return "\(TimeResolver.hijriName(event)) \(year)"
        case .hijri(let event, let qualifier, nil) where qualifier == .last || qualifier == .this:
            let occurrences = resolver.hijriOccurrences(event, qualifier, hijriYear: nil)
            guard occurrences.count == 1, let only = occurrences.first else { return resolver.label(expression, detailed: false).lowercasedFirstIfWord }
            return "\(TimeResolver.hijriName(only.event)) \(only.hijriYear)"
        default: return resolver.label(expression, detailed: false).lowercasedFirstIfWord
        }
    }

    /// The word before a time slot in a sentence: "during Ramadan 2024", "in December 2025", "on Saturdays".
    func preposition(_ expression: TimeExpression) -> String {
        switch expression {
        case .hijri, .holiday: "during"
        case .date, .relativeDay, .weekday, .weekend, .workdays: "on"
        case .range, .rolling, .partOfDay, .all: "from"
        default: "in"
        }
    }

    /// A time slot in a reason: "Ramadan 1445" (the Hijri year of a single occurrence), else the sentence name.
    func reasonName(_ expression: TimeExpression) -> String {
        if case .hijri(let event, let qualifier, let hijriYear) = expression {
            let occurrences = resolver.hijriOccurrences(event, qualifier, hijriYear: hijriYear)
            if occurrences.count == 1, let only = occurrences.first { return "\(TimeResolver.hijriName(only.event)) \(only.hijriYear)" }
        }
        return sentenceName(expression)
    }

    /// The text of a time reason for a photo inside the dates: "Summer 2026", "Ramadan 1446", "Saturday evening",
    /// "2023 · 3 years ago".
    func timeInside(_ expression: TimeExpression) -> String {
        switch expression {
        case .ago(.year, let count, false): return "\(resolver.todayDate.year - count) · \(TimeResolver.count(count, .year)) ago"
        case .weekday(let weekday, .every), .weekday(let weekday, .year): return LocalDateFormat.weekdayName(weekday, locale: locale)
        case .all: return resolver.label(expression, detailed: false).replacingOccurrences(of: "Every ", with: "")
        default: return reasonName(expression).capitalizedFirst
        }
    }

    // MARK: Reasons

    /// A place reason, and its sentence for "Why this matched". `noun` is "photo" or "video".
    func placeReason(_ evidence: PlaceEvidence, place: PlaceDescription, trips: [Int64: TripRow], noun: String = "photo") -> Reason? {
        switch evidence {
        case .inside(let metro):
            if place.isHome { return Reason(.place, "At home", "house", detail: "Taken at home.") }
            if place.isArea { return Reason(.place, "In \(place.name)", "mappin.circle", detail: "Taken inside \(place.name).") }
            return metro
                ? Reason(.place, "In the \(place.name) area", "mappin", detail: "Taken in the \(place.name) area.")
                : Reason(.place, "In \(place.name)", "mappin", detail: "Taken in \(place.fullName).")
        case .near(let metres):
            let detail = place.isHome
                ? "Taken \(distance(metres)) from home."
                : "Taken \(distance(metres)) from the middle of \(place.name), just outside the area searched."
            return Reason(.caution, "\(distance(metres)) from \(place.isHome ? "home" : place.name)", "mappin.and.ellipse", detail: detail)
        case .receivedSameDay:
            return Reason(.borrowed, "Saved the day of your \(place.isHome ? "home" : place.name) visit", "tray.and.arrow.down",
                          detail: "No location in this \(noun). It was saved the day you were \(place.phrase).")
        case .tripBorrow(let trip):
            let label = trips[Int64(trip)]?.label ?? place.name
            return Reason(.borrowed, "During your \(label) trip", "airplane", detail: "No location in this \(noun). It was taken during your \(label) trip.")
        case .unknown:
            return Reason(.neutral, "No location data", "questionmark.circle", detail: "No location in this \(noun), but everything else matches.")
        case .outside:
            return nil
        }
    }

    /// A borrowed location's reason. `gap` is the seconds from the item it borrowed from (negative: that one was taken
    /// earlier), when known.
    func borrowedReason(_ source: SearchSnapshot.PositionSource, noun: String = "photo", from sourceNoun: String = "photo", gap: Int64? = nil) -> Reason? {
        let detail = gap.map { "No GPS in this \(noun). Location comes from a \(sourceNoun) taken \(Self.gapPhrase($0)) in the same outing." }
            ?? "No GPS in this \(noun). Location comes from another \(sourceNoun) of the same outing."
        return switch source {
        case .momentNear: Reason(.borrowed, "Location from the same outing", "link", detail: detail)
        case .momentFar: Reason(.borrowed, "Location from nearby photos", "link", detail: detail)
        case .gps, .none: nil
        }
    }

    /// "3 min earlier", "1 hr 20 min later", "seconds earlier", "at the same moment" (`seconds` negative: earlier).
    static func gapPhrase(_ seconds: Int64) -> String {
        let magnitude = abs(seconds)
        guard magnitude > 0 else { return "at the same moment" }
        let direction = seconds < 0 ? "earlier" : "later"
        guard magnitude >= 60 else { return "seconds \(direction)" }
        let minutes = Int((Double(magnitude) / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min \(direction)" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr \(direction)" : "\(minutes / 60) hr \(minutes % 60) min \(direction)"
    }

    func timeReason(_ evidence: TimeEvidence, expression: TimeExpression?, noun: String = "photo") -> Reason? {
        guard let expression else { return nil }
        let outside = "just outside the dates you asked for"
        switch evidence {
        case .inside:
            return Reason(.time, timeInside(expression), "calendar", detail: timeSentence(expression))
        case .nearMiss(let days):
            let name = reasonName(expression)
            let text: String = switch days {
            case 0: "Close to \(name)"
            case 1: "Day after \(name)"
            case -1: "Day before \(name)"
            case let days where days > 0: "\(days) days after \(name)"
            default: "\(-days) days before \(name)"
            }
            return Reason(.caution, text, "calendar.badge.clock", detail: "Taken \(Self.dayOffset(days, from: name)), \(outside).")
        case .minutesOff(let minutes):
            let name = timeInside(expression).lowercased()
            let text = minutes > 0 ? "\(minutes) min after \(name)" : "\(-minutes) min before \(name)"
            return Reason(.caution, text, "clock.badge.exclamationmark", detail: "Taken \(text), just outside the time of day you asked for.")
        case .monthsOff(let days):
            let name = timeInside(expression).lowercased()
            let text: String = switch days {
            case 1: "Day after \(name)"
            case -1: "Day before \(name)"
            case let days where days > 0: "\(days) days after \(name)"
            default: "\(-days) days before \(name)"
            }
            return Reason(.caution, text, "calendar.badge.clock", detail: "Taken \(Self.dayOffset(days, from: name)), \(outside).")
        case .unreliable:
            return Reason(.neutral, "No reliable date", "questionmark.circle", detail: "This \(noun) has no reliable date.")
        case .wrongWeekday, .outside:
            return nil
        }
    }

    /// "the day after Ramadan 1445", "2 days before summer 2025", "close to December 2025".
    static func dayOffset(_ days: Int, from name: String) -> String {
        switch days {
        case 0: "close to \(name)"
        case 1: "the day after \(name)"
        case -1: "the day before \(name)"
        case let days where days > 0: "\(days) days after \(name)"
        default: "\(-days) days before \(name)"
        }
    }

    /// A photo inside the dates, as a sentence: "Taken in summer 2025.", "Taken during Ramadan 1445.", "Taken on a
    /// Saturday.", "Taken in 2023, 3 years ago."; combinations and ranges name the dates ("Taken in the dates you asked
    /// for: Saturday evening.").
    func timeSentence(_ expression: TimeExpression) -> String {
        switch expression {
        case .year, .month, .season, .date:
            return "Taken \(preposition(expression)) \(reasonName(expression))."
        case .hijri(let event, .every, nil):
            return "Taken during \(TimeResolver.hijriName(event))."
        case .hijri:
            return "Taken during \(reasonName(expression))."
        case .holiday(let holiday, .every):
            return "Taken on \(TimeResolver.holidayName(holiday))."
        case .holiday:
            return "Taken on \(timeInside(expression))."
        case .ago(.year, let count, false):
            return "Taken in \(resolver.todayDate.year - count), \(TimeResolver.count(count, .year)) ago."
        case .ago(.month, let count, false):
            let now = resolver.todayDate, total = now.year * 12 + now.month - 1 - count
            return "Taken in \(LocalDateFormat.monthTitle(year: total / 12, month: total % 12 + 1, locale: locale)), \(TimeResolver.count(count, .month)) ago."
        case .ago(let unit, let count, false):
            return "Taken \(TimeResolver.count(count, unit)) ago."
        case .ago(_, 0, true):
            return "Taken on this day in an earlier year."
        case .ago(.year, let count, true):
            return "Taken around this day in \(resolver.todayDate.year - count)."
        case .relativeDay(let offset):
            return switch offset {
            case 0: "Taken today."
            case -1: "Taken yesterday."
            default: "Taken \(TimeResolver.count(-offset, .day)) ago."
            }
        case .calendarUnit(let unit, let offset):
            return "Taken \(offset == 0 ? "this" : "last") \(unit.rawValue)."
        case .rolling(let unit, let count):
            return "Taken in the past \(count == 1 ? unit.rawValue : TimeResolver.count(count, unit))."
        case .weekday(let weekday, let qualifier):
            let name = LocalDateFormat.weekdayName(weekday, locale: locale)
            return switch qualifier {
            case .last: "Taken last \(name)."
            case .this: "Taken this \(name)."
            case .every, .year: "Taken on a \(name)."
            }
        case .weekend(let qualifier):
            return switch qualifier {
            case .last: "Taken last weekend."
            case .this: "Taken this weekend."
            case .every, .year: "Taken on a weekend."
            }
        case .workdays:
            return "Taken on a weekday."
        case .partOfDay(let part):
            let phrase = switch part {
            case .morning: "in the morning"
            case .noon: "around noon"
            case .afternoon: "in the afternoon"
            case .evening: "in the evening"
            case .night: "at night"
            case .lateNight: "late at night"
            case .tonight: "tonight"
            }
            return "Taken \(phrase)."
        case .ago, .range, .all:
            return "Taken in the dates you asked for: \(timeInside(expression))."
        }
    }

    static func videoReason(duration: Double) -> Reason {
        Reason(.media, "Video · \(clock(duration))", "video", detail: "A video, \(clock(duration)) long.")
    }

    static let selfieReason = Reason(.media, "Selfie", "person.crop.square", detail: "A selfie, taken with the front camera.")
    static let favoriteReason = Reason(.media, "Favorite", "heart", detail: "One of your favorites.")
    static let screenshotReason = Reason(.media, "Screenshot (ranked lower)", "camera.viewfinder", detail: "A screenshot, so it’s ranked below your photos.")

    static func tripReason(_ trip: TripRow) -> Reason {
        Reason(.event, "\(trip.label) trip", "airplane", detail: "Part of your \(trip.label) trip.")
    }

    /// "Includes 3 without location from this outing".
    static func borrowedCardReason(_ count: Int) -> Reason {
        Reason(.borrowed, "Includes \(count) without location from this outing", "link")
    }

    /// "1:05", "0:42".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "No matches in the last 12 months." — a free search whose matches are all older than it covers.
    func onlyEarlier(since: Date, now: Date) -> String {
        "No matches in the \(lastPeriod(since: since, now: now))."
    }

    /// "last 12 months", "last month", "last 20 days": a free search's window, in whole months.
    func lastPeriod(since: Date, now: Date) -> String {
        let days = max(0, now.timeIntervalSince(since) / 86_400)
        let months = Int((days / 30.436875).rounded())
        return switch months {
        case 0: "last \(Int(days.rounded())) days"
        case 1: "last month"
        default: "last \(months) months"
        }
    }

    /// "520 m", "2 km", "2.1 km".
    func distance(_ metres: Double) -> String {
        SearchFormat.distance(metres, locale: locale)
    }

    // MARK: Sections

    func sectionTitle(_ tier: Tier, place: PlaceDescription?, count: Int) -> (title: String, caption: String?) {
        switch tier {
        case .best:
            guard let place, place.isArea, !place.isUnion else { return ("Matches", nil) }
            return (place.isHome ? "At home" : "Inside \(place.name)", nil)
        case .more: return ("Nearby or close in time", "Just outside the place or dates, or saved the same day")
        case .locationUnknown: return ("Location unknown · \(count.formatted(.number.locale(locale)))", "No location data, but everything else matches")
        case .weaker: return ("Weaker matches", nil)
        }
    }

    // MARK: Coverage

    /// "Searched all 563 photos"; a free search (`since`) "Searched your last 12 months" (E20), its unlock row counting
    /// the rest. Limited access and the first build's progress keep their own words, free or not: they say which photos
    /// Lahza has, which the window doesn't change. A first build that has stopped short (paused, starting again,
    /// failed) of the dates searched reads "Searched 1,200 photos so far", never "all" or the whole window.
    func coverageCaption(searched: Int, index: SearchIndexContext, since: Date?, now: Date) -> String {
        let count = searched.formatted(.number.locale(locale))
        if index.isLimited { return searched == 1 ? "Searching the 1 photo you’ve shared" : "Searching the \(count) photos you’ve shared" }
        if index.isPartial, let total = index.libraryTotal, total > searched {
            return "Searched \(count) of about \(total.formatted(.number.locale(locale))) so far"
        }
        let covered = !index.isPartial || index.libraryTotal != nil || (since.flatMap { since in index.coveredSince.map { $0 <= since } } ?? false)
        if !covered { return searched == 1 ? "Searched 1 photo so far" : "Searched \(count) photos so far" }
        if let since { return "Searched your \(lastPeriod(since: since, now: now))" }
        return searched == 1 ? "Searched 1 photo" : "Searched all \(count) photos"
    }

    /// "Searched your photos since Mar 2021, still reading older ones".
    func partialHeader(since date: Date, zone: TimeZone) -> String {
        "Searched your photos since \(month(of: date, zone: zone)), still reading older ones"
    }

    /// "Mar 2021".
    func month(of date: Date, zone: TimeZone) -> String {
        let day = LocalTime.civil(day: Int32((Double(LocalTime.wallSeconds(date, in: zone)) / 86_400).rounded(.down)))
        return LocalDateFormat.shortMonth(year: day.year, month: day.month, locale: locale)
    }

    func photosCount(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count.formatted(.number.locale(locale))) photos"
    }

    // MARK: Unsupported

    /// "Lahza can't see what's in photos yet, so “soccer” was left out. Showing all your photos at Al-Nakheel Park."
    /// Dates Lahza couldn't use are quoted as typed (their chip says why).
    func unsupportedNotice(_ unsupported: [ResolvedSlot], text: String, showing: String?) -> String? {
        guard !unsupported.isEmpty else { return nil }
        let words = unsupported.map { "“\($0.slot.kind == .time ? $0.slot.span?.substring(of: text) ?? $0.chip : $0.chip)”" }
        let list = words.count == 1 ? words[0] : words.dropLast().joined(separator: ", ") + " and " + words.last!
        let reason: String
        if unsupported.allSatisfy({ $0.slot.kind == .people }) {
            reason = "Lahza can’t search for people yet"
        } else if unsupported.allSatisfy({ $0.slot.kind == .visual || $0.slot.kind == .text }) {
            reason = "Lahza can’t see what’s in photos yet"
        } else {
            reason = "Lahza can’t search for everything you asked yet"
        }
        let rest = showing.map { " Showing all your photos \($0)." } ?? ""
        return "\(reason), so \(list) \(words.count == 1 ? "was" : "were") left out.\(rest)"
    }
}

/// How a resolved place reads in reasons and sentences.
struct PlaceDescription: Sendable, Hashable {
    /// "Al-Nakheel Park", "Riyadh", "Greece".
    var name: String
    /// "Paris, France" for a city; the name otherwise.
    var fullName: String
    var isArea: Bool
    var isHome: Bool
    var isUnion: Bool
    var radius: Double?

    /// "at Al-Nakheel Park", "in Riyadh".
    var phrase: String { isHome ? "at home" : "\(isArea ? "at" : "in") \(name)" }

    init(_ candidate: PlaceCandidate) {
        name = candidate.name
        isHome = candidate.id == PlaceKey.home || candidate.source == .home
        switch candidate.resolved {
        case .area(_, let radius, let category, _):
            isArea = true
            isUnion = false
            self.radius = radius
            if category == .home { isHome = true }
            fullName = candidate.name
        case .membership(let level, _, _, _):
            isArea = false
            isUnion = false
            fullName = (level == .city || level == .locality || level == .region) && candidate.context.map({ $0 != candidate.name }) == true
                ? "\(candidate.name), \(candidate.context!)" : candidate.name
        case .categoryUnion:
            isArea = true
            isUnion = true
            fullName = candidate.name
        case .anyOf:
            isArea = false
            isUnion = true
            fullName = candidate.name
        }
    }
}

/// Formats search shares with the app (the place editor's radii).
public enum SearchFormat {
    /// "520 m", "2 km", "2.1 km".
    public static func distance(_ metres: Double, locale: Locale = .autoupdatingCurrent) -> String {
        if metres < 1_000 {
            let rounded = (metres / 10).rounded() * 10
            return Measurement(value: rounded, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
        }
        let kilometres = metres / 1_000
        return Measurement(value: kilometres, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))).locale(locale))
    }
}
