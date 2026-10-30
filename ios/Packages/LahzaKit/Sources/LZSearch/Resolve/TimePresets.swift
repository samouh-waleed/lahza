import Foundation
import LZGeo

/// A quick change the time editor offers for a date chip (search spec §7.1): "Summer 2025", "Every summer", "Any time".
public struct TimePreset: Sendable, Hashable, Identifiable {
    /// "Summer 2025", "Every Ramadan", "On this day in 2023".
    public var label: String
    /// What the slot becomes; nil for "Any time" (the dates go).
    public var expression: TimeExpression?

    public init(label: String, expression: TimeExpression?) {
        self.label = label
        self.expression = expression
    }

    public var id: String { label }
}

extension TimeResolver {
    /// The time editor's presets for a date chip, nearest change first:
    /// - a season or month: the one a year before (and after, once it has begun), every one, and any time ("last
    ///   summer": Summer 2025 · Every summer · Any time);
    /// - Ramadan, Eid or a holiday: the one a year before (and after, once it has begun) and every one ("Ramadan 2025":
    ///   Ramadan 2024 · Ramadan 2026 · Every Ramadan);
    /// - "3 years ago": On this day in 2023 · 2 years ago; "3 years ago today": All of 2023 · 2 years ago today;
    /// - a weekday or the weekend: last ↔ every; a year: the year before and after; a date: its month; today ↔
    ///   yesterday; this ↔ last week, month or year.
    /// A part of the day stays as it is (the editor changes it separately): "Any time" then keeps only it ("last summer
    /// at night" → "at night"). Ranges and rolling windows get none.
    public func presets(for expression: TimeExpression) -> [TimePreset] {
        if case .all(let parts) = expression {
            // One date part with a part of the day ("Saturday evening"): presets change the date part only. "Tonight"
            // is today's.
            let dates = parts.filter { if case .partOfDay = $0 { false } else { true } }
            guard dates.count == 1, let date = dates.first, !parts.contains(.partOfDay(.tonight)) else { return [] }
            let rest = parts.filter { $0 != date }
            return presets(for: date).map { preset in
                guard let replacement = preset.expression else {
                    return TimePreset(label: preset.label, expression: rest.isEmpty ? nil : rest.count == 1 ? rest[0] : .all(rest))
                }
                return TimePreset(label: preset.label, expression: .all(parts.map { $0 == date ? replacement : $0 }))
            }
        }
        let now = todayDate
        let anyTime = TimePreset(label: "Any time", expression: nil)
        func preset(_ expression: TimeExpression, _ label: String? = nil) -> TimePreset {
            TimePreset(label: label ?? expression.phrase(locale: context.locale).capitalizedFirst, expression: expression)
        }
        /// The year before `year` and, when it has begun, the year after.
        func neighbours(_ year: Int, _ make: (Int) -> TimeExpression, label: ((Int) -> String)? = nil) -> [TimePreset] {
            var found = [preset(make(year - 1), label?(year - 1))]
            if hasBegun(make(year + 1)) { found.append(preset(make(year + 1), label?(year + 1))) }
            return found
        }
        switch expression {
        case .season(let season, .every):
            return [preset(.season(season, .last)), anyTime]
        case .season(let season, let qualifier):
            guard let year = seasonYear(season, qualifier) else { return [anyTime] }
            return neighbours(year) { .season(season, .year($0)) } + [preset(.season(season, .every)), anyTime]
        case .month(let month, .every):
            return [preset(.month(month, .last)), anyTime]
        case .month(let month, let qualifier):
            let year = switch qualifier {
            case .year(let named): named
            case .last: month < now.month ? now.year : now.year - 1
            default: now.year
            }
            return neighbours(year) { .month(month, .year($0)) } + [preset(.month(month, .every)), anyTime]
        case .hijri(let event, .every, nil):
            return [preset(.hijri(event, .last, hijriYear: nil))]
        case .hijri(let event, _, let hijriYear?):
            let name = TimeResolver.hijriName(event)
            return [preset(.hijri(event, .every, hijriYear: hijriYear - 1), "\(name) \(hijriYear - 1)"),
                    preset(.hijri(event, .every, hijriYear: nil), "Every \(name)")]
        case .hijri(let event, let qualifier, nil):
            let every = preset(.hijri(event, .every, hijriYear: nil), "Every \(TimeResolver.hijriName(event))")
            guard let first = hijriOccurrences(event, qualifier, hijriYear: nil).first else { return [every] }
            return neighbours(LocalTime.civil(day: first.first).year) { .hijri(event, .year($0), hijriYear: nil) } + [every]
        case .holiday(let holiday, .every):
            return holidayRange(holiday, year: now.year) == nil ? [] : [preset(.holiday(holiday, .last))]
        case .holiday(let holiday, _):
            guard holidayRange(holiday, year: now.year) != nil else { return [] }
            let every = preset(.holiday(holiday, .every), "Every \(TimeResolver.holidayName(holiday))")
            guard let start = resolvePart(expression).ranges?.first?.lowerBound else { return [every] }
            return neighbours(LocalTime.civil(day: LocalTime.momentDay(wallSeconds: start)).year) { .holiday(holiday, .year($0)) } + [every]
        case .ago(.year, let count, false) where count > 0:
            var found = [preset(.ago(.year, count: count, onThisDay: true), "On this day in \(now.year - count)")]
            if count > 1 { found.append(preset(.ago(.year, count: count - 1, onThisDay: false))) }
            return found
        case .ago(.year, let count, true) where count > 0:
            var found = [preset(.ago(.year, count: count, onThisDay: false), "All of \(now.year - count)")]
            if count > 1 { found.append(preset(.ago(.year, count: count - 1, onThisDay: true))) }
            return found
        case .weekday(let weekday, .last), .weekday(let weekday, .this):
            return [preset(.weekday(weekday, .every))]
        case .weekday(let weekday, _):
            return [preset(.weekday(weekday, .last))]
        case .weekend(.last), .weekend(.this):
            return [preset(.weekend(.every))]
        case .weekend:
            return [preset(.weekend(.last))]
        case .year(let year):
            // A standalone year reads back from 1990 on.
            return neighbours(year) { .year($0) }.filter { if case .year(let other)? = $0.expression { other >= 1990 } else { true } }
        case .date(_, let month, let year):
            let resolved = resolvePart(expression).ranges?.first.map { LocalTime.civil(day: LocalTime.momentDay(wallSeconds: $0.lowerBound)).year }
            return [preset(.month(month, .year(year ?? resolved ?? now.year)))]
        case .relativeDay(0):
            return [preset(.relativeDay(-1))]
        case .relativeDay(-1):
            return [preset(.relativeDay(0))]
        case .calendarUnit(let unit, 0) where unit != .day:
            return [preset(.calendarUnit(unit, offset: -1))]
        case .calendarUnit(let unit, -1) where unit != .day:
            return [preset(.calendarUnit(unit, offset: 0))]
        default:
            return []
        }
    }

    /// The year a season of `qualifier` is "of" (``seasonDays(_:year:)``): "last summer" in October 2026 is 2026.
    private func seasonYear(_ season: Season, _ qualifier: Qualifier) -> Int? {
        if case .year(let named) = qualifier { return named }
        guard let days = seasonDays(season, qualifier) else { return nil }
        let year = todayDate.year
        return (year - 2...year + 2).first { seasonDays(season, year: $0) == days }
    }

    /// Whether the expression's dates have started by today (a later year is offered only then).
    private func hasBegun(_ expression: TimeExpression) -> Bool {
        guard let ranges = resolvePart(expression).ranges, let start = ranges.map(\.lowerBound).min() else { return false }
        return start < Self.start(today + 1)
    }
}

// MARK: Part of the day and days

extension TimeExpression {
    /// The part of the day the expression names, alone or with a date ("Saturday evening").
    public var partOfDay: PartOfDay? {
        switch self {
        case .partOfDay(let part): part
        case .all(let parts): parts.lazy.compactMap { if case .partOfDay(let part) = $0 { part } else { nil } }.last
        default: nil
        }
    }

    /// The expression with its part of the day replaced (nil removes it); nil when nothing would be left.
    public func with(partOfDay part: PartOfDay?) -> TimeExpression? {
        var parts: [TimeExpression] = if case .all(let all) = self { all } else { [self] }
        parts.removeAll { if case .partOfDay = $0 { true } else { false } }
        if let part { parts.append(.partOfDay(part)) }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return .all(parts)
        }
    }
}

extension TimeConstraint {
    /// The first and last days its ranges cover (moment days, ``LocalTime``), nil without a finite range: the custom
    /// dates the time editor starts from.
    public var days: ClosedRange<Int32>? {
        let finite = (ranges ?? []).filter { $0.lowerBound > TimeResolver.openStart && $0.upperBound < TimeResolver.openEnd }
        guard let lower = finite.map(\.lowerBound).min(), let upper = finite.map(\.upperBound).max(), lower < upper else { return nil }
        let first = LocalTime.momentDay(wallSeconds: lower), last = LocalTime.momentDay(wallSeconds: upper - 1)
        return first <= last ? first...last : nil
    }
}
