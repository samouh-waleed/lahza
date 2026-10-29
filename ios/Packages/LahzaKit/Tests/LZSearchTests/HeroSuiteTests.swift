import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// The hero seed's 33 search goldens end to end (search spec §9.3) over the fake library, an in-memory index with
/// fake Apple Maps place names, and the spec's fixed now. Prints each golden's precision, recall and F1.
@Suite struct HeroSuiteTests {
    @Test func everyGoldenPasses() async throws {
        let index = try await SearchFixture.heroIndex()
        let maps = SeedMaps.client()
        let clock = FixedClock(HeroSuite.now)
        let engine = SearchEngine(gazetteer: SearchFixture.gazetteer, maps: maps, budget: MapsBudget(clock: clock), clock: clock,
                                  network: FakeNetworkStatus(reachable: true), locale: HeroSuite.locale, deviceTimeZone: { SearchFixture.riyadh })
        let outcomes = try await HeroSuite.run(engine: engine, reader: index.reader, writer: index.writer, facts: .fake) {
            maps.calls.count { if case .search = $0 { true } else { false } }
        }
        for outcome in outcomes { print("HERO \(outcome)") }
        let passed = outcomes.count(where: \.passed)
        print("HERO \(passed)/\(outcomes.count) pass, mean F1 \(String(format: "%.3f", outcomes.map(\.f1).reduce(0, +) / Double(max(1, outcomes.count))))")
        #expect(outcomes.count == 33)
        #expect(outcomes.allSatisfy { $0.skipped == nil }, "the fake library keeps every fact")
        for outcome in outcomes where !outcome.passed { Issue.record("\(outcome)") }
    }
}
