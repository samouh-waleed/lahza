import Foundation
import LZGeo
import LZIndex

/// Says why a search found nothing and offers taps that widen it (search spec §6.8), from per-slot counts on the
/// snapshot: each slot alone, with the photo-type filter applied. Counts are Best matches, so a chip's number is what
/// is inside the place or the dates. An offer is shown only with a count above 0; widening is never automatic.
struct NoMatchBuilder {
    let snapshot: SearchSnapshot
    let query: PreparedQuery
    let copy: SearchCopy
    let context: EngineContext
    let index: SearchIndexContext

    /// Areas count their photos this many radii out for the "widen" offer.
    static let widenFactor = 5.0
    static let widenDays: Int32 = 14

    func build(reader: IndexReader) async throws -> NoMatch {
        let plan = query.plan
        if let failure = query.placeFailure { return placeNotFound(failure) }
        if plan.isEmpty {
            if let message = query.slots.first(where: { $0.slot.kind == .time && !$0.isSupported })?.chip {
                return NoMatch(kind: .nothing, headline: message, detail: "Try a date, like “last summer” or “Ramadan 2024”.", offers: [], examples: [])
            }
            return NoMatch(kind: .onlyUnsupported, headline: "Lahza can’t search what’s in photos yet. Try a place, a date or a photo type.", detail: nil,
                           offers: [], examples: [])
        }
        if let time = plan.time, time.isFuture {
            return NoMatch(kind: .future, headline: "That’s in the future.", detail: nil,
                           offers: offer("Any time", removing: query.timeSlots, plan: without(time: true)), examples: [])
        }
        if let stillReading = stillReading() { return stillReading }

        let placeCount = plan.place.map { _ in count(ScoringPlan(place: plan.place, media: plan.media)) }
        let timeCount = plan.time.map { _ in count(ScoringPlan(time: plan.time, media: plan.media)) }
        let eventCount = plan.event.map { _ in count(ScoringPlan(event: plan.event, media: plan.media)) }

        // Every slot-alone count includes the photo-type filter, so a filter that finds nothing is named first.
        if let media = plan.media, count(ScoringPlan(media: media)) == 0 { return mediaEmpty(media) }
        if placeCount == 0, let place = query.placeSlot { return try await placeEmpty(place, reader: reader) }
        if timeCount == 0, let time = query.timeExpression { return timeEmpty(time) }
        if eventCount == 0 {
            return NoMatch(kind: .nothing, headline: plan.event == .abroad ? "No trips abroad yet." : "No trips yet.",
                           detail: "Days away from home, two or more in a row, become trips.",
                           offers: offer("Not only trips", removing: query.eventSlot.map { [$0] } ?? [], plan: without(event: true)), examples: [])
        }
        if let place = query.placeSlot, let placeCount, let time = query.timeExpression, let timeCount {
            return combination(place: place, placeCount: placeCount, time: time, timeCount: timeCount)
        }
        var offers: [WideningOffer] = []
        if let place = query.placeSlot { offers += offer("Anywhere", removing: [place.id], plan: without(place: true)) }
        if !query.timeSlots.isEmpty { offers += offer("Any time", removing: query.timeSlots, plan: without(time: true)) }
        if let event = query.eventSlot { offers += offer("Not only trips", removing: [event], plan: without(event: true)) }
        return NoMatch(kind: .nothing, headline: "Nothing matches all of that.", detail: nil, offers: offers, examples: [])
    }

    // MARK: Counting

    /// Best matches of a plan.
    func count(_ plan: ScoringPlan) -> Int {
        var scorer = Scorer(snapshot: snapshot, plan: plan)
        return scorer.run().hits.count(where: { $0.tier == .best })
    }

    private func without(place: Bool = false, time: Bool = false, event: Bool = false) -> ScoringPlan {
        var plan = query.plan
        if place { plan.place = nil }
        if time { plan.time = nil }
        if event { plan.event = nil }
        return plan
    }

    /// An offer that removes slots, if what is left finds something.
    private func offer(_ label: String, removing slots: [Int], plan: ScoringPlan) -> [WideningOffer] {
        guard !slots.isEmpty, !plan.isEmpty else { return [] }
        let found = count(plan)
        return found > 0 ? [WideningOffer(label: label, count: found, edits: slots.map { .remove(slot: $0) })] : []
    }

    // MARK: Cases

    private func placeNotFound(_ failure: (id: Int, reason: PlaceNotFound, phrase: String)) -> NoMatch {
        let words = "“\(failure.phrase)”"
        let (headline, detail): (String, String?) = switch failure.reason {
        case .offline: ("Couldn’t look up \(words) offline.", "Places in your photos still work without internet.")
        case .mapsBusy: ("Couldn’t look up \(words) right now.", "Apple Maps is busy. Try again in a few minutes.")
        case .appleMapsOff: ("Couldn’t find \(words) in your photos.", "Apple Maps place names are off in Settings › Search index.")
        case .noHome: ("Lahza hasn’t worked out your home yet.", "Save it from a photo.")
        case .noPlacesOfCategory: ("Lahza hasn’t found \(words) among your places yet.", nil)
        case .notFound, .unconfirmed: ("Couldn’t find \(words) in your photos or on the map.", nil)
        }
        return NoMatch(kind: .placeNotFound(failure.reason), headline: headline, detail: detail,
                       offers: offer("Search without the place", removing: [failure.id], plan: query.plan), examples: [])
    }

    /// The first build hasn't reached the dates asked for.
    private func stillReading() -> NoMatch? {
        guard index.isPartial, let since = index.coveredSince, let ranges = query.plan.time?.ranges, let end = ranges.map(\.upperBound).max(),
              end <= LocalTime.wallSeconds(since, in: context.zone) else { return nil }
        return NoMatch(kind: .stillReading, headline: "Still reading your library: photos before \(copy.month(of: since, zone: context.zone)) aren’t searchable yet.",
                       detail: nil, offers: [], examples: [])
    }

    /// The place resolved but holds nothing: widen an area that has photos a little further out, else name the
    /// countries the photos are from.
    private func placeEmpty(_ place: (id: Int, candidate: PlaceCandidate, description: PlaceDescription, phrase: String), reader: IndexReader) async throws -> NoMatch {
        if case .area(let center, let radius, let category, let key) = place.candidate.resolved {
            let wider = radius * Self.widenFactor
            var plan = ScoringPlan(place: PlaceTarget(.area(center: center, radius: wider, category: category, placeKey: key)), media: query.plan.media)
            plan.time = query.plan.time
            plan.event = query.plan.event
            let found = count(plan)
            if found > 0 {
                return NoMatch(kind: .onlyBeyondRadius,
                               headline: "None within \(copy.distance(radius)) of \(place.description.name). \(found.formatted(.number.locale(copy.locale))) within \(copy.distance(wider)).",
                               detail: nil, offers: [WideningOffer(label: "Widen to \(copy.distance(wider))", count: found, edits: [.setRadius(slot: place.id, metres: wider)])],
                               examples: [])
            }
        }
        let countries = try await reader.places(kinds: [.country], minPhotos: 1, limit: 30)
        var offers: [WideningOffer] = []
        for country in countries {
            var plan = query.plan
            plan.place = PlaceTarget(.membership(level: .country, placeID: country.id, placeKey: country.key, center: nil))
            let found = count(plan)
            if found > 0 { offers.append(WideningOffer(label: country.name, count: found, edits: [.replacePlace(slot: place.id, placeKey: country.key, name: country.name)])) }
        }
        offers.sort { $0.count > $1.count }
        let detail: String? = switch countries.count {
        case 0: nil
        case 1: "Your photos are from \(countries[0].name)."
        default: "Your photos are from \(countries.count) countries."
        }
        let at = place.description.isArea ? "at" : "in"
        return NoMatch(kind: .placeEmpty, headline: "No photos \(at) \(place.description.fullName).", detail: detail, offers: Array(offers.prefix(8)), examples: [])
    }

    private func timeEmpty(_ time: TimeExpression) -> NoMatch {
        let name = copy.sentenceName(time)
        var detail: String?
        if let first = context.summary.firstYear, let ranges = query.plan.time?.ranges, let end = ranges.map(\.upperBound).max(),
           end <= Int64(LocalTime.day(year: first, month: 1, day: 1)) * 86_400 {
            detail = "Your library starts in \(first)."
        }
        var offers: [WideningOffer] = []
        if query.timeSlots.count == 1, let slot = query.timeSlots.first {
            if let every = Self.everyOccurrence(of: time) {
                offers += replacing(slot, with: every.expression, label: every.label)
            }
            if case .hijri(let event, let qualifier, let hijriYear) = time, let years = context.time.years {
                let asked: Int? = if case .year(let year) = qualifier { year } else { hijriYear.flatMap { Self.gregorianYear(of: event, hijriYear: $0) } }
                if let asked {
                    let candidates = years.sorted { abs($0 - asked) < abs($1 - asked) }
                    for year in candidates where year != asked {
                        let expression = TimeExpression.hijri(event, .year(year), hijriYear: nil)
                        let found = countReplacing(time: expression)
                        if found > 0 {
                            offers.append(WideningOffer(label: "Closest: \(TimeResolver.hijriName(event)) \(year)", count: found, edits: [.replaceTime(slot: slot, expression)]))
                            break
                        }
                    }
                }
            }
        }
        if offers.isEmpty { offers = offer("Any time", removing: query.timeSlots, plan: without(time: true)) }
        return NoMatch(kind: .timeEmpty, headline: "No photos from \(name).", detail: detail, offers: offers, examples: [])
    }

    private func mediaEmpty(_ media: MediaFilter) -> NoMatch {
        let (headline, detail): (String, String?) =
            if media.flags.contains(.selfie) { ("No selfies found.", "Lahza finds selfies from Apple Photos’ Selfies album.") }
            else if media.flags.contains(.favorite) { ("No favorites found.", "Lahza finds the photos you’ve marked as favorites in Apple Photos.") }
            else if media.flags.contains(.screenshot) { ("No screenshots found.", nil) }
            else if media.kinds == [.video] && media.flags.isEmpty { ("No videos found.", nil) }
            else { ("No \(media.phrase) found.", nil) }
        return NoMatch(kind: .mediaEmpty, headline: headline, detail: detail,
                       offers: offer("All photos", removing: query.mediaSlots, plan: { var plan = query.plan; plan.media = nil; return plan }()), examples: [])
    }

    /// "85 at Al-Nakheel Park, none during Ramadan 2024." with the nearest photo in time, and taps for the place at
    /// any time, the dates anywhere and the dates ±2 weeks.
    private func combination(place: (id: Int, candidate: PlaceCandidate, description: PlaceDescription, phrase: String), placeCount: Int,
                             time: TimeExpression, timeCount: Int) -> NoMatch {
        let name = copy.sentenceName(time)
        let headline = "\(placeCount.formatted(.number.locale(copy.locale))) \(place.description.phrase), none \(copy.preposition(time)) \(name)."
        var offers: [WideningOffer] = []
        if placeCount > 0 {
            offers.append(WideningOffer(label: "\(place.description.isHome ? "Home" : place.description.name), any time", count: placeCount,
                                        edits: query.timeSlots.map { .remove(slot: $0) }))
        }
        if timeCount > 0 { offers.append(WideningOffer(label: "\(name.capitalizedFirst), anywhere", count: timeCount, edits: [.remove(slot: place.id)])) }
        if let widened = widenedByTwoWeeks(), let slot = query.timeSlots.first {
            let found = countReplacing(time: widened)
            if found > 0 {
                offers.append(WideningOffer(label: "±2 weeks", count: found,
                                            edits: [.replaceTime(slot: slot, widened)] + query.timeSlots.dropFirst().map { .remove(slot: $0) }))
            }
        }
        return NoMatch(kind: .combination, headline: headline, detail: closest(time), offers: offers, examples: [])
    }

    /// "Closest: Sat 2 Mar 2024, 9 days before." — the photo of the place nearest the dates.
    private func closest(_ time: TimeExpression) -> String? {
        guard let constraint = query.plan.time, let ranges = constraint.ranges?.sorted(by: { $0.lowerBound < $1.lowerBound }), !ranges.isEmpty,
              let place = query.plan.place else { return nil }
        var scorer = Scorer(snapshot: snapshot, plan: ScoringPlan(place: place, media: query.plan.media))
        var best: (distance: Int64, day: Int32, edgeDay: Int32)?
        for hit in scorer.run().hits where hit.tier == .best {
            let i = Int(hit.index)
            guard snapshot.isDated(i), !snapshot.has(.dateUnreliable, i),
                  let miss = Scorer.distance(snapshot.wall[i], outside: ranges), let edge = miss.edge else { continue }
            if best.map({ miss.distance < $0.distance }) ?? true {
                let edgeDay = miss.after ? LocalTime.momentDay(wallSeconds: edge - 1) : Scorer.firstDay(of: edge)
                best = (miss.distance, snapshot.day[i], edgeDay)
            }
        }
        guard let best else { return nil }
        let days = Int(best.day - best.edgeDay)
        let gap = abs(days) == 1 ? "1 day" : "\(abs(days)) days"
        return "Closest: \(LocalDateFormat.dayTitle(best.day, locale: copy.locale)), \(gap) \(days < 0 ? "before" : "after")."
    }

    // MARK: Time offers

    /// The dates two weeks wider on each side, as an editable range.
    private func widenedByTwoWeeks() -> TimeExpression? {
        guard let ranges = query.plan.time?.ranges, let lower = ranges.map(\.lowerBound).min(), let upper = ranges.map(\.upperBound).max(),
              upper - lower < 400 * 86_400 else { return nil }
        let first = LocalTime.civil(day: Scorer.firstDay(of: lower) - Self.widenDays)
        let last = LocalTime.civil(day: LocalTime.momentDay(wallSeconds: upper - 1) + Self.widenDays)
        return .range(from: .date(day: first.day, month: first.month, year: first.year), to: .date(day: last.day, month: last.month, year: last.year))
    }

    private func countReplacing(time expression: TimeExpression) -> Int {
        guard let constraint = TimeResolver(context: context.time).resolve(expression).constraint else { return 0 }
        var plan = query.plan
        plan.time = constraint
        return count(plan)
    }

    private func replacing(_ slot: Int, with expression: TimeExpression, label: String) -> [WideningOffer] {
        let found = countReplacing(time: expression)
        return found > 0 ? [WideningOffer(label: label, count: found, edits: [.replaceTime(slot: slot, expression)])] : []
    }

    /// The Gregorian year an event of a Hijri year starts in ("Ramadan 1440" began in May 2019).
    static func gregorianYear(of event: HijriEvent, hijriYear: Int) -> Int? {
        HijriCalendar.occurrences(event, hijriYear: hijriYear).first.map { LocalTime.civil(day: $0.first).year }
    }

    /// "Every Ramadan" for "Ramadan 2019", "Every June" for "June 2019".
    static func everyOccurrence(of time: TimeExpression) -> (expression: TimeExpression, label: String)? {
        switch time {
        case .hijri(let event, let qualifier, let hijriYear) where qualifier != .every || hijriYear != nil:
            (.hijri(event, .every, hijriYear: nil), "Every \(TimeResolver.hijriName(event))")
        case .holiday(let holiday, let qualifier) where qualifier != .every:
            (.holiday(holiday, .every), "Every \(TimeResolver.holidayName(holiday))")
        case .month(let month, let qualifier) where qualifier != .every:
            (.month(month, .every), "Every \(TimeExpression.monthNames[min(max(1, month), 12) - 1])")
        case .season(let season, let qualifier) where qualifier != .every:
            (.season(season, .every), "Every \(season.rawValue)")
        default:
            nil
        }
    }
}
