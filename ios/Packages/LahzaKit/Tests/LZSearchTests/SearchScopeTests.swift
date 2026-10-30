import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// A free search's last 12 months (decision 34, E11) on the hero library at the spec's now, with expectations from the
/// scenario's dates: what is shown, what is counted as locked, the answer when every match is older, offers and
/// examples that count what a tap shows, an offer whose matches are all older (E19) and the caption (E20); and E17,
/// the examples after a no-match with no offer left.
@Suite struct SearchScopeTests {
    static let hero = SeedScenario.hero
    /// 12 months before 2026-10-28T12:00+03:00.
    static let since = Date(timeIntervalSince1970: 1_761_642_000)
    static let free = SearchScope.since(since)

    private static func inWindow(_ item: SeedItem) -> Bool {
        item.utc.map { $0 >= Int64(since.timeIntervalSince1970) } ?? true
    }

    private func request(_ text: String, scope: SearchScope = free) -> SearchRequest {
        SearchRequest(text: text, scope: scope)
    }

    @Test func theWindowStartsTwelveMonthsBack() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SearchFixture.riyadh
        #expect(calendar.date(byAdding: .month, value: -12, to: SearchFixture.now) == Self.since)
    }

    /// The park while free: only its sessions of the last 12 months, the rest counted for the unlock row.
    @Test func aFreeSearchShowsItsMonthsAndCountsTheRest() async throws {
        let search = try await HeroSearch.shared.value
        let nakheel = Self.hero.items(.nakheel)
        let received = Self.hero.items(.received).filter { item in nakheel.contains { $0.momentDay == item.momentDay } }

        let everything = try await search.search(request("Al-Nakheel Park", scope: .wholeLibrary))
        #expect(everything.lockedCount == 0)
        #expect(Set(everything.items(.more).map(\.number)) == Set(received.map(\.number)), "More is the received photos of the visits")

        let free = try await search.search(request("Al-Nakheel Park"))
        let recent = nakheel.filter(Self.inWindow)
        #expect(!recent.isEmpty && recent.count < nakheel.count)
        #expect(Set(free.items(.best).map(\.number)) == Set(recent.map(\.number)))
        #expect(Set(free.items(.more).map(\.number)) == Set(received.filter(Self.inWindow).map(\.number)))
        #expect(free.lockedCount == nakheel.count(where: { !Self.inWindow($0) }) + received.count(where: { !Self.inWindow($0) }))
        #expect(free.noMatch == nil)
        #expect(free.totals.items == recent.count + received.count(where: Self.inWindow))
    }

    /// Greece (2023) while free: nothing in the window, all 75 counted, and an answer that says why.
    @Test func everyMatchOlderSaysSo() async throws {
        let search = try await HeroSearch.shared.value
        let greece = Self.hero.items(.greece)
        #expect(greece.count == 75 && !greece.contains(where: Self.inWindow))
        let result = try await search.search(request("Greece"))
        #expect(result.totals.items == 0)
        #expect(result.lockedCount == greece.count)
        let noMatch = try #require(result.noMatch)
        #expect(noMatch.kind == .onlyEarlier)
        #expect(noMatch.headline == "No matches in the last 12 months.")
        #expect(noMatch.offers.isEmpty && noMatch.examples.isEmpty, "the unlock row is the next tap")
        #expect(QueryChipTitles.of(result) == ["Greece"])
    }

    /// The search an offer's tap runs (the edits on the query it was offered for).
    private func tap(_ offer: WideningOffer, on result: SearchResult, scope: SearchScope = free) -> SearchRequest {
        let edited = result.query.parsed.applying(offer.edits, locale: SearchFixture.uk)
        return SearchRequest(text: edited.text, parsed: edited, scope: scope)
    }

    /// Facts about the library count every year; an offer counts what its tap shows. E19: an offer whose matches are
    /// all older than the window stays, counted as the unlock row its tap shows will count them.
    @Test func offersCountWhatATapShows() async throws {
        let search = try await HeroSearch.shared.value
        let dubai = Self.hero.items(.dubai1) + Self.hero.items(.dubai2)
        #expect(dubai.count == 57 && dubai.allSatisfy(\.isLocated) && !dubai.contains(where: Self.inWindow), "both trips are older")
        let free = try await search.search(request("Dubai last December"))
        let noMatch = try #require(free.noMatch)
        #expect(noMatch.kind == .combination)
        #expect(noMatch.headline.hasPrefix("\(dubai.count) in Dubai, none in "), "never reads as if Dubai weren't there")
        #expect(noMatch.detail?.hasPrefix("Closest: ") == true)
        #expect(noMatch.offers.map(\.label) == ["Dubai, any time", "December 2025, anywhere"])
        #expect(noMatch.examples.isEmpty, "an offer is left")
        let anyTime = try #require(noMatch.offers.first)
        #expect(anyTime.count == dubai.count, "every Dubai photo, older than the window")

        // Its tap: no match in the window, and the unlock row counts what the offer said.
        let tapped = try await search.search(tap(anyTime, on: free))
        #expect(tapped.query.parsed.text == "Dubai")
        #expect(tapped.noMatch?.kind == .onlyEarlier && tapped.noMatch?.headline == "No matches in the last 12 months.")
        #expect(tapped.lockedCount == anyTime.count && tapped.totals.items == 0)

        // An offer with matches in the window counts what its tap shows, as before.
        let december = noMatch.offers[1]
        let decemberTap = try await search.search(tap(december, on: free))
        #expect(decemberTap.items(.best).count == december.count && decemberTap.noMatch == nil)
        let unlocked = try await search.search(request("Dubai last December", scope: .wholeLibrary))
        #expect(unlocked.noMatch?.offers.first { $0.label == december.label }?.count == december.count, "December 2025 is inside the window")
        #expect(unlocked.noMatch?.offers.first.map { [$0.label, String($0.count)] } == ["Dubai, any time", String(dubai.count)])
        #expect(unlocked.lockedCount == 0)
    }

    /// E19 for any offer: "Paris" (no photos there) offers the library's countries; while free, the older-only ones stay
    /// with their older count and land on the unlock row.
    @Test func olderOnlyCountriesStayWhileFree() async throws {
        let search = try await HeroSearch.shared.value
        let greece = Self.hero.items(.greece)
        #expect(!greece.contains(where: Self.inWindow))
        let free = try await search.search(request("Paris"))
        let noMatch = try #require(free.noMatch)
        #expect(noMatch.kind == .placeEmpty)
        let greeceOffer = try #require(noMatch.offers.first { $0.label == "Greece" }, "older than the window, but kept")
        #expect(greeceOffer.count == greece.count)
        let tapped = try await search.search(tap(greeceOffer, on: free))
        #expect(tapped.noMatch?.kind == .onlyEarlier && tapped.lockedCount == greece.count)
        let uae = try #require(noMatch.offers.first { $0.label == "United Arab Emirates" })
        #expect(uae.count == Self.hero.items(.dubai1).count + Self.hero.items(.dubai2).count)

        // A country with photos in the window counts what its tap shows.
        let saudi = try #require(noMatch.offers.first { $0.label == "Saudi Arabia" })
        let saudiTap = try await search.search(tap(saudi, on: free))
        #expect(saudiTap.noMatch == nil && saudiTap.items(.best).count == saudi.count)

        // Unlocked, every country counts what its tap shows over every year.
        let unlocked = try await search.search(request("Paris", scope: .wholeLibrary))
        let offers = try #require(unlocked.noMatch?.offers)
        #expect(Set(offers.map(\.label)) == Set(noMatch.offers.map(\.label)), "while free, no country is left out")
        for offer in offers {
            let shown = try await search.search(tap(offer, on: unlocked, scope: .wholeLibrary))
            #expect(shown.items(.best).count == offer.count && shown.lockedCount == 0, "\(offer.label)")
        }
    }

    /// E20: a free search's caption says what it covered; the progress and limited-access captions keep their words.
    @Test func theCaptionNamesTheWindow() async throws {
        let search = try await HeroSearch.shared.value
        let free = try await search.search(request("Al-Nakheel Park"))
        #expect(free.coverage.caption == "Searched your last 12 months")
        let unlocked = try await search.search(request("Al-Nakheel Park", scope: .wholeLibrary))
        #expect(unlocked.coverage.caption == "Searched all \(Self.hero.items.count) photos")
        let reading = SearchIndexContext(isPartial: true, coveredSince: Date(timeIntervalSince1970: 1_710_460_800), libraryTotal: 2_000)
        let partial = try await search.engine.search(request("2025"), reader: search.index.reader, writer: search.index.writer, index: reading)
        #expect(partial.coverage.caption == "Searched \(Self.hero.items.count) of about 2,000 so far")
        let limited = try await search.engine.search(request("2025"), reader: search.index.reader, writer: search.index.writer,
                                                     index: SearchIndexContext(isLimited: true))
        #expect(limited.coverage.caption == "Searching the \(Self.hero.items.count) photos you’ve shared")
        // Once the first build has read everything, a free search names its window again.
        let read = SearchIndexContext(isPartial: true, coveredSince: Date(timeIntervalSince1970: 1_710_460_800), libraryTotal: Self.hero.items.count)
        let caughtUp = try await search.engine.search(request("2025"), reader: search.index.reader, writer: search.index.writer, index: read)
        #expect(caughtUp.coverage.caption == "Searched your last 12 months")
        #expect(SearchCopy(locale: SearchFixture.uk, resolver: SearchFixture.saudi()).lastPeriod(since: Self.since, now: SearchFixture.now) == "last 12 months")
    }

    /// The examples of a free search count its months, so a tap shows the count; older-only ones are left out.
    @Test func freeExamplesCountTheirMonths() async throws {
        let search = try await HeroSearch.shared.value
        let examples = try await search.engine.examples(reader: search.index.reader, scope: Self.free)
        #expect(!examples.isEmpty)
        #expect(!examples.contains { $0.text == "Dubai trip" }, "both Dubai trips are older")
        for example in examples {
            let result = try await search.search(request(example.text))
            #expect(result.items(.best).count == example.count, "\(example.text)")
        }
        let nakheel = try #require(examples.first { $0.text == "Al-Nakheel Park" })
        #expect(nakheel.count == Self.hero.items(.nakheel).count(where: Self.inWindow))
        #expect(try await search.engine.examples(reader: search.index.reader).first?.text == "Dubai trip", "the whole library's are their own")
    }

    /// E17: a lone name no place confirms has no offer, so the examples follow it.
    @Test func noOfferLeftShowsTheExamples() async throws {
        let search = try await HeroSearch.shared.value
        for text in ["Louvre", "kebab"] {
            let result = try await search.search(request(text, scope: .wholeLibrary))
            let noMatch = try #require(result.noMatch, "\(text)")
            #expect(noMatch.kind == .placeNotFound(.unconfirmed), "\(text)")
            #expect(noMatch.offers.isEmpty)
            #expect(noMatch.examples.map(\.text) == ["Dubai trip", "Al-Nakheel Park", "Last Ramadan", "Videos from Riyadh this year", "5 years ago"])
        }
        // With an offer left, no examples.
        let ramadan = try await search.search(request("Al-Nakheel Park during Ramadan 2024", scope: .wholeLibrary))
        #expect(ramadan.noMatch?.offers.isEmpty == false && ramadan.noMatch?.examples.isEmpty == true)
    }
}

/// The chip texts of a result, in slot order.
enum QueryChipTitles {
    static func of(_ result: SearchResult) -> [String] { result.query.slots.map(\.chip) }
}
