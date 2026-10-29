import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// Example searches (search spec §6.9): verified counts, the five rules in order, never a zero, and nothing for an
/// empty index.
@Suite struct ExampleSearchTests {
    static let hero = SeedScenario.hero

    @Test func theHeroLibraryGetsItsFiveExamples() async throws {
        let search = try await HeroSearch()
        let examples = try await search.engine.examples(reader: search.index.reader)
        let year2021 = Self.hero.items.count { $0.momentDay.map { LocalTime.civil(day: $0).year == 2021 } == true }
        let riyadhVideos2026 = Self.hero.items.count { $0.isVideo && [.nakheel, .summer2026].contains($0.tag) && LocalTime.civil(day: $0.momentDay!).year == 2026 }
        #expect(examples.map(\.text) == ["Dubai trip", "Al-Nakheel Park", "Last Ramadan", "Videos from Riyadh this year", "5 years ago"])
        #expect(examples[0].count == Self.hero.items(.dubai1).count + Self.hero.items(.dubai2).count)
        #expect(examples[1].count == Self.hero.items(.nakheel).count)
        #expect(examples[2].count >= 10)
        #expect(examples[3].count == riyadhVideos2026)
        #expect(examples[4].count == year2021)
        #expect(examples.allSatisfy { $0.count >= 3 })
        #expect(try await search.engine.examples(reader: search.index.reader) == examples, "deterministic")
        #expect(search.mapsSearches == 0, "examples never ask Apple Maps")
    }

    @Test func anEmptyIndexHasNoExamples() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let clock = FixedClock(SearchFixture.now)
        let engine = SearchEngine(gazetteer: SearchFixture.gazetteer, maps: FakeMapsClient(), budget: MapsBudget(clock: clock), clock: clock,
                                  network: FakeNetworkStatus(reachable: true))
        #expect(try await engine.examples(reader: IndexReader(database: database)).isEmpty)
    }
}
