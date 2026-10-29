import Foundation
import LZGeo

/// Chip text for time constraints: a name, then the dates it stands for in the iPhone's own format ("Last summer ·
/// Jun – Aug 2026"). Dates come from ``LocalDateFormat``, shared with the Moments tab.
extension TimeResolver {
    func label(_ expression: TimeExpression) -> String {
        label(expression, detailed: true)
    }

    private var locale: Locale { context.locale }

    /// `detailed` adds the dates after a name ("Last December · Dec 2025"); range ends and combinations leave them out.
    func label(_ expression: TimeExpression, detailed: Bool) -> String {
        func with(_ name: String, _ details: @autoclosure () -> String?) -> String {
            guard detailed, let details = details(), !details.isEmpty else { return name }
            return "\(name) · \(details)"
        }
        let now = todayDate
        switch expression {
        case .year(let year):
            return String(year)
        case .month(let month, let qualifier):
            let name = LocalDateFormat.monthName(month, locale: locale)
            switch qualifier {
            case .every: return "Every \(name)"
            case .year(let year): return LocalDateFormat.monthTitle(year: year, month: month, locale: locale)
            case .last: return with("Last \(name)", LocalDateFormat.shortMonth(year: month < now.month ? now.year : now.year - 1, month: month, locale: locale))
            case .this: return with("This \(name)", LocalDateFormat.shortMonth(year: now.year, month: month, locale: locale))
            }
        case .date:
            return rangeText(resolvePart(expression).ranges) ?? ""
        case .relativeDay(let offset):
            switch offset {
            case 0: return "Today"
            case -1: return "Yesterday"
            default: return with("\(abs(offset)) days ago", rangeText(resolvePart(expression).ranges))
            }
        case .calendarUnit(let unit, let offset):
            let name = "\(offset == 0 ? "This" : "Last") \(unit.rawValue)"
            guard offset != 0 else { return name }
            switch unit {
            case .year: return with(name, String(now.year + offset))
            case .month:
                let total = now.year * 12 + now.month - 1 + offset
                return with(name, LocalDateFormat.shortMonth(year: total / 12, month: total % 12 + 1, locale: locale))
            case .week, .day: return with(name, rangeText(resolvePart(expression).ranges))
            }
        case .rolling(let unit, let count):
            return count == 1 ? "Past \(unit.rawValue)" : "Past \(count) \(unit.rawValue)s"
        case .ago(let unit, let count, let onThisDay):
            if onThisDay {
                if count == 0 { return "On this day" }
                if unit == .year { return "On this day in \(now.year - count)" }
                return with("\(Self.count(count, unit)) ago today", rangeText(resolvePart(expression).ranges))
            }
            switch unit {
            case .year: return "\(now.year - count) (\(Self.count(count, unit)) ago)"
            case .month:
                let total = now.year * 12 + now.month - 1 - count
                return "\(LocalDateFormat.monthTitle(year: total / 12, month: total % 12 + 1, locale: locale)) (\(Self.count(count, unit)) ago)"
            case .week, .day: return with("\(Self.count(count, unit)) ago", rangeText(resolvePart(expression).ranges))
            }
        case .season(let season, let qualifier):
            let name = season.rawValue
            switch qualifier {
            case .every: return "Every \(name)"
            case .year(let year): return with("\(name.capitalized) \(year)", monthRangeText(seasonDays(season, year: year)))
            case .last: return with("Last \(name)", seasonDays(season, .last).map(monthRangeText))
            case .this: return with("This \(name)", seasonDays(season, .this).map(monthRangeText))
            }
        case .weekday(let weekday, let qualifier):
            let name = LocalDateFormat.weekdayName(weekday, locale: locale)
            switch qualifier {
            case .every, .year: return "Every \(name)"
            case .last: return with("Last \(name)", rangeText(resolvePart(expression).ranges))
            case .this: return with("This \(name)", rangeText(resolvePart(expression).ranges))
            }
        case .weekend(let qualifier):
            switch qualifier {
            case .every, .year: return "Weekends"
            case .last: return with("Last weekend", rangeText(resolvePart(expression).ranges))
            case .this: return with("This weekend", rangeText(resolvePart(expression).ranges))
            }
        case .workdays:
            return "Weekdays"
        case .partOfDay(let part):
            return Self.partName(part).capitalizedFirst
        case .hijri(let event, let qualifier, let hijriYear):
            return hijriLabel(event, qualifier, hijriYear: hijriYear, detailed: detailed)
        case .holiday(let holiday, let qualifier):
            let name = Self.holidayName(holiday)
            switch qualifier {
            case .every: return "Every \(name)"
            case .year(let year): return with("\(name) \(year)", rangeText(holidayRange(holiday, year: year).map { [$0] }))
            case .last, .this:
                let ranges = resolvePart(expression).ranges
                let year = ranges?.first.map { LocalTime.civil(day: LocalTime.momentDay(wallSeconds: $0.lowerBound)).year }
                return with(year.map { "\(name) \($0)" } ?? "\(qualifier == .last ? "Last" : "This") \(name)", rangeText(ranges))
            }
        case .range(let from, let to):
            switch (from, to) {
            case (let from?, let to?): return "\(label(from, detailed: false)) – \(label(to, detailed: false))"
            case (let from?, nil): return "Since \(label(from, detailed: false).lowercasedFirstIfWord)"
            case (nil, let to?): return "Before \(label(to, detailed: false).lowercasedFirstIfWord)"
            case (nil, nil): return ""
            }
        case .all(let parts):
            return combinedLabel(RuleScan.parts(.all(parts)))
        }
    }

    /// "Saturday evening", "Last night", "Tonight", then the rest joined by " · ".
    private func combinedLabel(_ parts: [TimeExpression]) -> String {
        var rest = parts
        var pieces: [String] = []
        if let partIndex = rest.firstIndex(where: { if case .partOfDay = $0 { true } else { false } }), case .partOfDay(let part) = rest[partIndex] {
            if let dayIndex = rest.firstIndex(where: { if case .relativeDay = $0 { true } else { false } }), case .relativeDay(let offset) = rest[dayIndex],
               offset == 0 || offset == -1 {
                let phrase = switch (offset, part) {
                case (0, .tonight): "Tonight"
                case (-1, .night): "Last night"
                case (0, _): "This \(Self.partName(part))"
                default: "Yesterday \(Self.partName(part))"
                }
                pieces.append(phrase)
                rest.removeAll { $0 == .relativeDay(offset) || $0 == .partOfDay(part) }
            } else if let weekdayIndex = rest.firstIndex(where: { if case .weekday = $0 { true } else { false } }),
                      case .weekday(let weekday, let qualifier) = rest[weekdayIndex] {
                let name = LocalDateFormat.weekdayName(weekday, locale: locale)
                let prefix = switch qualifier {
                case .last: "Last "
                case .this: "This "
                default: ""
                }
                pieces.append("\(prefix)\(name) \(Self.partName(part))")
                rest.removeAll { $0 == .weekday(weekday, qualifier) || $0 == .partOfDay(part) }
            }
        }
        pieces += rest.map { label($0, detailed: rest.count == 1 && pieces.isEmpty) }
        return pieces.joined(separator: " · ")
    }

    private func hijriLabel(_ event: HijriEvent, _ qualifier: Qualifier, hijriYear: Int?, detailed: Bool) -> String {
        let name = Self.hijriName(event)
        let occurrences = hijriOccurrences(event, qualifier, hijriYear: hijriYear)
        if hijriYear == nil, qualifier == .every { return "Every \(name)" }
        guard let first = occurrences.first else {
            if let hijriYear { return "\(name) \(hijriYear)" }
            if case .year(let year) = qualifier { return "\(name) \(year)" }
            return qualifier == .last ? "Last \(name)" : "This \(name)"
        }
        if occurrences.count == 1 {
            let title = "\(Self.hijriName(first.event)) \(first.hijriYear)"
            return detailed ? "\(title) · \(LocalDateFormat.dayRange(first.first, first.last, locale: locale))" : title
        }
        let years = Array(Set(occurrences.map(\.hijriYear))).sorted()
        let title: String
        if case .year(let year) = qualifier { title = "\(name) \(year)" } else if let hijriYear { title = "\(name) \(hijriYear)" } else { title = name }
        guard detailed else { return title }
        return event == .eid && years.count == 1 ? "\(title) · al-Fitr and al-Adha" : "\(title) · \(years.map(String.init).joined(separator: " and "))"
    }

    // MARK: Words

    static func count(_ value: Int, _ unit: TimeUnit) -> String {
        value == 1 ? "1 \(unit.rawValue)" : "\(value) \(unit.rawValue)s"
    }

    static func partName(_ part: PartOfDay) -> String {
        switch part {
        case .lateNight: "late night"
        default: part.rawValue
        }
    }

    static func hijriName(_ event: HijriEvent) -> String {
        switch event {
        case .ramadan: "Ramadan"
        case .eidAlFitr: "Eid al-Fitr"
        case .eidAlAdha: "Eid al-Adha"
        case .eid: "Eid"
        case .hajj: "Hajj"
        }
    }

    static func holidayName(_ holiday: Holiday) -> String {
        switch holiday {
        case .christmas: "Christmas"
        case .newYearsEve: "New Year’s Eve"
        case .newYearsDay: "New Year’s Day"
        case .nationalDay: "National Day"
        case .foundingDay: "Founding Day"
        }
    }

    /// The days of the ranges: "Sat, 14 Jun 2025" for one day, "23 – 24 Oct 2026" for several.
    private func rangeText(_ ranges: [Range<Int64>]?) -> String? {
        guard let ranges, let lower = ranges.map(\.lowerBound).min(), let upper = ranges.map(\.upperBound).max(),
              lower > Self.openStart, upper < Self.openEnd else { return nil }
        let first = LocalTime.momentDay(wallSeconds: lower), last = LocalTime.momentDay(wallSeconds: upper - 1)
        return first == last ? LocalDateFormat.dayTitle(first, locale: locale) : LocalDateFormat.dayRange(first, last, locale: locale)
    }

    /// "Jun – Aug 2026" for a season's days.
    private func monthRangeText(_ days: (Int32, Int32)) -> String {
        let first = LocalTime.civil(day: days.0), last = LocalTime.civil(day: days.1)
        return LocalDateFormat.monthRange(from: (first.year, first.month), to: (last.year, last.month), locale: locale)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }

    /// "Since June 2024", but "Since every Saturday" → keeps names capitalised and lowers only the leading "Every"/"Last".
    var lowercasedFirstIfWord: String {
        for word in ["Every ", "Last ", "This "] where hasPrefix(word) { return word.lowercased() + dropFirst(word.count) }
        return self
    }
}
