import Foundation
import LZGeo

/// The time grammar of ``RulesQueryParser`` (search spec §6.3): Hijri events and holidays, ranges, and times.
extension RuleScan {
    // MARK: 2. Hijri events and holidays

    mutating func hijriAndHolidays() {
        var index = 0
        while index < tokens.count {
            guard let first = word(index) else {
                index += 1
                continue
            }
            var qualifier = Qualifier.every
            var start = index
            switch first {
            case "last": qualifier = .last; start += 1
            case "this": qualifier = .this; start += 1
            case "every", "each": start += 1
            default: break
            }
            if let (event, length) = longest(lexicon.hijri, at: start) {
                var end = start + length
                var hijriYear: Int?
                if let (year, next) = yearSuffix(at: end, hijri: true) {
                    if (1300...1600).contains(year) { hijriYear = year } else { qualifier = .year(year) }
                    end = next
                }
                add(.time(.hijri(event, qualifier, hijriYear: hijriYear)), first: index, last: end - 1, claimed: index..<end)
                index = end
            } else if let (holiday, length) = longest(lexicon.holidays, at: start) {
                var end = start + length
                if let (year, next) = yearSuffix(at: end, hijri: false) {
                    qualifier = .year(year)
                    end = next
                }
                add(.time(.holiday(holiday, qualifier)), first: index, last: end - 1, claimed: index..<end)
                index = end
            } else {
                index += 1
            }
        }
    }

    /// A year right after an event: "2024", "in 2024", "of 2024", or a Hijri year "1445" ("1445 AH").
    private func yearSuffix(at index: Int, hijri: Bool) -> (Int, Int)? {
        var position = index
        if let word = word(position), ["in", "of"].contains(word) { position += 1 }
        if let year = attachedYear(at: position) { return (year, position + 1) }
        if hijri, let token = word(position), token.count == 4, let year = Int(token), (1300...1600).contains(year) {
            return (year, word(position + 1) == "ah" ? position + 2 : position + 1)
        }
        return nil
    }

    // MARK: 3. Ranges

    mutating func timeRanges() {
        var index = 0
        while index < tokens.count {
            guard let first = word(index) else {
                index += 1
                continue
            }
            switch first {
            case "between", "from":
                guard let (from, fromEnd) = time(at: index + 1, inRange: true) else { break }
                var second: Int?
                if let connector = word(fromEnd), ["and", "to", "until", "till", "through", "thru"].contains(connector) {
                    second = fromEnd + 1
                } else if fromEnd < tokens.count, tokens[fromEnd].gap.contains(where: { "-–—".contains($0) }) {
                    second = fromEnd
                }
                guard let second, let (to, end) = time(at: second, inRange: true) else { break }
                let (start, finish) = Self.sharingYear(from, to)
                add(.time(.range(from: start, to: finish)), first: index, last: end - 1, claimed: index..<end)
                index = end
                continue
            case "since", "after":
                guard let (from, end) = time(at: index + 1, inRange: true) else { break }
                add(.time(.range(from: from, to: nil)), first: index, last: end - 1, claimed: index..<end)
                index = end
                continue
            case "before", "until", "till":
                guard let (to, end) = time(at: index + 1, inRange: true) else { break }
                add(.time(.range(from: nil, to: to)), first: index, last: end - 1, claimed: index..<end)
                index = end
                continue
            default:
                break
            }
            index += 1
        }
    }

    /// "between March and May 2024": a month or date without a year takes the other end's year (the year before when
    /// it would come after the end).
    static func sharingYear(_ from: TimeExpression, _ to: TimeExpression) -> (TimeExpression, TimeExpression) {
        switch (from, to) {
        case (.month(let first, .every), .month(let last, .year(let year))):
            return (.month(first, .year(first <= last ? year : year - 1)), to)
        case (.date(let day, let month, nil), .date(let lastDay, let lastMonth, let year?)):
            let earlier = (month, day) <= (lastMonth, lastDay)
            return (.date(day: day, month: month, year: earlier ? year : year - 1), to)
        case (.month(let first, .every), .date(_, let lastMonth, let year?)):
            return (.month(first, .year(first <= lastMonth ? year : year - 1)), to)
        default:
            return (from, to)
        }
    }

    // MARK: 4. Times

    mutating func times() {
        var index = 0
        while index < tokens.count {
            guard isFree(index), let (expression, spanStart, end) = timeWithPreposition(at: index, inRange: false) else {
                index += 1
                continue
            }
            add(.time(expression), first: spanStart, last: end - 1, claimed: index..<end)
            index = end
        }
    }

    /// A time at `index`, after an optional preposition ("in", "on", "during", "from", "of", "at" for parts of the
    /// day) and "the". Returns where its own words start (the span leaves the preposition out) and the end.
    func timeWithPreposition(at index: Int, inRange: Bool) -> (TimeExpression, Int, Int)? {
        var best: (TimeExpression, Int, Int)?
        if let (expression, end) = core(at: index, preposition: nil, inRange: inRange) { best = (expression, index, end) }
        if let preposition = word(index), lexicon.timePrepositions.contains(preposition) {
            var start = index + 1
            if word(start) == "the" { start += 1 }
            if let (expression, end) = core(at: start, preposition: preposition, inRange: inRange), end > (best?.2 ?? index),
               preposition != "at" || Self.isPartOfDay(expression) {
                best = (expression, start, end)
            }
        } else if word(index) == "the", let (expression, end) = core(at: index + 1, preposition: "the", inRange: inRange), end > (best?.2 ?? index) {
            best = (expression, index + 1, end)
        }
        return best
    }

    /// A time inside a range ("between March and May 2024"): the expression and its end.
    private func time(at index: Int, inRange: Bool) -> (TimeExpression, Int)? {
        timeWithPreposition(at: index, inRange: inRange).map { ($0.0, $0.2) }
    }

    private static func isPartOfDay(_ expression: TimeExpression) -> Bool {
        if case .partOfDay = expression { return true }
        return false
    }

    /// The longest time expression starting exactly at `index`.
    private func core(at index: Int, preposition: String?, inRange: Bool) -> (TimeExpression, Int)? {
        guard let first = word(index) else { return nil }
        var best: (TimeExpression, Int)?
        func consider(_ expression: TimeExpression, _ end: Int) {
            if end > (best?.1 ?? index) { best = (expression, end) }
        }
        let anchored = preposition != nil || inRange

        switch first {
        case "today": consider(.relativeDay(0), index + 1)
        case "yesterday": consider(.relativeDay(-1), index + 1)
        case "tonight": consider(.all([.relativeDay(0), .partOfDay(.tonight)]), index + 1)
        case "recently", "lately": consider(.rolling(.day, count: 30), index + 1)
        default: break
        }

        // this/last/previous/past week|month|year; past/last N units.
        if ["this", "last", "previous", "past"].contains(first) {
            if let next = word(index + 1), let unit = lexicon.units[next], unit != .day, !next.hasSuffix("s") {
                switch first {
                case "this": consider(.calendarUnit(unit, offset: 0), index + 2)
                case "past": consider(.rolling(unit, count: 1), index + 2)
                default: consider(.calendarUnit(unit, offset: -1), index + 2)
                }
            }
            if first == "past" || first == "last", let (count, next) = number(at: index + 1, article: false), let unit = unit(at: next) {
                consider(.rolling(unit, count: count), next + 1)
            }
        }

        // N units ago (today).
        if let (count, next) = number(at: index, article: true), let unit = unit(at: next), word(next + 1) == "ago" {
            if word(next + 2) == "today" {
                consider(.ago(unit, count: count, onThisDay: true), next + 3)
            } else {
                consider(.ago(unit, count: count, onThisDay: false), next + 2)
            }
        }

        // on this day (N years ago).
        if first == "on", word(index + 1) == "this", word(index + 2) == "day" {
            if let (count, next) = number(at: index + 3, article: true), unit(at: next) == .year, word(next + 1) == "ago" {
                consider(.ago(.year, count: count, onThisDay: true), next + 2)
            } else {
                consider(.ago(.year, count: 0, onThisDay: true), index + 3)
            }
        }

        // last night; this morning.
        if first == "last", word(index + 1) == "night" { consider(.all([.relativeDay(-1), .partOfDay(.night)]), index + 2) }
        if first == "this", let (part, end) = partOfDay(at: index + 1) { consider(.all([.relativeDay(0), .partOfDay(part)]), end) }

        // this/last/every season, weekday, weekend or month.
        if ["this", "last", "every", "each"].contains(first), let next = word(index + 1) {
            let qualifier: Qualifier = first == "this" ? .this : first == "last" ? .last : .every
            if let season = lexicon.seasons[next] { consider(.season(season, qualifier), index + 2) }
            if let weekday = lexicon.weekdays[next] ?? (qualifier == .every ? lexicon.weekdayPlurals[next] : nil) {
                if let (part, end) = partOfDay(at: index + 2) {
                    consider(.all([.weekday(weekday, qualifier), .partOfDay(part)]), end)
                } else {
                    consider(.weekday(weekday, qualifier), index + 2)
                }
            }
            if next == "weekend" || next == "weekends" { consider(.weekend(qualifier), index + 2) }
            if let month = lexicon.months[next] { consider(.month(month, qualifier), index + 2) }
        }

        // A year on its own.
        if let year = year(at: index) { consider(.year(year), index + 1) }

        // Months: MONTH YEAR · MONTH of YEAR · MONTH 'YY · MONTH DAY, YEAR · MONTH.
        if let month = lexicon.months[first] {
            if let year = attachedYear(at: index + 1) { consider(.month(month, .year(year)), index + 2) }
            if word(index + 1) == "of", let year = attachedYear(at: index + 2) { consider(.month(month, .year(year)), index + 3) }
            if let year = shortYear(at: index + 1) { consider(.month(month, .year(year)), index + 2) }
            if let day = dayNumber(at: index + 1) {
                if let year = attachedYear(at: index + 2) {
                    consider(.date(day: day, month: month, year: year), index + 3)
                } else {
                    consider(.date(day: day, month: month, year: nil), index + 2)
                }
            }
            if !lexicon.ambiguousMonths.contains(first) || preposition == "in" || preposition == "during" || inRange {
                consider(.month(month, .every), index + 1)
            }
        }

        // DAY (of) MONTH (YEAR).
        if let day = dayNumber(at: index) {
            let monthIndex = word(index + 1) == "of" ? index + 2 : index + 1
            if let monthWord = word(monthIndex), let month = lexicon.months[monthWord] {
                if let year = attachedYear(at: monthIndex + 1) {
                    consider(.date(day: day, month: month, year: year), monthIndex + 2)
                } else {
                    consider(.date(day: day, month: month, year: nil), monthIndex + 1)
                }
            }
        }

        // ISO 2024-03-02 and numeric dates in the region's order.
        if let date = numericDate(at: index) { consider(date.0, date.1) }

        // Seasons: SEASON YEAR · SEASON of YEAR · SEASON.
        if let season = lexicon.seasons[first] {
            if let year = attachedYear(at: index + 1) { consider(.season(season, .year(year)), index + 2) }
            if word(index + 1) == "of", let year = attachedYear(at: index + 2) { consider(.season(season, .year(year)), index + 3) }
            if !lexicon.ambiguousSeasons.contains(first) || anchored || preposition == "the" { consider(.season(season, .every), index + 1) }
        }

        // Weekdays: Saturdays · Saturday (evening).
        if let weekday = lexicon.weekdayPlurals[first] {
            if let (part, end) = partOfDay(at: index + 1) {
                consider(.all([.weekday(weekday, .every), .partOfDay(part)]), end)
            } else {
                consider(.weekday(weekday, .every), index + 1)
            }
        }
        if let weekday = lexicon.weekdays[first] {
            if let (part, end) = partOfDay(at: index + 1) {
                consider(.all([.weekday(weekday, .every), .partOfDay(part)]), end)
            } else if !lexicon.ambiguousWeekdays.contains(first) || preposition == "on" {
                consider(.weekday(weekday, .every), index + 1)
            }
        }

        switch first {
        case "weekend", "weekends": consider(.weekend(.every), index + 1)
        case "weekday", "weekdays", "workday", "workdays": consider(.workdays, index + 1)
        default: break
        }

        if let (part, end) = partOfDay(at: index) { consider(.partOfDay(part), end) }
        return best
    }

    // MARK: Pieces

    /// A part of the day: "evening", "late night", "late at night".
    private func partOfDay(at index: Int) -> (PartOfDay, Int)? {
        guard let first = word(index) else { return nil }
        if first == "late" {
            if word(index + 1) == "night" { return (.lateNight, index + 2) }
            if word(index + 1) == "at", word(index + 2) == "night" { return (.lateNight, index + 3) }
            return nil
        }
        return lexicon.partsOfDay[first].map { ($0, index + 1) }
    }

    /// A standalone year from 1990 to next year.
    func year(at index: Int) -> Int? {
        guard let year = attachedYear(at: index), (1990...context.currentYear + 1).contains(year) else { return nil }
        return year
    }

    /// A year after a month, season, date or event ("Ramadan 2030"): any from 1900 to 2100 (a future one is kept and
    /// reported).
    func attachedYear(at index: Int) -> Int? {
        guard let word = word(index), word.count == 4, let year = Int(word), (1900...2100).contains(year) else { return nil }
        return year
    }

    /// "'23" after a month: a two-digit year after an apostrophe.
    private func shortYear(at index: Int) -> Int? {
        guard let word = word(index), word.count == 2, let value = Int(word), tokens[index].gap.contains(where: { "'’‘".contains($0) }) else { return nil }
        let year = 2000 + value
        return year <= context.currentYear + 1 ? year : 1900 + value
    }

    /// A day of the month: 1–31 as digits or an ordinal ("14th").
    private func dayNumber(at index: Int) -> Int? {
        guard isFree(index), tokens[index].text.count <= 4, let value = tokens[index].digits, (1...31).contains(value),
              tokens[index].text.count <= 2 || !tokens[index].isNumeric else { return nil }
        return value
    }

    /// A count: digits, one–twenty, "a"/"an" (with `article`), "a couple of", "a few".
    private func number(at index: Int, article: Bool) -> (Int, Int)? {
        guard let first = word(index) else { return nil }
        if first == "a" || first == "an" {
            if word(index + 1) == "couple", word(index + 2) == "of" { return (2, index + 3) }
            if word(index + 1) == "couple" { return (2, index + 2) }
            if word(index + 1) == "few" { return (3, index + 2) }
            return article ? (1, index + 1) : nil
        }
        if first == "couple", word(index + 1) == "of" { return (2, index + 2) }
        if first == "few" { return (3, index + 1) }
        if let value = lexicon.numbers[first] { return (value, index + 1) }
        if tokens[index].isNumeric, first.count <= 3, let value = Int(first), value > 0 { return (value, index + 1) }
        return nil
    }

    private func unit(at index: Int) -> TimeUnit? {
        word(index).flatMap { lexicon.units[$0] }
    }

    /// 2024-03-02, or 2/3/2024 in the region's order (unambiguous when a part is above 12).
    private func numericDate(at index: Int) -> (TimeExpression, Int)? {
        guard index + 2 < tokens.count, isFree(index), isFree(index + 1), isFree(index + 2),
              tokens[index].isNumeric, tokens[index + 1].isNumeric, tokens[index + 2].isNumeric,
              let a = Int(tokens[index].text), let b = Int(tokens[index + 1].text), let c = Int(tokens[index + 2].text) else { return nil }
        let separator = tokens[index + 1].gap.trimmingCharacters(in: .whitespaces)
        guard ["-", "/", "."].contains(separator), tokens[index + 2].gap.trimmingCharacters(in: .whitespaces) == separator else { return nil }
        if tokens[index].text.count == 4 {
            guard (1...12).contains(b), (1...31).contains(c) else { return nil }
            return (.date(day: c, month: b, year: a), index + 3)
        }
        let year: Int
        switch tokens[index + 2].text.count {
        case 4: year = c
        case 2: year = 2000 + c <= context.currentYear + 1 ? 2000 + c : 1900 + c
        default: return nil
        }
        var monthFirst = LocalDateFormat.numericMonthComesFirst(context.locale)
        if a > 12 { monthFirst = false } else if b > 12 { monthFirst = true }
        let (day, month) = monthFirst ? (b, a) : (a, b)
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return (.date(day: day, month: month, year: year), index + 3)
    }
}
