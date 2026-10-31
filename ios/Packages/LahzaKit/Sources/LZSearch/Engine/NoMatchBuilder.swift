import Foundation
import LZGeo
import LZIndex

/// Says why a search found nothing and offers taps that widen it (search spec §6.8), from per-slot counts on the
/// snapshot: each slot alone, with the photo-type filter applied. Counts are Best matches, so a chip's number is what
/// is inside the place or the dates. An offer is shown only with a count above 0; widening is never automatic.
///
/// A free search (`since`): what it says about the library counts every year ("57 in Dubai"), so it never reads as if
/// the photos didn't exist; an offer counts what its tap shows, the photos since `since`, and goes at 0. An offer whose
/// matches are all older is kept (E19): its tap gives the all-older answer, so it counts what that answer's unlock row
/// counts.
struct NoMatchBuilder {
    let snapshot: SearchSnapshot
    let query: PreparedQuery
    let copy: SearchCopy
    let context: EngineContext
    let index: SearchIndexContext
    /// A free search's start (Unix seconds): offers count the photos taken since (and undated ones).
    var since: Int64?
    /// The photos of the related tags of visual slots searched without them (the "Include related tags" offer).
    var relatedPostings: [String: [LabelPosting]] = [:]
    /// The search shows its Weaker section, so an all-older offer's tap counts those as locked too.
    var showWeaker = false

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
            // "the first time" or "oldest first" alone: nothing to find the first of, or to order.
            if let order = query.orderSlot, query.unsupported.isEmpty {
                let example = order.order.isOccasion ? "the first time at the beach" : "the beach, oldest first"
                return NoMatch(kind: .nothing, headline: "Add a place, a date or a photo type, like “\(example)”.", detail: nil, offers: [], examples: [])
            }
            if snapshot.hasVisualPass {
                let words = copy.list(query.unsupported.filter { $0.slot.kind == .visual }.map { "“\($0.chip)”" })
                if !words.isEmpty {
                    return NoMatch(kind: .onlyUnsupported, headline: "Lahza has no photo tag for \(words) yet.",
                                   detail: "Try a place, a date, or what’s in a photo, like “beach” or “sunset”.", offers: [], examples: [])
                }
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
        for target in plan.visual where count(ScoringPlan(media: plan.media, visual: [target])) == 0 {
            return notTagged(target)
        }
        if let place = query.placeSlot, let placeCount, let time = query.timeExpression, timeCount != nil {
            return combination(place: place, placeCount: placeCount, time: time)
        }
        var offers: [WideningOffer] = []
        if let place = query.placeSlot { offers += offer("Anywhere", removing: [place.id] + otherPlaceSlots, plan: without(place: true)) }
        if !query.timeSlots.isEmpty { offers += offer("Any time", removing: query.timeSlots, plan: without(time: true)) }
        if let event = query.eventSlot { offers += offer("Not only trips", removing: [event], plan: without(event: true)) }
        for target in plan.visual {
            offers += offer("Without “\(target.concept.name)”", removing: [target.slot], plan: without(visual: target.slot))
        }
        return NoMatch(kind: .nothing, headline: "Nothing matches all of that.", detail: nil, offers: offers, examples: [])
    }

    // MARK: Counting

    /// Best matches of a plan in the whole library (what a headline says).
    func count(_ plan: ScoringPlan) -> Int {
        var scorer = Scorer(snapshot: snapshot, plan: plan)
        return scorer.run().hits.count(where: { $0.tier == .best })
    }

    /// What an offer of a plan counts, 0 to leave it out: the Best matches its tap shows (the whole library, or a free
    /// search's photos since its start). While free, a plan with no match since the start but older ones is the
    /// all-older answer, "No matches in the last 12 months." with "N more from earlier years": it counts that row's N,
    /// as the search engine counts it (every older hit it would list).
    func shown(_ plan: ScoringPlan) -> Int { reach(plan).count }

    /// What an offer's tap shows: `count` as ``shown(_:)`` counts it, and whether those are all older than a free
    /// search's start (the tap shows the unlock row, no photos).
    func reach(_ plan: ScoringPlan) -> (count: Int, olderOnly: Bool) {
        guard let since else { return (count(plan), false) }
        var scorer = Scorer(snapshot: snapshot, plan: plan)
        var best = 0, recent = 0, older = 0, locked = 0
        for hit in scorer.run().hits {
            let i = Int(hit.index)
            let matches = hit.tier == .best || hit.tier == .more
            if !snapshot.isDated(i) || snapshot.utc[i] >= since {
                if hit.tier == .best { best += 1 }
                if matches { recent += 1 }
            } else {
                if matches { older += 1 }
                if hit.tier != .weaker || showWeaker { locked += 1 }
            }
        }
        if best > 0 { return (best, false) }
        return recent == 0 && older > 0 ? (locked, true) : (0, false)
    }

    private func without(place: Bool = false, time: Bool = false, event: Bool = false, visual slot: Int? = nil) -> ScoringPlan {
        var plan = query.plan
        if place { plan.place = nil }
        if time { plan.time = nil }
        if event { plan.event = nil }
        if let slot { plan.visual.removeAll { $0.slot == slot } }
        return plan
    }

    /// The place slots other than the one searched (or failing): left out, they would be the place on a re-run, so an
    /// offer that removes the place removes them too ("December 2025, anywhere" for "Dubai near my house last
    /// December" searches no place, as it counted).
    private var otherPlaceSlots: [Int] {
        query.parsed.slots.compactMap { slot in
            guard case .place = slot.value, slot.id != query.placeSlot?.id, slot.id != query.placeFailure?.id else { return nil }
            return slot.id
        }
    }

    /// An offer that removes slots, if what is left finds something.
    private func offer(_ label: String, removing slots: [Int], plan: ScoringPlan) -> [WideningOffer] {
        guard !slots.isEmpty, !plan.isEmpty else { return [] }
        let found = shown(plan)
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
        case .choseNoHome: ("You chose No home.", "Choose one in Settings › Saved places.")
        case .notSaved: ("You have no saved place called \(words).", "Save one from a moment.")
        case .noPlacesOfCategory: ("Lahza hasn’t found \(words) among your places yet.", nil)
        case .notFound, .unconfirmed: ("Couldn’t find \(words) in your photos or on the map.", nil)
        }
        return NoMatch(kind: .placeNotFound(failure.reason), headline: headline, detail: detail,
                       offers: offer("Search without the place", removing: [failure.id] + otherPlaceSlots, plan: query.plan), examples: [])
    }

    /// No checked photo has the concept's own tags: "No photos tagged scuba diving among 1,204 checked." While photos
    /// are still being checked the detail says how far it has got (E25); with the related tags removed, a tap brings
    /// them back when they find something. Before any photo is checked it says Lahza is still looking.
    private func notTagged(_ target: VisualTarget) -> NoMatch {
        let (checked, _) = snapshot.visualCounts
        let progress = copy.visualLine(checked: checked, total: snapshot.count).map { $0 + "." }
        guard checked > 0 else {
            return NoMatch(kind: .notTagged, headline: "Lahza is still checking what’s in your photos.",
                           detail: (progress.map { $0 + " " } ?? "") + "It looks while Lahza is open.", offers: [], examples: [])
        }
        var offers: [WideningOffer] = []
        if target.related.isEmpty, !target.concept.related.isEmpty {
            var plan = query.plan
            let index = plan.visual.firstIndex { $0.slot == target.slot }
            if let index {
                plan.visual[index] = VisualTarget(slot: target.slot, concept: target.concept, related: target.concept.related, postings: relatedPostings,
                                                  snapshot: snapshot)
                // Related tags only ever reach More: the tap's count is its More (photos a free search covers).
                var scorer = Scorer(snapshot: snapshot, plan: plan)
                let found = scorer.run().hits.count { hit in
                    let i = Int(hit.index)
                    return hit.tier <= .more && (since.map { !snapshot.isDated(i) || snapshot.utc[i] >= $0 } ?? true)
                }
                if found > 0 { offers.append(WideningOffer(label: "Include related tags", count: found, edits: [.setRelatedTags(slot: target.slot, true)])) }
            }
        }
        if plan(withoutSlot: target.slot).scoredSlots > 0 {
            offers += offer("Without “\(target.concept.name)”", removing: [target.slot], plan: plan(withoutSlot: target.slot))
        }
        return NoMatch(kind: .notTagged, headline: "No photos tagged \(target.concept.name) among \(checked.formatted(.number.locale(copy.locale))) checked.",
                       detail: progress, offers: offers, examples: [])
    }

    private func plan(withoutSlot slot: Int) -> ScoringPlan { without(visual: slot) }

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
                let visible = shown(plan)
                return NoMatch(kind: .onlyBeyondRadius,
                               headline: "None within \(copy.distance(radius)) of \(place.description.name). \(found.formatted(.number.locale(copy.locale))) within \(copy.distance(wider)).",
                               detail: nil,
                               offers: visible > 0 ? [WideningOffer(label: "Widen to \(copy.distance(wider))", count: visible, edits: [.setRadius(slot: place.id, metres: wider)])] : [],
                               examples: [])
            }
        }
        let countries = try await reader.places(kinds: [.country], minPhotos: 1, limit: 30)
        var offers: [(offer: WideningOffer, olderOnly: Bool)] = []
        for country in countries {
            var plan = query.plan
            plan.place = PlaceTarget(.membership(level: .country, placeID: country.id, placeKey: country.key, center: nil))
            let found = reach(plan)
            if found.count > 0 {
                offers.append((WideningOffer(label: country.name, count: found.count, edits: [.replacePlace(slot: place.id, placeKey: country.key, name: country.name)]),
                               found.olderOnly))
            }
        }
        let detail: String? = switch countries.count {
        case 0: nil
        case 1: "Your photos are from \(countries[0].name)."
        default: "Your photos are from \(countries.count) countries."
        }
        let at = place.description.isArea ? "at" : "in"
        return NoMatch(kind: .placeEmpty, headline: "No photos \(at) \(place.description.fullName).", detail: detail,
                       offers: Self.countryOffers(offers), examples: [])
    }

    static let maxCountryOffers = 8

    /// The most photos first, at most 8. While free, countries whose photos the tap shows come before those whose
    /// photos are all older (E19): those never push one that shows photos out.
    static func countryOffers(_ offers: [(offer: WideningOffer, olderOnly: Bool)]) -> [WideningOffer] {
        let kept = offers.filter { !$0.olderOnly }.map(\.offer).sorted { $0.count > $1.count }
            + offers.filter(\.olderOnly).map(\.offer).sorted { $0.count > $1.count }
        return kept.prefix(maxCountryOffers).sorted { $0.count > $1.count }
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
                             time: TimeExpression) -> NoMatch {
        let name = copy.sentenceName(time)
        let headline = "\(placeCount.formatted(.number.locale(copy.locale))) \(place.description.phrase), none \(copy.preposition(time)) \(name)."
        var offers: [WideningOffer] = []
        // Each counts the search its tap runs: the event, if any, stays ("Dubai trips last December"), and "anywhere"
        // drops every place word.
        let placeShown = shown(without(time: true))
        let timeShown = shown(without(place: true))
        if placeShown > 0 {
            offers.append(WideningOffer(label: "\(place.description.isHome ? "Home" : place.description.name), any time", count: placeShown,
                                        edits: query.timeSlots.map { .remove(slot: $0) }))
        }
        if timeShown > 0 {
            offers.append(WideningOffer(label: "\(name.capitalizedFirst), anywhere", count: timeShown,
                                        edits: ([place.id] + otherPlaceSlots).map { .remove(slot: $0) }))
        }
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
        return shown(plan)
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
