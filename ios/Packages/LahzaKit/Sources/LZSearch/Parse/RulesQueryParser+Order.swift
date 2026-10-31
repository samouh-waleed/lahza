import Foundation

/// Which occasion or order a query asks for (``SearchOrder``), and "recently" next to named dates.
extension RuleScan {
    // MARK: Order

    /// "the first time", "my last trip", "oldest to newest", "over the years": after the times, so "last summer" and
    /// "the last Eid" stay dates, and before the places, so "in order" and "from oldest" never become one. "first" or
    /// "last" alone counts before a trip word ("first trip to Dubai").
    mutating func orders() {
        var index = 0
        while index < tokens.count {
            if let (order, length) = longest(lexicon.orders, at: index), standsAsOrder(ending: index + length - 1) {
                add(.order(order), first: index, last: index + length - 1, claimed: index..<index + length)
                index += length
            } else if let word = word(index), word == "first" || word == "last", let next = self.word(index + 1), lexicon.events[next] != nil,
                      !tokens[index + 1].followsPunctuation {
                add(.order(word == "first" ? .first : .last), first: index, last: index, claimed: index..<index + 1)
                index += 1
            } else {
                index += 1
            }
        }
    }

    /// Words after "the first" or "my last" that make it about dates or counting, not an occasion: "the first of
    /// June", "my first week", "the first two", "the last few".
    static let notOccasionWords: Set<String> = ["of", "few", "couple", "half", "quarter", "day", "days", "week", "weeks", "month", "months", "year",
                                                "years", "weekend", "weekends", "night", "nights"]

    /// A phrase ending in "first" or "last" ("my first") is an occasion only when the next word isn't about dates.
    private func standsAsOrder(ending last: Int) -> Bool {
        guard ["first", "last"].contains(tokens[last].text), let next = word(last + 1), !tokens[last + 1].followsPunctuation else { return true }
        if Self.notOccasionWords.contains(next) || lexicon.numbers[next] != nil || lexicon.months[next] != nil || lexicon.weekdays[next] != nil
            || lexicon.seasons[next] != nil || tokens[last + 1].isNumeric { return false }
        return true
    }

    // MARK: Recently

    /// "recently, in 2026": a vague "recently" (the past 30 days) gives way to dates the query names rather than
    /// narrowing them to the past month. Beside a recurring time ("recently on Saturdays") it still holds.
    mutating func recentlyYields() {
        let vague = found.indices.filter { index in
            guard case .time(.rolling(.day, count: 30)) = found[index].value, found[index].first == found[index].last else { return false }
            return ["recently", "lately"].contains(tokens[found[index].first].text)
        }
        guard !vague.isEmpty else { return }
        let named = found.indices.contains { index in
            guard !vague.contains(index), case .time(let expression) = found[index].value else { return false }
            return Self.namesDates(expression)
        }
        guard named else { return }
        found = found.indices.filter { !vague.contains($0) }.map { found[$0] }
    }

    /// Whether an expression names dates (a year, "last June", a range) rather than a recurring time ("Saturdays",
    /// "June", "evenings").
    static func namesDates(_ expression: TimeExpression) -> Bool {
        switch expression {
        case .year, .date, .relativeDay, .calendarUnit, .rolling, .ago, .range: true
        case .month(_, let qualifier), .season(_, let qualifier), .weekday(_, let qualifier), .weekend(let qualifier), .holiday(_, let qualifier):
            qualifier != .every
        case .hijri(_, let qualifier, let hijriYear): qualifier != .every || hijriYear != nil
        case .workdays, .partOfDay: false
        case .all(let parts): parts.contains(where: namesDates)
        }
    }
}
