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

    func placeReason(_ evidence: PlaceEvidence, place: PlaceDescription, trips: [Int64: TripRow]) -> Reason? {
        switch evidence {
        case .inside(let metro):
            if place.isHome { return Reason(.place, "At home", "house") }
            if place.isArea { return Reason(.place, "In \(place.name)", "mappin.circle") }
            return Reason(.place, metro ? "In the \(place.name) area" : "In \(place.name)", "mappin")
        case .near(let metres):
            return Reason(.caution, "\(distance(metres)) from \(place.isHome ? "home" : place.name)", "mappin.and.ellipse")
        case .receivedSameDay:
            return Reason(.borrowed, "Saved the day of your \(place.isHome ? "home" : place.name) visit", "tray.and.arrow.down")
        case .tripBorrow(let trip):
            let label = trips[Int64(trip)]?.label ?? place.name
            return Reason(.borrowed, "During your \(label) trip", "airplane")
        case .unknown:
            return Reason(.neutral, "No location data", "questionmark.circle")
        case .outside:
            return nil
        }
    }

    func borrowedReason(_ source: SearchSnapshot.PositionSource) -> Reason? {
        switch source {
        case .momentNear: Reason(.borrowed, "Location from the same outing", "link")
        case .momentFar: Reason(.borrowed, "Location from nearby photos", "link")
        case .gps, .none: nil
        }
    }

    func timeReason(_ evidence: TimeEvidence, expression: TimeExpression?) -> Reason? {
        guard let expression else { return nil }
        switch evidence {
        case .inside:
            return Reason(.time, timeInside(expression), "calendar")
        case .nearMiss(let days):
            let name = reasonName(expression)
            let text: String = switch days {
            case 0: "Close to \(name)"
            case 1: "Day after \(name)"
            case -1: "Day before \(name)"
            case let days where days > 0: "\(days) days after \(name)"
            default: "\(-days) days before \(name)"
            }
            return Reason(.caution, text, "calendar.badge.clock")
        case .minutesOff(let minutes):
            let name = timeInside(expression).lowercased()
            return Reason(.caution, minutes > 0 ? "\(minutes) min after \(name)" : "\(-minutes) min before \(name)", "clock.badge.exclamationmark")
        case .monthsOff(let days):
            let name = timeInside(expression).lowercased()
            let text: String = switch days {
            case 1: "Day after \(name)"
            case -1: "Day before \(name)"
            case let days where days > 0: "\(days) days after \(name)"
            default: "\(-days) days before \(name)"
            }
            return Reason(.caution, text, "calendar.badge.clock")
        case .unreliable:
            return Reason(.neutral, "No reliable date", "questionmark.circle")
        case .wrongWeekday, .outside:
            return nil
        }
    }

    static func videoReason(duration: Double) -> Reason {
        Reason(.media, "Video · \(clock(duration))", "video")
    }

    static let selfieReason = Reason(.media, "Selfie", "person.crop.square")
    static let favoriteReason = Reason(.media, "Favorite", "heart")
    static let screenshotReason = Reason(.media, "Screenshot (ranked lower)", "camera.viewfinder")

    static func tripReason(_ trip: TripRow) -> Reason {
        Reason(.event, "\(trip.label) trip", "airplane")
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

    /// "520 m", "2 km", "2.1 km".
    func distance(_ metres: Double) -> String {
        if metres < 1_000 {
            let rounded = (metres / 10).rounded() * 10
            return Measurement(value: rounded, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
        }
        let kilometres = metres / 1_000
        return Measurement(value: kilometres, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))).locale(locale))
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

    func coverageCaption(searched: Int, index: SearchIndexContext) -> String {
        let count = searched.formatted(.number.locale(locale))
        if index.isLimited { return searched == 1 ? "Searching the 1 photo you’ve shared" : "Searching the \(count) photos you’ve shared" }
        if index.isPartial, let total = index.libraryTotal, total > searched {
            return "Searched \(count) of about \(total.formatted(.number.locale(locale))) so far"
        }
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
