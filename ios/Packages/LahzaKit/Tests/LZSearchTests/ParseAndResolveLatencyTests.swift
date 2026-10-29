import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// The query targets (search spec §6.9): a parse under 10 ms and an own-index place resolve under 20 ms, measured as the
/// 95th percentile on the Mac in the debug build `make test-kit` uses (release is faster).
@Suite struct ParseAndResolveLatencyTests {
    private func p95(_ samples: [Duration]) -> Duration {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
    }

    @Test func parsingTakesUnder10Milliseconds() {
        let vocabulary = ParserTableTests.knownVocabulary
        let texts = ParserTableTests.cases.map(\.text)
        for text in texts { _ = SearchFixture.parse(text, vocabulary) }            // warm the gazetteer's name index
        var samples: [Duration] = []
        for _ in 0..<3 {
            for text in texts {
                let started = ContinuousClock.now
                _ = SearchFixture.parse(text, vocabulary)
                samples.append(ContinuousClock.now - started)
            }
        }
        let percentile = p95(samples)
        print("LATENCY parse p95 \(percentile) over \(samples.count) parses")
        #expect(percentile < .milliseconds(10))
    }

    @Test func resolvingAnOwnPlaceTakesUnder20Milliseconds() async throws {
        let index = try await SearchFixture.heroIndex()
        let vocabulary = try await SearchFixture.vocabulary(index.reader)
        let clock = FixedClock(SearchFixture.now)
        let maps = SeedMaps.client()
        let resolver = PlaceResolver(gazetteer: SearchFixture.gazetteer, maps: maps, budget: MapsBudget(clock: clock),
                                     network: FakeNetworkStatus(reachable: true), clock: clock)
        let places = ["Al-Nakheel Park", "Riyadh", "Greece", "nakhel prk", "Salam Park", "Diriyah", "at home", "near Kingdom Centre", "Dubai", "mykonos"]
            .compactMap { text -> PlaceExpression? in
                guard case .place(let place) = SearchFixture.parse(text, vocabulary).slots.first(where: { $0.kind == .place })?.value else { return nil }
                return place
            }
        #expect(places.count == 10)
        let environment = PlaceEnvironment(reader: index.reader, writer: index.writer, appleMapsEnabled: true, searchRegion: nil)
        for place in places { _ = try await resolver.resolve(place, in: environment) }
        var samples: [Duration] = []
        for _ in 0..<10 {
            for place in places {
                let started = ContinuousClock.now
                _ = try await resolver.resolve(place, in: environment)
                samples.append(ContinuousClock.now - started)
            }
        }
        let percentile = p95(samples)
        print("LATENCY own-index resolve p95 \(percentile) over \(samples.count) resolves")
        #expect(percentile < .milliseconds(20))
        #expect(maps.calls.isEmpty)
    }
}
