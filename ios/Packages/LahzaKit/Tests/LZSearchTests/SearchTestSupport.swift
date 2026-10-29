import Foundation
import LZCore
import LZGeo
import LZLibrary
@testable import LZIndex
@testable import LZSearch

/// Shared fixtures: the bundled gazetteer, the spec's fixed now, parse contexts and the hero seed's index.
enum SearchFixture {
    static let gazetteer: Gazetteer = {
        do { return try Gazetteer.bundled() } catch { fatalError("The bundled gazetteer must load: \(error)") }
    }()

    /// 2026-10-28T12:00+03:00, the spec's fixed now.
    static let now = Date(timeIntervalSince1970: 1_793_178_000)
    static let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    static let sydney = TimeZone(identifier: "Australia/Sydney")!
    /// The spec writes dates day first; tests pin the UK region to compare with its strings.
    static let uk = Locale(identifier: "en_GB")
    static let us = Locale(identifier: "en_US")

    static let parser = RulesQueryParser()

    static func context(_ vocabulary: PlaceVocabulary? = nil, locale: Locale = uk) -> ParseContext {
        ParseContext(now: now, vocabulary: vocabulary ?? PlaceVocabulary(gazetteer: gazetteer), locale: locale)
    }

    static func parse(_ text: String, _ vocabulary: PlaceVocabulary? = nil, locale: Locale = uk) -> ParsedQuery {
        parser.parse(text, context: context(vocabulary, locale: locale))
    }

    /// Saudi home context at the fixed now.
    static func saudi(years: ClosedRange<Int>? = 2021...2026) -> TimeResolver {
        TimeResolver(context: TimeContext(now: now, zone: riyadh, homeCountry: "SA", homeIsSouth: false, locale: uk, years: years))
    }

    /// The same now from a home in Sydney.
    static func sydneyHome(years: ClosedRange<Int>? = 2021...2026) -> TimeResolver {
        TimeResolver(context: TimeContext(now: now, zone: sydney, homeCountry: "AU", homeIsSouth: true, locale: uk, years: years))
    }

    /// Wall seconds of a local date and time.
    static func wall(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Int64 {
        Int64(LocalTime.day(year: year, month: month, day: day)) * 86_400 + Int64(hour * 3_600 + minute * 60)
    }

    // MARK: The hero index

    /// The hero seed's index (fake reader, structure pass, fake Apple Maps place names), as the app has it once
    /// place naming has run. Each call builds a fresh in-memory index, so tests may write to it.
    static func heroIndex(placeNames: Bool = true) async throws -> HeroIndex {
        let database = try IndexDatabase.open(.inMemory)
        let clock = FixedClock(now)
        let indexer = LibraryIndexer(database: database, reader: FakeLibraryReader(.seed(.hero)), gazetteer: gazetteer, clock: clock,
                                     deviceTimeZone: { riyadh })
        await indexer.enqueue(.sync(.launch))
        await indexer.settled()
        if placeNames {
            let queue = PlaceNameQueue(database: database, maps: SeedMaps.client(), budget: MapsBudget(perMinute: 60_000, capacity: 10_000, clock: clock),
                                       clock: clock, network: FakeNetworkStatus(reachable: true), notify: { await indexer.enqueue(.restructure) })
            await queue.run()
            await indexer.settled()
        }
        return HeroIndex(database: database, reader: IndexReader(database: database), writer: UserDataWriter(database: database, clock: clock))
    }

    /// The vocabulary the app would build for `reader`.
    static func vocabulary(_ reader: IndexReader) async throws -> PlaceVocabulary {
        PlaceVocabulary(savedAliases: PlaceVocabulary.aliases(for: try await reader.savedPlaces()), ownNames: try await reader.ownPlaceNames(),
                        gazetteer: gazetteer)
    }
}

struct HeroIndex: Sendable {
    let database: IndexDatabase
    let reader: IndexReader
    let writer: UserDataWriter
}

/// A search engine over a fresh hero index, with the fake Apple Maps it asks, at the spec's fixed now and the UK region.
struct HeroSearch: Sendable {
    let index: HeroIndex
    let maps: FakeMapsClient
    let engine: SearchEngine
    /// The engine's clock (searches read "now" from it).
    let clock: FixedClock

    init(reachable: Bool = true, placeNames: Bool = true, budget: MapsBudget? = nil, table: FakeMapsClient.Table = SeedMaps.hero) async throws {
        index = try await SearchFixture.heroIndex(placeNames: placeNames)
        maps = FakeMapsClient(table)
        let clock = FixedClock(SearchFixture.now)
        self.clock = clock
        engine = SearchEngine(gazetteer: SearchFixture.gazetteer, maps: maps, budget: budget ?? MapsBudget(clock: clock), clock: clock,
                              network: FakeNetworkStatus(reachable: reachable), locale: SearchFixture.uk, deviceTimeZone: { SearchFixture.riyadh })
    }

    /// One hero search for tests that only read (built once, so fewer indexes are built side by side).
    static let shared = Task { try await HeroSearch() }

    func search(_ text: String, index context: SearchIndexContext = SearchIndexContext()) async throws -> SearchResult {
        try await engine.search(SearchRequest(text: text), reader: index.reader, writer: index.writer, index: context)
    }

    func search(_ request: SearchRequest) async throws -> SearchResult {
        try await engine.search(request, reader: index.reader, writer: index.writer)
    }

    /// Apple Maps searches so far.
    var mapsSearches: Int { maps.calls.count { if case .search = $0 { true } else { false } } }
}

extension SearchResult {
    /// The seed items of the hits in a tier.
    func items(_ tier: Tier) -> [SeedItem] {
        hits.filter { $0.tier == tier }.compactMap { $0.utc.flatMap { SeedScenario.hero.item(matchingUTC: $0) } }
    }

    /// The reasons of the hit of a seed item.
    func reasons(of item: SeedItem) -> [String] {
        hits.first { $0.utc == item.utc }?.reasons.map(\.text) ?? []
    }
}

extension ParsedQuery {
    /// The slots' values, in text order.
    var values: [SlotValue] { slots.map(\.value) }

    /// The text each slot's span covers.
    var spanTexts: [String] { slots.map { $0.span?.substring(of: text) ?? "" } }
}
