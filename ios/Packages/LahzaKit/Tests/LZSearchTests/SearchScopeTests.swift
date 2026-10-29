import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// A free search's last 12 months (decision 34, E11) on the hero library at the spec's now, with expectations from the
/// scenario's dates: what is shown, what is counted as locked, the answer when every match is older, offers and
/// examples that count what a tap shows; and E17, the examples after a no-match with no offer left.
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

    /// Facts about the library count every year; an offer counts what its tap shows.
    @Test func offersCountWhatATapShows() async throws {
        let search = try await HeroSearch.shared.value
        let dubai = Self.hero.items(.dubai1).filter(\.isLocated) + Self.hero.items(.dubai2).filter(\.isLocated)
        let free = try await search.search(request("Dubai last December"))
        let noMatch = try #require(free.noMatch)
        #expect(noMatch.kind == .combination)
        #expect(noMatch.headline.hasPrefix("\(dubai.count) in Dubai, none in "), "never reads as if Dubai weren't there")
        #expect(!noMatch.offers.contains { $0.label.hasPrefix("Dubai") }, "every Dubai photo is older: no tap to show 0")
        let december = try #require(noMatch.offers.first)
        let unlocked = try await search.search(request("Dubai last December", scope: .wholeLibrary))
        #expect(unlocked.noMatch?.offers.first { $0.label == december.label }?.count == december.count, "December 2025 is inside the window")
        #expect(unlocked.noMatch?.offers.first?.label.hasPrefix("Dubai") == true && unlocked.lockedCount == 0)
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
