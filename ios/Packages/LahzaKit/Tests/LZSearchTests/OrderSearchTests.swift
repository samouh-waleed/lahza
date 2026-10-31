import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// "The first time", "the last time" and "oldest first" on the hero library, with expectations from the scenario: the
/// whole first trip for a place away from home, a visit for a park, the row that shows every time, the order of cards,
/// trips and grid tiles, a free search whose first time is older than it covers, and "recently" beside a year.
@Suite struct OrderSearchTests {
    static let hero = SeedScenario.hero

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Int32 { LocalTime.day(year: year, month: month, day: day) }

    private func numbers(_ items: [SeedItem]) -> Set<Int> { Set(items.map(\.number)) }

    private func orderSlot(_ result: SearchResult) throws -> ResolvedSlot {
        try #require(result.query.slots.first { $0.slot.kind == .order })
    }

    // MARK: The first time

    /// A city away from home: the whole earliest trip, under its header, in time order, and "1 later trip".
    @Test func theFirstTimeInDubaiIsTheWholeFirstTrip() async throws {
        let search = try await HeroSearch.shared.value
        let result = try await search.search("the first time I went to Dubai")
        #expect(numbers(result.items(.best)) == numbers(Self.hero.items(.dubai1)))
        #expect(result.items(.more).isEmpty && result.sections.count == 1)
        let section = try #require(result.sections.first)
        #expect(section.title == "First time in Dubai")
        guard case .trip(let trip)? = section.groups.first, section.groups.count == 1 else {
            Issue.record("one trip group, got \(section.groups.count)")
            return
        }
        #expect(trip.trip.startDay == Self.day(2024, 4, 11))
        let starts = trip.cards.map(\.id.startUTC)
        #expect(starts == starts.sorted(), "the trip reads in time order")

        let occasion = try #require(result.occasion)
        let slot = try orderSlot(result)
        #expect(occasion.order == .first && occasion.isTrip && occasion.others == 1)
        #expect(occasion.othersLabel == "1 later trip")
        #expect(occasion.showAll == [.replaceOrder(slot: slot.id, .oldestFirst)])
        #expect(slot.chip == "First time")
        #expect(result.totals.moments == trip.cards.count && result.lockedCount == 0)
    }

    /// A park: the earliest visit, and the later ones counted.
    @Test func theFirstTimeAtTheParkIsItsFirstVisit() async throws {
        let search = try await HeroSearch.shared.value
        let result = try await search.search("the first time at Al-Nakheel Park")
        let nakheel = Self.hero.items(.nakheel)
        #expect(numbers(result.items(.best)) == numbers(nakheel.filter { $0.momentDay == Self.day(2024, 3, 2) }))
        #expect(result.sections.first?.title == "First time at Al-Nakheel Park")
        #expect(result.cards.count == 1)
        #expect(result.occasion?.isTrip == false)
        #expect(result.occasion?.othersLabel == "9 later times")
    }

    /// "Show all" after the first time lists every visit oldest first, its chip now Oldest first.
    @Test func showAllListsEveryTimeOldestFirst() async throws {
        let search = try await HeroSearch.shared.value
        let first = try await search.search("the first time at Al-Nakheel Park")
        let showAll = try #require(first.occasion?.showAll)
        let query = first.query.parsed.applying(showAll, locale: SearchFixture.uk)
        #expect(query.text == "oldest first at Al-Nakheel Park")
        let all = try await search.search(SearchRequest(text: query.text, parsed: query))
        #expect(numbers(all.items(.best)) == numbers(Self.hero.items(.nakheel)))
        #expect(all.occasion == nil)
        #expect(try orderSlot(all).chip == "Oldest first")
        let days = all.sections.first { $0.tier == .best }?.groups.flatMap(\.cards).map(\.id.day) ?? []
        #expect(days == days.sorted() && days.count == 10)
    }

    // MARK: The last time

    @Test func theLastTimeAtTheParkIsItsLatestVisit() async throws {
        let search = try await HeroSearch.shared.value
        let result = try await search.search("last time at Al-Nakheel Park")
        let nakheel = Self.hero.items(.nakheel)
        #expect(numbers(result.items(.best)) == numbers(nakheel.filter { $0.momentDay == Self.day(2026, 8, 22) }))
        #expect(result.sections.first?.title == "Last time at Al-Nakheel Park")
        let occasion = try #require(result.occasion)
        let slot = try orderSlot(result)
        #expect(occasion.othersLabel == "9 earlier times")
        #expect(occasion.showAll == [.remove(slot: slot.id)], "Show all goes back to newest first")
    }

    /// A photo saved late at home doesn't beat a real outing: the last time on a park day is the park, not the
    /// received photo at 23:40.
    @Test func aReceivedPhotoDoesntBeatAnOuting() async throws {
        let search = try await HeroSearch.shared.value
        let parkDay = Self.day(2025, 2, 8)
        let received = Self.hero.items(.received).filter { $0.momentDay == parkDay }
        #expect(!received.isEmpty, "the scenario saves a photo late on this park day")
        let everything = try await search.search("8 February 2025")
        #expect(!numbers(everything.items(.best)).isDisjoint(with: numbers(received)), "a dates-only search lists it as Best")

        let result = try await search.search("the last time on 8 February 2025")
        let best = numbers(result.items(.best))
        #expect(!best.isEmpty && best.isDisjoint(with: numbers(received)))
        #expect(best.isSubset(of: numbers(Self.hero.items.filter { $0.momentDay == parkDay && $0.tag != .received })))
    }

    // MARK: Oldest first

    /// Cards, trip groups and grid tiles go oldest to newest; the "No date" card stays last.
    @Test func oldestFirstOrdersCardsTripsAndTheGrid() async throws {
        let search = try await HeroSearch.shared.value
        let park = try await search.search("Al-Nakheel Park oldest first")
        #expect(numbers(park.items(.best)) == numbers(Self.hero.items(.nakheel)))
        for section in park.sections {
            let starts = section.groups.flatMap(\.cards).filter { $0.id != MomentCard.noDateKey }.map(\.id.startUTC)
            #expect(starts == starts.sorted(), "\(section.title)")
        }
        let tiles = ResultGrid(park, showsUnknown: true).tiles.filter { $0.hit.tier == .best }.compactMap(\.hit.utc)
        #expect(tiles == tiles.sorted(), "the grid keeps the order")

        let trips = try await search.search("trips oldest first")
        let starts = trips.sections.first?.groups.compactMap { group -> Int32? in if case .trip(let trip) = group { trip.trip.startDay } else { nil } }
        #expect(starts == Self.hero.trips.map(\.firstDay).sorted())

        let newest = try await search.search("Al-Nakheel Park newest first")
        let days = newest.sections.first?.groups.flatMap(\.cards).map(\.id.day) ?? []
        #expect(days == days.sorted(by: >) && days.count == 10)
        #expect(try orderSlot(newest).chip == "Newest first")
    }

    // MARK: Free

    /// A free search whose first time is older than its months says so, with the older photos for the unlock row,
    /// and never shows the earliest visit it covers as the first.
    @Test func aFreeSearchSaysTheFirstTimeIsEarlier() async throws {
        let search = try await HeroSearch.shared.value
        let first = try await search.search(SearchRequest(text: "the first time at Al-Nakheel Park", scope: SearchScopeTests.free))
        let noMatch = try #require(first.noMatch)
        #expect(noMatch.kind == .onlyEarlier)
        #expect(noMatch.headline == "Your first time at Al-Nakheel Park was before the last 12 months.")
        #expect(first.hits.isEmpty && first.occasion == nil)
        let older = Self.hero.items(.nakheel).filter { ($0.utc ?? .max) < Int64(SearchScopeTests.since.timeIntervalSince1970) }
        #expect(first.lockedCount >= older.count)

        // The last time is inside the months: the visit, the earlier ones it covers, no unlock row.
        let last = try await search.search(SearchRequest(text: "the last time at Al-Nakheel Park", scope: SearchScopeTests.free))
        #expect(numbers(last.items(.best)) == numbers(Self.hero.items(.nakheel).filter { $0.momentDay == Self.day(2026, 8, 22) }))
        #expect(last.occasion?.othersLabel == "3 earlier times")
        #expect(last.lockedCount == 0)
    }

    // MARK: Words

    @Test func anOrderAloneAsksForSomethingToFind() async throws {
        let search = try await HeroSearch.shared.value
        let first = try await search.search("the first time")
        #expect(first.noMatch?.headline == "Add a place, a date or a photo type, like “the first time at the beach”.")
        #expect(first.noMatch?.examples.isEmpty == false)
        let oldest = try await search.search("oldest first")
        #expect(oldest.noMatch?.headline == "Add a place, a date or a photo type, like “the beach, oldest first”.")
    }

    @Test func wordsLeftOutNameTheOccasionShown() async throws {
        let search = try await HeroSearch.shared.value
        let result = try await search.search("soccer the first time at Al-Nakheel Park")
        #expect(result.unsupportedNotice == "Lahza can’t see what’s in photos yet, so “soccer” was left out. Showing your first time at Al-Nakheel Park.")
    }

    /// "recently, in 2026" searches 2026, not the past 30 days of it.
    @Test func recentlyBesideAYearSearchesTheYear() async throws {
        let search = try await HeroSearch.shared.value
        let recently = try await search.search("recently, in 2026")
        let year = try await search.search("2026")
        #expect(numbers(recently.items(.best)) == numbers(year.items(.best)))
        #expect(recently.query.slots.map(\.chip) == year.query.slots.map(\.chip))
    }
}
