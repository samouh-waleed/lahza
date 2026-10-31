#if DEBUG
import Foundation
import LZGeo
import LZIndex
import LZLibrary

/// The search goldens of the hero seed (search spec §9.3), one definition for two harnesses: the kit tests over the
/// fake library and `make verify-search` over the seeded Simulator's real PhotoKit (search spec S24).
///
/// Every expectation is computed from the scenario's predicates (tags, local dates, positions, trips, Umm al-Qura
/// windows, and the photo tags ``SeedLabels`` gives the seed, which both harnesses tag it with), never from engine output. Best is asserted exactly; More as must-include ⊆ More ⊆ allowed (items whose
/// fuzzed score can reach 0.5). Photos map back to seed items by their capture second, so items that aren't in the
/// seed (the Simulator's own samples) are ignored. Dates in expected copy are written with the UK region, as the spec
/// writes them. Cases (or parts) that depend on a fact the library under test didn't keep are skipped: see ``Facts``.
public enum HeroSuite {
    /// 2026-10-28T12:00+03:00.
    public static let now = Date(timeIntervalSince1970: 1_793_178_000)
    /// A free search's start: 12 months before `now`.
    public static let freeSince = Date(timeIntervalSince1970: 1_761_642_000)
    public static let locale = Locale(identifier: "en_GB")

    /// What the library under test kept of the seed.
    public struct Facts: Sendable, Hashable {
        /// Received photos look received (PhotoKit import resets the added date, so the shape rule can't match).
        public var receivedPhotos: Bool
        /// Screenshots carry PhotoKit's screenshot subtype.
        public var screenshotSubtype: Bool
        /// Front-camera photos are in the Selfies album.
        public var selfiesAlbum: Bool
        /// The library holds the seed and nothing else (the Simulator adds its own samples).
        public var onlySeed: Bool

        public init(receivedPhotos: Bool, screenshotSubtype: Bool, selfiesAlbum: Bool, onlySeed: Bool) {
            self.receivedPhotos = receivedPhotos
            self.screenshotSubtype = screenshotSubtype
            self.selfiesAlbum = selfiesAlbum
            self.onlySeed = onlySeed
        }

        /// The fake reader keeps everything, and holds nothing else.
        public static let fake = Facts(receivedPhotos: true, screenshotSubtype: true, selfiesAlbum: true, onlySeed: true)

        /// What PhotoKit keeps, as the probe recorded it.
        public static func photoKit(_ capabilities: SeedCapabilities) -> Facts {
            Facts(receivedPhotos: !capabilities.addedDateIsImportTime, screenshotSubtype: capabilities.screenshotSubtype,
                  selfiesAlbum: capabilities.selfiesAlbum, onlySeed: false)
        }
    }

    /// One golden's outcome, with set precision, recall and F1 of Best ∪ More against Best ∪ must-include.
    public struct Outcome: Sendable, CustomStringConvertible {
        public var number: Int
        public var query: String
        /// Why it didn't run (a fact the library didn't keep).
        public var skipped: String?
        public var failures: [String]
        public var precision: Double
        public var recall: Double

        public var passed: Bool { failures.isEmpty }
        public var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }

        public var description: String {
            if let skipped { return "#\(number) “\(query)”: skipped (\(skipped))" }
            let scores = String(format: "P %.2f R %.2f F1 %.2f", precision, recall, f1)
            return "#\(number) “\(query)”: \(passed ? "pass" : "FAIL") \(scores)" + (failures.isEmpty ? "" : " — " + failures.joined(separator: "; "))
        }
    }

    /// Runs every golden in order over the hero index behind `reader` (place names already fetched with the seed's
    /// fake Apple Maps). `mapsSearches` counts the Apple Maps searches made so far.
    public static func run(engine: SearchEngine, reader: IndexReader, writer: UserDataWriter?, facts: Facts,
                           mapsSearches: @escaping @Sendable () -> Int) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for golden in Golden.all(facts) {
            var outcome = Outcome(number: golden.number, query: golden.query, skipped: golden.skip, failures: [], precision: 1, recall: 1)
            if golden.skip == nil {
                let before = mapsSearches()
                let result = try await engine.search(SearchRequest(text: golden.query, scope: golden.scope), reader: reader, writer: writer)
                outcome = golden.expectation.evaluate(result, number: golden.number, query: golden.query, searches: mapsSearches() - before)
                if let followUp = golden.followUp, let request = followUp.request(result) {
                    let next = try await engine.search(request, reader: reader, writer: writer)
                    let second = followUp.expectation.evaluate(next, number: golden.number, query: golden.query, searches: 0)
                    outcome.failures += second.failures.map { "after the pick: \($0)" }
                } else if golden.followUp != nil {
                    outcome.failures.append("no picker to choose from")
                }
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    // MARK: Expectations

    struct Expectation {
        /// Exactly these seed items in Best (nil: not checked).
        var best: [SeedItem]?
        var moreMust: [SeedItem] = []
        /// Allowed in More besides `moreMust`.
        var moreAllowed: [SeedItem] = []
        /// Exactly these under Location unknown (nil: not checked).
        var locationUnknown: [SeedItem]?
        /// At most this many Apple Maps searches.
        var maxSearches: Int?
        var checks: [@Sendable (SearchResult) -> String?] = []

        func evaluate(_ result: SearchResult, number: Int, query: String, searches: Int) -> Outcome {
            var failures: [String] = []
            var tiers: [Tier: Set<Int>] = [:]
            for hit in result.hits {
                guard let utc = hit.utc, let item = SeedScenario.hero.item(matchingUTC: utc) else { continue }
                tiers[hit.tier, default: []].insert(item.number)
            }
            let best = tiers[.best] ?? [], more = tiers[.more] ?? [], unknown = tiers[.locationUnknown] ?? []
            if let expected = self.best.map(numbers) {
                if best != expected { failures.append("Best \(Self.difference(best, expected))") }
            }
            let must = numbers(moreMust)
            if !must.isSubset(of: more) { failures.append("More misses \(Self.describe(must.subtracting(more)))") }
            let allowed = must.union(numbers(moreAllowed))
            if !more.isSubset(of: allowed) { failures.append("More has unexpected \(Self.describe(more.subtracting(allowed)))") }
            if let expected = locationUnknown.map(numbers), unknown != expected { failures.append("Location unknown \(Self.difference(unknown, expected))") }
            if let maxSearches, searches > maxSearches { failures.append("\(searches) Apple Maps searches (at most \(maxSearches))") }
            failures += checks.compactMap { $0(result) }

            let got = best.union(more), wanted = (self.best.map(numbers) ?? best).union(must)
            let hits = Double(got.intersection(wanted).count)
            return Outcome(number: number, query: query, skipped: nil, failures: failures, precision: got.isEmpty ? (wanted.isEmpty ? 1 : 0) : hits / Double(got.count),
                           recall: wanted.isEmpty ? 1 : hits / Double(wanted.count))
        }

        private func numbers(_ items: [SeedItem]) -> Set<Int> { Set(items.map(\.number)) }

        static func describe(_ numbers: Set<Int>) -> String {
            let items = numbers.sorted().compactMap { SeedScenario.hero.items.indices.contains($0 - 1) ? SeedScenario.hero.items[$0 - 1] : nil }
            var tags: [String: Int] = [:]
            for item in items { tags[item.tag.rawValue, default: 0] += 1 }
            return "\(numbers.count) [" + tags.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "]"
        }

        static func difference(_ got: Set<Int>, _ expected: Set<Int>) -> String {
            "missing \(describe(expected.subtracting(got))), extra \(describe(got.subtracting(expected)))"
        }
    }

    struct FollowUp {
        var request: @Sendable (SearchResult) -> SearchRequest?
        var expectation: Expectation
    }

    struct Golden {
        var number: Int
        var query: String
        /// The whole library, or a free search's months.
        var scope: SearchScope
        var skip: String?
        var expectation: Expectation
        var followUp: FollowUp?

        init(_ number: Int, _ query: String, scope: SearchScope = .wholeLibrary, skip: String? = nil, _ expectation: Expectation,
             followUp: FollowUp? = nil) {
            self.number = number
            self.query = query
            self.scope = scope
            self.skip = skip
            self.expectation = expectation
            self.followUp = followUp
        }
    }
}

// MARK: The goldens

extension HeroSuite.Golden {
    typealias Expectation = HeroSuite.Expectation
    typealias Tag = SeedScenario.Tag

    static func all(_ facts: HeroSuite.Facts) -> [HeroSuite.Golden] {
        let p = Predicates(facts: facts)
        let nakheel = p.tagged(.nakheel)
        let receivedOnNakheelDays = p.received.filter { item in nakheel.contains { $0.momentDay == item.momentDay } }
        let summer2026 = p.days(2026, 6, 1, through: 2026, 8, 31)
        let summer2026Dates = p.window(2026, 6, 1, through: 2026, 8, 31)
        let dates2023 = p.window(2023, 1, 1, through: 2023, 12, 31)
        let dates2025 = p.window(2025, 1, 1, through: 2025, 12, 31)
        let newYearsEve = p.wall(2021, 12, 31, 18, 0)..<p.wall(2022, 1, 1, 4, 0)
        let ramadan1445 = p.hijriWindow(1445, .ramadan)
        let dubai = p.tagged(.dubai1, .dubai2).filter(\.isLocated)
        let salamDubai = p.tagged(.dubai1).filter { $0.title == SeedPlace.salamParkDubai.name && $0.isLocated }
        let greeceTrip = SeedScenario.hero.trips.first { $0.name == "Greece" }!
        let dubaiTrip = SeedScenario.hero.trips.last { $0.name == "Dubai" }!
        let firstDubaiTrip = SeedScenario.hero.trips.first { $0.name == "Dubai" }!
        let year2025 = p.days(2025, 1, 1, through: 2025, 12, 31)
        // The park's visits, by moment day: the first and the last.
        let nakheelDays = Set(nakheel.compactMap(\.momentDay))
        let firstVisit = nakheel.filter { $0.momentDay == nakheelDays.min() }
        let lastVisit = nakheel.filter { $0.momentDay == nakheelDays.max() }
        let freeStart = Int64(HeroSuite.freeSince.timeIntervalSince1970)
        // Photo tags (content search Milestone A).
        let soccer = p.tagTiers("soccer"), hike = p.tagTiers("hike"), sunset = p.tagTiers("sunset"), beach = p.tagTiers("beach")
        let receipts = p.tagTiers("receipts"), passport = p.tagTiers("passport"), camping = p.tagTiers("camping"), fireworks = p.tagTiers("fireworks")
        let soccerAtNakheel = nakheel.filter(soccer.best.contains)
        let soccerReceived = receivedOnNakheelDays.filter { soccer.best.contains($0) || soccer.more.contains($0) }
        let london = p.tagged(.london).filter(\.isLocated)

        return [
            Self(1, "Al-Nakheel Park", Expectation(
                best: nakheel, moreMust: receivedOnNakheelDays, moreAllowed: p.received, maxSearches: 0,
                checks: [p.chips(["Al-Nakheel Park"]), p.noPicker, p.cards(.best, 10),
                         p.reason("Location from the same outing", on: nakheel.filter { !$0.isLocated }),
                         p.reason("Saved the day of your Al-Nakheel Park visit", on: receivedOnNakheelDays)])),
            Self(2, "videos at Al-Nakheel Park", Expectation(best: nakheel.filter(\.isVideo))),
            Self(3, "soccer at Al-Nakheel Park", Expectation(
                best: soccerAtNakheel, moreMust: nakheel.filter(soccer.more.contains) + soccerReceived,
                checks: [p.chips(["soccer · photo tag", "Al-Nakheel Park"]), p.noNotice, p.reason("Tagged soccer", on: soccerAtNakheel),
                         p.reason("Related tag: football", on: nakheel.filter(soccer.more.contains))])),
            Self(4, "Al-Nakheel Park last summer", Expectation(
                best: nakheel.filter(summer2026), moreMust: receivedOnNakheelDays.filter(summer2026),
                moreAllowed: p.near(nakheel, [summer2026Dates], place: 1) + p.near(receivedOnNakheelDays, [summer2026Dates], place: 0.6))),
            Self(5, "Saturday evening at Al-Nakheel Park", Expectation(
                best: nakheel.filter { $0.weekdayOfMomentDay == 7 && (17 * 60..<21 * 60).contains($0.minuteOfDay) },
                // 45-minute fuzz, the park scoring 1: up to 62 minutes outside the evening (the received photos, at 23:40, never).
                moreAllowed: nakheel.filter { $0.weekdayOfMomentDay == 7 && (17 * 60 - 62..<21 * 60 + 62).contains($0.minuteOfDay) })),
            Self(6, "al nakheel park 2025", Expectation(
                best: nakheel.filter(year2025),
                moreAllowed: p.near(nakheel, [dates2025], place: 1) + p.near(receivedOnNakheelDays, [dates2025], place: 0.6))),
            Self(7, "Greece", Expectation(
                best: p.tagged(.greece).filter(\.isLocated), moreMust: p.tagged(.greece).filter { !$0.isLocated },
                checks: [p.tripHeader(greeceTrip, in: .best), p.reason("During your Greece trip", on: p.tagged(.greece).filter { !$0.isLocated })])),
            Self(8, "Mykonos", Expectation(best: p.tagged(.greece).filter { $0.isLocated && $0.title == SeedPlace.mykonos.name })),
            Self(9, "Santorini", Expectation(
                best: p.tagged(.greece).filter { $0.isLocated && [SeedPlace.oia.name, SeedPlace.fira.name].contains($0.title) }, maxSearches: 1)),
            Self(10, "Dubai December 2024", Expectation(best: p.tagged(.dubai2), checks: [p.tripHeader(dubaiTrip, in: .best)])),
            Self(11, "Dubai last December", Expectation(best: [], checks: [p.noMatch(
                .combination, headline: "\(dubai.count) in Dubai, none in \(LocalDateFormat.monthTitle(year: 2025, month: 12, locale: HeroSuite.locale)).",
                offers: [("Dubai, any time", dubai.count),
                         ("\(LocalDateFormat.monthTitle(year: 2025, month: 12, locale: HeroSuite.locale)), anywhere",
                          p.bestEligible.filter(p.days(2025, 12, 1, through: 2025, 12, 31)).count)])])),
            Self(12, "Ramadan 2024", Expectation(
                best: p.bestEligible.filter(p.inside([ramadan1445])),
                moreMust: p.tagged(.eid).filter { $0.momentDay == LocalTime.day(year: 2024, month: 4, day: 10) },
                moreAllowed: p.timeOnlyMore([ramadan1445], tau: Predicates.day),
                checks: [p.reason("Day after Ramadan 1445", on: p.tagged(.eid).filter { $0.momentDay == LocalTime.day(year: 2024, month: 4, day: 10) })])),
            Self(13, "Eid", Expectation(
                best: p.bestEligible.filter(p.inside(p.eidWindows)), moreAllowed: p.timeOnlyMore(p.eidWindows, tau: Predicates.day))),
            Self(14, "summer", Expectation(
                // Recurring months: a 3-day fuzz in whole days, so up to 2 days outside (screenshots, halved, only inside).
                best: p.bestEligible.filter(p.inSummer(margin: 0)),
                moreAllowed: p.dated.filter { p.inSummer(margin: 2)($0) && ($0.media != .screenshot || p.inSummer(margin: 0)($0)) })),
            Self(15, "last summer", Expectation(
                best: p.bestEligible.filter(summer2026), moreAllowed: p.timeOnlyMore([summer2026Dates]))),
            Self(16, "3 years ago", Expectation(
                best: p.bestEligible.filter(p.days(2023, 1, 1, through: 2023, 12, 31)), moreAllowed: p.timeOnlyMore([dates2023]),
                checks: [p.chips(["2023 (3 years ago)"])])),
            Self(17, "trips", Expectation(
                best: p.dated.filter { item in SeedScenario.hero.trips.contains { $0.contains(day: item.momentDay!) } },
                checks: [p.tripGroupsNewestFirst(SeedScenario.hero.trips)])),
            Self(18, "at home", Expectation(best: p.tagged(.home, .summer2026), checks: [p.chips(["Home (estimated)"])])),
            Self(19, "Sufra Grill", Expectation(best: p.tagged(.sufra), maxSearches: 1)),
            Self(20, "near Kingdom Centre", Expectation(best: p.tagged(.kingdom), moreMust: p.tagged(.sufra))),
            Self(21, "Riyadh 2025", Expectation(
                best: p.riyadh.filter(year2025),
                moreMust: facts.receivedPhotos ? p.received.filter(year2025) : [],
                moreAllowed: p.near(p.riyadh, [dates2025], place: 1) + p.near(p.received, [dates2025], place: 0.6),
                // Received photos that don't look received are plain photos without a location.
                locationUnknown: p.tagged(.orphans).filter(year2025) + (facts.receivedPhotos ? [] : p.tagged(.received).filter(year2025)),
                checks: [p.absent(p.tagged(.screens))])),
            Self(22, "Paris", Expectation(best: [], checks: [p.noMatch(
                .placeEmpty, headline: "No photos in Paris, France.",
                // The Simulator's own samples may add countries; the seed's are offered with their Best counts.
                detail: facts.onlySeed ? "Your photos are from \(p.countryBest.count) countries." : nil,
                offerCounts: p.countryBest, exactOffers: facts.onlySeed)])),
            Self(23, "videos", Expectation(best: p.dated.filter(\.isVideo), checks: [p.bestNewestFirst])),
            Self(24, "screenshots", skip: facts.screenshotSubtype ? nil : "the screenshot subtype didn't import", Expectation(best: p.tagged(.screens))),
            Self(25, "Sydney in summer", Expectation(best: p.tagged(.sydney))),
            Self(26, "weekends in Riyadh", Expectation(
                best: p.riyadh.filter { [6, 7].contains($0.weekdayOfMomentDay) }, moreAllowed: p.received)),
            Self(27, "London new year's eve", Expectation(
                best: p.tagged(.london).filter(p.inside([newYearsEve])), moreAllowed: p.near(p.tagged(.london), [newYearsEve], place: 1))),
            Self(28, "Al-Nakheel Park during Ramadan 2024", Expectation(best: [], checks: [p.noMatch(
                .combination, headline: "\(nakheel.count) at Al-Nakheel Park, none during Ramadan 2024.", detail: p.closestBefore(nakheel, ramadan1445),
                offers: [("Al-Nakheel Park, any time", nakheel.count), ("Ramadan 2024, anywhere", p.bestEligible.filter(p.inside([ramadan1445])).count)])])),
            Self(29, "sunset", Expectation(
                best: sunset.best, moreMust: sunset.more, maxSearches: 0,
                checks: [p.chips(["sunset · photo tag"]), p.reason("Tagged sunset", on: sunset.best), p.visualLine])),
            Self(30, "Diriyah", Expectation(best: p.tagged(.diriyah))),
            Self(31, "selfies", skip: facts.selfiesAlbum ? nil : "Selfies album membership didn't import", Expectation(best: p.dated.filter(\.isSelfie))),
            Self(32, "nakhel prk", Expectation(best: nakheel, moreMust: receivedOnNakheelDays, moreAllowed: p.received, checks: [p.chips(["Al-Nakheel Park"])])),
            Self(33, "Salam Park", Expectation(
                best: p.tagged(.salam), checks: [p.picker(["Riyadh · \(p.tagged(.salam).count)", "Dubai · \(salamDubai.count)"])]),
                 followUp: HeroSuite.FollowUp(request: { result in
                     guard let picker = result.query.picker, let dubai = picker.choices.first(where: { $0.candidate.context == "Dubai" }) else { return nil }
                     let edit = SlotEdit.replacePlace(slot: picker.slot, placeKey: dubai.candidate.id, name: dubai.candidate.name)
                     var overrides = ResolutionOverrides()
                     overrides.apply(edit)
                     return SearchRequest(text: result.query.parsed.text, parsed: result.query.parsed.applying([edit]), overrides: overrides)
                 }, expectation: Expectation(best: salamDubai))),
            // The first and last time, and oldest first: the whole first trip to a city away from home, the park's
            // latest visit, every visit in time order, and a free search whose first time is older than it covers.
            Self(34, "the first time I went to Dubai", Expectation(
                best: p.tagged(.dubai1).filter { firstDubaiTrip.contains(day: $0.momentDay!) },
                checks: [p.chips(["First time", "Dubai"]), p.tripHeader(firstDubaiTrip, in: .best), p.sectionTitle(.best, "First time in Dubai"),
                         p.occasion("1 later trip"), p.bestOldestFirst])),
            Self(35, "last time at Al-Nakheel Park", Expectation(
                best: lastVisit, moreMust: receivedOnNakheelDays.filter { $0.momentDay == nakheelDays.max() },
                checks: [p.sectionTitle(.best, "Last time at Al-Nakheel Park"), p.occasion("\(nakheelDays.count - 1) earlier times"), p.cards(.best, 1)])),
            Self(36, "Al-Nakheel Park oldest first", Expectation(
                best: nakheel, moreMust: receivedOnNakheelDays, moreAllowed: p.received,
                checks: [p.chips(["Al-Nakheel Park", "Oldest first"]), p.cards(.best, nakheelDays.count), p.bestOldestFirst])),
            Self(37, "the first time at Al-Nakheel Park", scope: .since(HeroSuite.freeSince), Expectation(best: [], checks: [
                p.noMatch(.onlyEarlier, headline: "Your first time at Al-Nakheel Park was before the last 12 months."),
                p.lockedAtLeast(nakheel.count { ($0.utc ?? .max) < freeStart }), p.absent(firstVisit)])),
            // Photo tags (content search Milestone A): strict tags in Best, related and less sure ones in More (E24), photos
            // not checked yet left out and counted (E25), honest declines, and no Apple Maps search for content words.
            Self(38, "soccer", Expectation(
                best: soccer.best, moreMust: soccer.more, maxSearches: 0,
                checks: [p.chips(["soccer · photo tag"]), p.visualLine, p.noNotice, p.reason("Related tag: football", on: soccer.more)])),
            Self(39, "hike", Expectation(
                best: hike.best, moreMust: hike.more, maxSearches: 0,
                checks: [p.chips(["hiking · photo tag"]), p.reason("Tagged hiking", on: hike.best), p.reason("Related tag: cliff", on: hike.more),
                         p.sectionTitle(.more, "Less sure")]),
                 followUp: HeroSuite.FollowUp(request: { result in
                     // The editor removes the related tags: Best stays, More goes.
                     guard let slot = result.query.slots.first(where: { $0.slot.kind == .visual }) else { return nil }
                     var overrides = ResolutionOverrides()
                     overrides.apply(.setRelatedTags(slot: slot.id, false))
                     return SearchRequest(text: result.query.parsed.text, parsed: result.query.parsed, overrides: overrides)
                 }, expectation: Expectation(best: hike.best))),
            Self(40, "trekking", Expectation(best: hike.best, moreMust: hike.more, maxSearches: 0, checks: [p.chips(["hiking · photo tag"])])),
            Self(41, "scuba diving", Expectation(best: [], maxSearches: 0, checks: [
                p.noMatch(.notTagged, headline: facts.onlySeed ? "No photos tagged scuba diving among \(p.checked.count) checked." : nil,
                          detail: facts.onlySeed ? p.expectedVisualLine + "." : nil)])),
            Self(42, "receipts", Expectation(best: receipts.best, moreMust: receipts.more, checks: [p.chips(["receipt · photo tag"])])),
            Self(43, "passport", Expectation(best: passport.best, moreMust: passport.more, checks: [p.chips(["passport · photo tag"])])),
            Self(44, "beach", Expectation(best: beach.best, moreMust: beach.more, maxSearches: 0, checks: [p.chips(["beach · photo tag"])])),
            Self(45, "camping", Expectation(best: camping.best, moreMust: camping.more, maxSearches: 0)),
            Self(46, "fireworks in London", Expectation(
                best: london.filter(fireworks.best.contains), moreMust: london.filter(fireworks.more.contains),
                checks: [p.chips(["fireworks · photo tag", "London"]), p.reason("Related tag: night sky", on: london.filter(fireworks.more.contains))])),
            Self(47, "beach sunset", Expectation(best: [], maxSearches: 0, checks: [p.noMatch(
                .nothing, headline: "Nothing matches all of that.",
                offers: [("Without “beach”", sunset.best.count), ("Without “sunset”", beach.best.count)])])),
            Self(48, "party", Expectation(best: [], maxSearches: 0, checks: [
                p.noMatch(.onlyUnsupported, headline: "Lahza has no photo tag for “party” yet."), p.unsupported(["party"]), p.hasExamples])),
            // The first night out: its moment (whole outings come with step 4).
            Self(49, "the first time I went camping", Expectation(best: camping.best, checks: [p.sectionTitle(.best, "First time camping")])),
        ]
    }
}

/// Scenario predicates and result checks.
private struct Predicates {
    let facts: HeroSuite.Facts
    let items = SeedScenario.hero.items

    /// Riyadh's own places (the home, the parks and the family house), whose photos the gazetteer puts in Riyadh or
    /// its metro.
    static let riyadhTags: Set<SeedScenario.Tag> = [.home, .nakheel, .otherPitch, .salam, .kingdom, .sufra, .diriyah, .iftar, .eid, .summer2026]

    func tagged(_ tags: SeedScenario.Tag...) -> [SeedItem] { items.filter { tags.contains($0.tag) } }

    var dated: [SeedItem] { items.filter { $0.utc != nil } }

    /// Dated and not a screenshot (screenshots rank lower, so never Best unless asked for).
    var bestEligible: [SeedItem] { dated.filter { $0.media != .screenshot } }

    var received: [SeedItem] { facts.receivedPhotos ? tagged(.received) : [] }

    /// Riyadh items with a position: their own, or one borrowed from their outing.
    var riyadh: [SeedItem] { items.filter { Self.riyadhTags.contains($0.tag) && ($0.isLocated || $0.borrowing == .moment) } }

    func wall(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Int64 {
        Int64(LocalTime.day(year: year, month: month, day: day)) * 86_400 + Int64(hour * 3_600 + minute * 60)
    }

    /// Moment days from one date through another.
    func days(_ y1: Int, _ m1: Int, _ d1: Int, through y2: Int, _ m2: Int, _ d2: Int) -> @Sendable (SeedItem) -> Bool {
        let first = LocalTime.day(year: y1, month: m1, day: d1), last = LocalTime.day(year: y2, month: m2, day: d2)
        return { item in item.momentDay.map { (first...last).contains($0) } ?? false }
    }

    func inside(_ windows: [Range<Int64>], margin: Int64 = 0) -> @Sendable (SeedItem) -> Bool {
        { item in item.wallSeconds.map { wall in windows.contains { ($0.lowerBound - margin..<$0.upperBound + margin).contains(wall) } } ?? false }
    }

    // MARK: Reaching More

    static let day: Double = 86_400

    /// The dates' wall seconds, from 04:00 on the first day to 04:00 after the last.
    func window(_ y1: Int, _ m1: Int, _ d1: Int, through y2: Int, _ m2: Int, _ d2: Int) -> Range<Int64> {
        let first = LocalTime.day(year: y1, month: m1, day: d1), last = LocalTime.day(year: y2, month: m2, day: d2)
        return Int64(first) * 86_400 + LocalTime.dayBreak..<Int64(last + 1) * 86_400 + LocalTime.dayBreak
    }

    /// A range's fuzz τ: a tenth of the longest one, at least 3 days.
    static func tau(_ windows: [Range<Int64>]) -> Double {
        max(Double(windows.map(\.count).max() ?? 0) / 10, 3 * day)
    }

    /// How far outside the dates a photo still reaches More (S ≥ 0.5, the geometric mean of its slots): its time score
    /// e^(−Δ/τ) alone must reach 0.5, so Δ ≤ τ·ln 2; with a place scoring `place`, Δ ≤ τ·ln(4·place).
    static func reach(tau: Double, place: Double? = nil) -> Int64 {
        Int64(tau * log(place.map { 4 * $0 } ?? 2))
    }

    /// Items close enough to the dates to reach More when their place scores `place`.
    func near(_ items: [SeedItem], _ windows: [Range<Int64>], place: Double) -> [SeedItem] {
        items.filter(inside(windows, margin: Self.reach(tau: Self.tau(windows), place: place)))
    }

    /// Dated items that can reach More on a dates-only query: within τ·ln 2 of the dates; screenshots (halved) only
    /// inside them.
    func timeOnlyMore(_ windows: [Range<Int64>], tau: Double? = nil) -> [SeedItem] {
        let margin = Self.reach(tau: tau ?? Self.tau(windows))
        return dated.filter { inside(windows, margin: margin)($0) && ($0.media != .screenshot || inside(windows)($0)) }
    }

    /// Each seed country's Best matches for a place-only search of it: its photos with their own position or one from
    /// their outing (screenshots rank lower; received photos and photos far from their outing aren't Best).
    var countryBest: [String: Int] {
        let countries: [SeedScenario.Tag: String] = [.dubai1: "AE", .dubai2: "AE", .greece: "GR", .london: "GB", .sydney: "AU"]
        var counts: [String: Int] = [:]
        for item in items where item.media != .screenshot && (item.isLocated || item.borrowing == .moment) {
            let code = countries[item.tag] ?? (Self.saudiTags.contains(item.tag) ? "SA" : nil)
            if let code { counts[CountryNames.name(code), default: 0] += 1 }
        }
        return counts
    }

    /// The tags placed in Saudi Arabia: Riyadh's and the desert trip's.
    static let saudiTags = riyadhTags.union([.desert])

    /// Meteorological summer in each photo's hemisphere (photos without a position: the northern home's), within
    /// `margin` days of it.
    func inSummer(margin: Int32) -> @Sendable (SeedItem) -> Bool {
        { item in
            guard let day = item.momentDay else { return false }
            let months: Set<Int> = (item.coordinate?.latitude ?? 1) < 0 ? [12, 1, 2] : [6, 7, 8]
            return (day - margin...day + margin).contains { months.contains(LocalTime.civil(day: $0).month) }
        }
    }

    // MARK: Umm al-Qura

    enum Event { case ramadan, eidAlFitr, eidAlAdha }

    private static let hijri: Calendar = {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.timeZone = .gmt
        return calendar
    }()

    static func hijriDay(_ year: Int, _ month: Int, _ day: Int) -> Int32 {
        let date = hijri.date(from: DateComponents(year: year, month: month, day: day))!
        return Int32((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// 18:00 on the eve to 04:00 after the last day, in local wall seconds.
    func hijriWindow(_ year: Int, _ event: Event) -> Range<Int64> {
        let (first, last): (Int32, Int32) = switch event {
        case .ramadan: (Self.hijriDay(year, 9, 1), Self.hijriDay(year, 10, 1) - 1)
        case .eidAlFitr: (Self.hijriDay(year, 10, 1), Self.hijriDay(year, 10, 1) + 2)
        case .eidAlAdha: (Self.hijriDay(year, 12, 10), Self.hijriDay(year, 12, 10) + 3)
        }
        return (Int64(first) - 1) * 86_400 + 18 * 3_600..<(Int64(last) + 1) * 86_400 + 4 * 3_600
    }

    /// Both Eids of the Hijri years that start in the library's years (2021–2026).
    var eidWindows: [Range<Int64>] {
        let first = LocalTime.day(year: 2021, month: 1, day: 1), last = LocalTime.day(year: 2026, month: 12, day: 31)
        return (1441...1449).flatMap { [hijriWindow($0, .eidAlFitr), hijriWindow($0, .eidAlAdha)] }.filter { window in
            let start = LocalTime.momentDay(wallSeconds: window.lowerBound + 12 * 3_600)
            return (first...last).contains(start)
        }
    }

    /// "Closest: Sat 2 Mar 2024, 9 days before." for the latest item before an event window.
    func closestBefore(_ items: [SeedItem], _ window: Range<Int64>) -> String? {
        guard let item = items.filter({ ($0.wallSeconds ?? .max) < window.lowerBound }).max(by: { $0.wallSeconds! < $1.wallSeconds! }),
              let day = item.momentDay else { return nil }
        let eventDay = LocalTime.momentDay(wallSeconds: window.lowerBound + 12 * 3_600)
        let gap = eventDay - day
        return "Closest: \(LocalDateFormat.dayTitle(day, locale: HeroSuite.locale)), \(gap == 1 ? "1 day" : "\(gap) days") before."
    }

    // MARK: Photo tags

    /// The items checked for photo tags (not only in iCloud).
    var checked: [SeedItem] { items.filter { !SeedLabels.analysis(for: $0).inCloud } }

    /// What words about what's in photos alone find (content search plan §Fusion): a checked item's strongest own tag
    /// scores 1 (precise), 0.8 (likely) or 0.55 (high-recall only), a related tag 0.6; Best needs 0.7 and no junk, More
    /// S ≥ 0.5 with S = J × score (J: screenshots and utility photos 0.5, or 1.2 for a document).
    func tagTiers(_ words: String) -> (best: [SeedItem], more: [SeedItem]) {
        guard let concept = VisualVocabulary.english.concept(for: words) else { return ([], []) }
        var best: [SeedItem] = [], more: [SeedItem] = []
        for item in checked {
            let analysis = SeedLabels.analysis(for: item)
            var score = concept.labels.compactMap { analysis.labels[$0] }.max().map { strength in
                switch strength {
                case .precise: 1.0
                case .likely: 0.8
                case .candidate: 0.55
                }
            } ?? 0
            if concept.related.contains(where: { analysis.labels[$0] != nil }) { score = max(score, 0.6) }
            guard score > 0.1 else { continue }
            let utility = item.media == .screenshot || analysis.isUtility
            let junk = concept.kind == .document ? (utility ? 1.2 : 1) : (utility ? 0.5 : 1)
            if score >= 0.7, junk >= 1 { best.append(item) } else if junk * score >= 0.5 { more.append(item) }
        }
        return (best, more)
    }

    /// "Checked 552 of 557 photos · 5 only in iCloud" (the fake library); with the Simulator's own samples, some such
    /// line.
    var expectedVisualLine: String { "Checked \(checked.count) of \(items.count) photos · \(items.count - checked.count) only in iCloud" }

    var visualLine: Check {
        let expected = expectedVisualLine
        let exact = facts.onlySeed
        return { result in
            let line = result.coverage.visualLine ?? ""
            return (exact ? line == expected : line.hasPrefix("Checked ")) ? nil : "visual line “\(line)”, expected “\(expected)”"
        }
    }

    var noNotice: Check { { $0.unsupportedNotice == nil ? nil : "unexpected notice “\($0.unsupportedNotice ?? "")”" } }

    // MARK: Checks

    typealias Check = @Sendable (SearchResult) -> String?

    func chips(_ expected: [String]) -> Check {
        { result in
            let chips = result.query.slots.filter(\.isSupported).map(\.chip)
            return expected.allSatisfy(chips.contains) ? nil : "chips \(chips), expected \(expected)"
        }
    }

    var noPicker: Check { { $0.query.picker == nil ? nil : "unexpected picker" } }

    func cards(_ tier: Tier, _ count: Int) -> Check {
        { result in
            let cards = result.sections.first { $0.tier == tier }?.groups.flatMap(\.cards).count ?? 0
            return cards == count ? nil : "\(cards) cards in \(tier), expected \(count)"
        }
    }

    func reason(_ text: String, on items: [SeedItem]) -> Check {
        let utcs = Set(items.compactMap(\.utc))
        return { result in
            let hits = result.hits.filter { $0.utc.map(utcs.contains) ?? false }
            let missing = hits.count(where: { !$0.reasons.contains { $0.text == text } })
            if hits.count < utcs.count { return "“\(text)”: \(utcs.count - hits.count) of \(utcs.count) items aren't hits" }
            return missing == 0 ? nil : "“\(text)” missing on \(missing) hits"
        }
    }

    func unsupported(_ words: [String]) -> Check {
        { result in
            let found = result.unsupported.compactMap { slot -> String? in
                switch slot.value {
                case .visual(let text), .people(let text), .text(let text): text
                default: nil
                }
            }
            return Set(words).isSubset(of: found) ? nil : "unsupported \(found), expected \(words)"
        }
    }

    func notice(containing text: String) -> Check {
        { ($0.unsupportedNotice ?? "").contains(text) ? nil : "notice “\($0.unsupportedNotice ?? "")” lacks “\(text)”" }
    }

    func tripHeader(_ trip: SeedScenario.Trip, in tier: Tier) -> Check {
        let title = "\(trip.name) · \(LocalDateFormat.dayRange(trip.firstDay, trip.lastDay, locale: HeroSuite.locale))"
        return { result in
            let titles = result.sections.first { $0.tier == tier }?.groups.compactMap { group -> String? in
                if case .trip(let trip) = group { trip.title } else { nil }
            } ?? []
            return titles.contains(title) ? nil : "trip headers \(titles), expected “\(title)”"
        }
    }

    func tripGroupsNewestFirst(_ trips: [SeedScenario.Trip]) -> Check {
        let expected = trips.map(\.firstDay).sorted(by: >)
        return { result in
            let groups = result.sections.first { $0.tier == .best }?.groups ?? []
            let days = groups.compactMap { group -> Int32? in if case .trip(let trip) = group { trip.trip.startDay } else { nil } }
            return days == expected && days.count == groups.count ? nil : "trip groups \(days) (of \(groups.count) groups), expected \(expected)"
        }
    }

    var bestNewestFirst: Check {
        { result in
            let utcs = result.hits.filter { $0.tier == .best }.compactMap(\.utc)
            return utcs == utcs.sorted(by: >) ? nil : "Best isn't newest first"
        }
    }

    var bestOldestFirst: Check {
        { result in
            let utcs = result.hits.filter { $0.tier == .best }.compactMap(\.utc)
            return utcs == utcs.sorted() ? nil : "Best isn't oldest first"
        }
    }

    func sectionTitle(_ tier: Tier, _ title: String) -> Check {
        { result in
            let got = result.sections.first { $0.tier == tier }?.title
            return got == title ? nil : "\(tier) titled “\(got ?? "-")”, expected “\(title)”"
        }
    }

    /// The first or last time's row: "9 later times".
    func occasion(_ label: String) -> Check {
        { result in result.occasion?.othersLabel == label ? nil : "occasion row “\(result.occasion?.othersLabel ?? "-")”, expected “\(label)”" }
    }

    func lockedAtLeast(_ count: Int) -> Check {
        { result in result.lockedCount >= count ? nil : "\(result.lockedCount) locked, expected at least \(count)" }
    }

    func absent(_ items: [SeedItem]) -> Check {
        let utcs = Set(items.compactMap(\.utc))
        return { result in
            let found = result.hits.count(where: { $0.utc.map(utcs.contains) ?? false })
            return found == 0 ? nil : "\(found) unexpected hits"
        }
    }

    func noMatch(_ kind: NoMatch.Kind, headline: String?, detail: String? = nil, offers: [(String, Int)] = [], offerCounts: [String: Int]? = nil,
                 exactOffers: Bool = true) -> Check {
        { result in
            guard let noMatch = result.noMatch else { return "no no-match" }
            var problems: [String] = []
            if noMatch.kind != kind { problems.append("kind \(noMatch.kind)") }
            if let headline, noMatch.headline != headline { problems.append("headline “\(noMatch.headline)”, expected “\(headline)”") }
            if let detail, noMatch.detail != detail { problems.append("detail “\(noMatch.detail ?? "")”, expected “\(detail)”") }
            for (index, offer) in offers.enumerated() {
                guard noMatch.offers.indices.contains(index) else {
                    problems.append("missing offer “\(offer.0) · \(offer.1)”")
                    continue
                }
                let got = noMatch.offers[index]
                if got.label != offer.0 || got.count != offer.1 { problems.append("offer “\(got.label) · \(got.count)”, expected “\(offer.0) · \(offer.1)”") }
            }
            // Offers by label with their counts: exactly these, or (with the Simulator's samples) at least these.
            if let offerCounts {
                let got = Dictionary(noMatch.offers.map { ($0.label, $0.count) }, uniquingKeysWith: max)
                let matches = exactOffers ? got == offerCounts : offerCounts.allSatisfy { got[$0.key] == $0.value }
                if !matches || noMatch.offers.contains(where: { $0.count <= 0 }) {
                    problems.append("offers \(noMatch.offers.map { "\($0.label) · \($0.count)" }), expected \(offerCounts.sorted { $0.value > $1.value }.map { "\($0.key) · \($0.value)" })")
                }
            }
            return problems.isEmpty ? nil : problems.joined(separator: ", ")
        }
    }

    var hasExamples: Check { { ($0.noMatch?.examples.isEmpty ?? true) ? "no example searches" : nil } }

    func picker(_ labels: [String]) -> Check {
        { result in
            let got = result.query.picker?.choices.map(\.label) ?? []
            return Array(got.prefix(labels.count)) == labels ? nil : "picker \(got), expected \(labels)"
        }
    }
}

private extension SeedItem {
    var weekdayOfMomentDay: Int { momentDay.map { LocalTime.weekday(day: $0) } ?? 0 }
    var minuteOfDay: Int { wallSeconds.map { LocalTime.minuteOfDay(wallSeconds: $0) } ?? -1 }
}
#endif
