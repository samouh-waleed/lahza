import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// The place resolver over the hero seed's index (search spec §9.1): aliases, remembered picks, own names and the 2×
/// rule, ties, the typo pass, the gazetteer offline, the one Apple Maps search per query and its cache, the
/// maybe-place rule, radii, hull refinement, "near" and categories. Expected counts come from the scenario.
@Suite struct PlaceResolverTests {
    static let hero = SeedScenario.hero

    /// A resolver over a fresh hero index, with the fake Apple Maps it asks.
    struct Setup {
        let index: HeroIndex
        let maps: FakeMapsClient
        let budget: MapsBudget
        let network: FakeNetworkStatus
        let resolver: PlaceResolver

        init(placeNames: Bool = true, table: FakeMapsClient.Table = SeedMaps.hero, reachable: Bool = true, budget: MapsBudget? = nil) async throws {
            index = try await SearchFixture.heroIndex(placeNames: placeNames)
            maps = FakeMapsClient(table)
            let clock = FixedClock(SearchFixture.now)
            self.budget = budget ?? MapsBudget(clock: clock)
            network = FakeNetworkStatus(reachable: reachable)
            resolver = PlaceResolver(gazetteer: SearchFixture.gazetteer, maps: maps, budget: self.budget, network: network, clock: clock)
        }

        func environment(appleMaps: Bool = true, allowance: MapsAllowance = MapsAllowance(), density: (any PlaceDensity)? = nil) -> PlaceEnvironment {
            PlaceEnvironment(reader: index.reader, writer: index.writer, density: density, appleMapsEnabled: appleMaps, searchRegion: nil,
                             allowance: allowance)
        }

        /// Parses `text` with the index's vocabulary and resolves its first place slot.
        func resolve(_ text: String, override: PlaceOverride? = nil, environment: PlaceEnvironment? = nil) async throws -> PlaceResolution {
            let vocabulary = try await SearchFixture.vocabulary(index.reader)
            let query = SearchFixture.parse(text, vocabulary)
            guard let slot = query.slots.first(where: { $0.kind == .place }), case .place(let place) = slot.value else {
                Issue.record("“\(text)” has no place slot")
                return .notFound(.notFound)
            }
            return try await resolver.resolve(place, override: override, in: environment ?? self.environment())
        }
    }

    private func area(_ resolution: PlaceResolution) -> (center: Coordinate, radius: Double, category: PlaceCategory, key: String)? {
        guard case .area(let center, let radius, let category, let key) = resolution.place else { return nil }
        return (center, radius, category, key)
    }

    // MARK: Aliases and picks

    @Test func homeIsTheEstimatedHomeUntilOneIsSaved() async throws {
        let setup = try await Setup()
        let home = try await setup.resolve("at home")
        #expect(home.chosen?.name == "Home (estimated)")
        #expect(area(home)?.radius == 150 && area(home)?.key == PlaceKey.home)
        #expect(home.chosen?.photoCount == Self.hero.items(.home).count + Self.hero.items(.summer2026).count)
        #expect(try await setup.resolve("near home").place.flatMap { if case .area(_, let radius, _, _) = $0 { radius } else { nil } } == 300)

        try await setup.index.database.write { db in
            try db.execute(sql: """
                INSERT INTO saved_place (id, name, name_folded, lat, lon, radius_m, is_home, created_utc, updated_utc)
                VALUES (3, 'Our flat', 'our flat', 24.748, 46.633, 100, 1, 0, 0)
                """)
        }
        let saved = try await setup.resolve("home")
        #expect(saved.chosen?.name == "Our flat" && saved.chosen?.source == .saved && area(saved)?.radius == 100)
    }

    @Test func noHomeYet() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let resolver = PlaceResolver(gazetteer: SearchFixture.gazetteer, maps: FakeMapsClient(), budget: MapsBudget(clock: FixedClock(SearchFixture.now)),
                                     network: FakeNetworkStatus(reachable: true), clock: FixedClock(SearchFixture.now))
        let reader = IndexReader(database: database)
        let resolution = try await resolver.resolve(.alias(.home, relation: .at), in: PlaceEnvironment(reader: reader, writer: nil, appleMapsEnabled: true,
                                                                                                         searchRegion: nil))
        #expect(resolution == .notFound(.noHome))
    }

    @Test func aSavedPlaceIsAnAlias() async throws {
        let setup = try await Setup()
        try await setup.index.database.write { db in
            try db.execute(sql: """
                INSERT INTO saved_place (id, name, name_folded, lat, lon, radius_m, is_home, created_utc, updated_utc)
                VALUES (7, 'My pitch', 'my pitch', 24.759, 46.644, 250, 0, 0, 0)
                """)
        }
        let vocabulary = try await SearchFixture.vocabulary(setup.index.reader)
        #expect(vocabulary.savedAliases == ["my pitch": 7, "pitch": 7])
        let resolution = try await setup.resolve("at my pitch")
        #expect(resolution.chosen?.name == "My pitch" && resolution.chosen?.match == .alias)
        #expect(area(resolution)?.radius == 250 && area(resolution)?.key == "saved:7")
        #expect(resolution.chosen?.photoCount == Self.hero.items(.nakheel).count, "every session is within 250 m of the park's centre")
    }

    @Test func aRememberedPickWinsAndKeepsTheOthers() async throws {
        let setup = try await Setup()
        let dubai = "mk:seed.salam-park-dubai"
        try await setup.index.writer.rememberChoice(phrase: "Salam Park", placeKey: dubai, radius: nil)
        let picked = try await setup.resolve("Salam Park")
        guard case .resolved(let chosen, let alternatives) = picked else { Issue.record("expected a resolved pick, got \(picked)"); return }
        #expect(chosen.id == dubai && chosen.context == "Dubai")
        #expect(chosen.photoCount == Self.hero.items(.dubai1).filter { $0.title == "Salam Park" }.count)
        #expect(alternatives.map(\.id).contains("mk:seed.salam-park"))
        #expect(setup.maps.calls.isEmpty)

        try await setup.index.writer.rememberChoice(phrase: "salam park", placeKey: dubai, radius: 1_000)
        #expect(area(try await setup.resolve("salam park"))?.radius == 1_000)
    }

    @Test func anOverrideFromAnEditWins() async throws {
        let setup = try await Setup()
        let override = PlaceOverride(placeKey: "mk:seed.salam-park-dubai", radius: 600, near: true)
        let resolution = try await setup.resolve("Salam Park", override: override)
        #expect(resolution.chosen?.id == "mk:seed.salam-park-dubai")
        #expect(area(resolution)?.radius == 1_200, "the picked radius, doubled by near")
    }

    // MARK: Own names

    @Test func anExactOwnNameWithTwiceThePhotosIsPicked() async throws {
        let setup = try await Setup()
        // An earlier Apple Maps search left the Dammam park in the index, with no photos.
        try await setup.index.writer.rememberMapResults(key: "earlier", results: SeedMaps.hero.searches["al nakheel park"] ?? [])
        let resolution = try await setup.resolve("Al-Nakheel Park")
        guard case .resolved(let park, let alternatives) = resolution else { Issue.record("expected resolved, got \(resolution)"); return }
        #expect(park.name == "Al-Nakheel Park" && park.match == .exact && park.source == .ownIndex)
        #expect(park.photoCount == Self.hero.items(.nakheel).count)
        #expect(area(resolution)?.category == .park && area(resolution)?.radius == 400)
        #expect(alternatives.contains { $0.subtitle == "Park · Dammam" && $0.photoCount == 0 })
        #expect(setup.maps.calls.isEmpty, "a good own match with photos never asks Apple Maps")
    }

    @Test func anExactTieIsAmbiguous() async throws {
        let setup = try await Setup()
        let resolution = try await setup.resolve("Salam Park")
        guard case .ambiguous(let top, let candidates) = resolution else { Issue.record("expected ambiguous, got \(resolution)"); return }
        let riyadh = Self.hero.items(.salam).count, dubai = Self.hero.items(.dubai1).filter { $0.title == "Salam Park" }.count
        #expect(top.context == "Riyadh" && top.photoCount == riyadh)
        #expect(candidates.map { "\($0.context ?? "") · \($0.photoCount)" } == ["Riyadh · \(riyadh)", "Dubai · \(dubai)"])
        #expect(riyadh < 2 * dubai, "10 is not twice 8")
    }

    @Test func theTypoPassFindsTheParkWithoutAppleMaps() async throws {
        let setup = try await Setup()
        let resolution = try await setup.resolve("nakhel prk")
        guard case .resolved(let park, _) = resolution else { Issue.record("expected resolved, got \(resolution)"); return }
        #expect(park.name == "Al-Nakheel Park" && park.match == .typo)
        #expect(park.photoCount == Self.hero.items(.nakheel).count)
        #expect(setup.maps.calls.isEmpty)
    }

    @Test func diriyahFoldsTheArabicArticle() async throws {
        let setup = try await Setup()
        for text in ["Diriyah", "Ad Diriyah", "ad-Dir'iyah"] {
            let resolution = try await setup.resolve(text)
            guard case .membership(let level, _, let key, _) = resolution.place else { Issue.record("\(text): \(resolution)"); continue }
            #expect(level == .locality && key.hasPrefix("gn:"), "\(text)")
            #expect(resolution.chosen?.photoCount == Self.hero.items(.diriyah).count, "\(text)")
        }
    }

    @Test func membershipPlacesFromTheIndex() async throws {
        let setup = try await Setup()
        let greece = try await setup.resolve("Greece")
        #expect(greece.place == .membership(level: .country, placeID: greece.place.flatMap { if case .membership(_, let id, _, _) = $0 { id } else { nil } },
                                            placeKey: "cc:GR", center: nil))
        #expect(greece.chosen?.photoCount == Self.hero.items(.greece).filter(\.isLocated).count)
        let dubai = try await setup.resolve("Dubai")
        guard case .resolved(let city, _) = dubai else { Issue.record("Dubai should not be ambiguous with its emirate: \(dubai)"); return }
        #expect(city.subtitle == "Dubai, United Arab Emirates")
        if case .membership(let level, _, _, _) = city.resolved { #expect(level == .city) } else { Issue.record("Dubai is a city") }
        let mykonos = try await setup.resolve("mykonos")
        #expect(mykonos.chosen?.id == "al:GR:mykonos", "Apple's town name after place naming")
        let either = try await setup.resolve("Dubai or Riyadh")
        guard case .anyOf(let parts) = either.place else { Issue.record("expected any of: \(either)"); return }
        #expect(parts.count == 2 && either.chosen?.name == "Dubai or Riyadh")
        #expect(setup.maps.calls.isEmpty)
    }

    @Test func theGazetteerWorksOffline() async throws {
        let setup = try await Setup(reachable: false)
        let paris = try await setup.resolve("Paris")
        guard case .resolved(let city, _) = paris else { Issue.record("expected Paris, France: \(paris)"); return }
        #expect(city.subtitle == "Paris, France" && city.photoCount == 0 && city.source == .gazetteer)
        #expect(try await setup.resolve("Riyadh").chosen?.photoCount ?? 0 > 0)
        #expect(try await setup.resolve("Sufra Grill") == .notFound(.offline), "no own place and no network")
        #expect(setup.maps.calls.isEmpty)
    }

    // MARK: Apple Maps

    @Test func oneAppleMapsSearchPerQueryAndItsCache() async throws {
        let setup = try await Setup()
        let allowance = MapsAllowance()
        let environment = setup.environment(allowance: allowance)
        let sufra = try await setup.resolve("Sufra Grill", environment: environment)
        #expect(sufra.chosen?.photoCount == Self.hero.items(.sufra).count)
        #expect(area(sufra)?.category == .restaurant && area(sufra)?.radius == 75)
        // A second place slot of the same query may not ask again.
        #expect(try await setup.resolve("Santorini", environment: environment) == .notFound(.notFound))
        #expect(setup.maps.calls == [.search("Sufra Grill", nil)])
        #expect(allowance.searched)

        // The next query reuses the cached answer and the place now in the index.
        let again = try await setup.resolve("Sufra Grill")
        #expect(again.chosen?.id == sufra.chosen?.id)
        #expect(setup.maps.calls.count == 1)
        let kept = try await setup.index.reader.places(keys: ["mk:seed.sufra-grill"])["mk:seed.sufra-grill"]
        #expect(kept?.kind == .mapResult)
        // An empty answer is cached too.
        #expect(try await setup.resolve("Narnia Gardens") == .notFound(.notAPlace))
        #expect(try await setup.resolve("Narnia Gardens") == .notFound(.notAPlace))
        #expect(setup.maps.calls.count == 2)
    }

    @Test func maybeWordsTakeOnlyAnExactName() async throws {
        var table = SeedMaps.hero
        table.searches["shawarma"] = [MapPlace(appleID: "shawarma-house", name: "Shawarma House", category: .restaurant,
                                               coordinate: Coordinate(latitude: 24.70, longitude: 46.68))]
        table.searches["nakheel"] = SeedMaps.hero.searches["al nakheel park"]
        let setup = try await Setup(placeNames: false, table: table)
        let santorini = try await setup.resolve("santorini")
        #expect(area(santorini)?.category == .physicalFeature && area(santorini)?.radius == 10_000)
        #expect(santorini.chosen?.photoCount == Self.hero.items(.greece).filter { ["Oia", "Fira"].contains($0.title) && $0.isLocated }.count)
        let mykonos = try await setup.resolve("Mykonos")
        #expect(area(mykonos)?.radius == 9_000, "before place naming, the island from the search")
        // "shawarma" is a content word, so it is never a place; resolving it as one still refuses Shawarma House.
        #expect(SearchFixture.parse("shawarma").values == [.visual("shawarma")])
        let shawarma = try await setup.resolver.resolve(.named("shawarma", relation: .in, confidence: .maybe), in: setup.environment())
        #expect(shawarma == .notFound(.notAPlace))
        #expect(PlaceResolver.acceptsMaybe("Al Nakheel Park", phrase: ["nakheel"]) && PlaceResolver.acceptsMaybe("Santorini", phrase: ["santorini"]))
        #expect(!PlaceResolver.acceptsMaybe("Shawarma House", phrase: ["shawarma"]))
        // "sunset" never reaches Apple Maps: it is a content word, not a place slot.
        #expect(SearchFixture.parse("sunset").values == [.visual("sunset")])
        #expect(setup.maps.calls == [.search("santorini", nil), .search("Mykonos", nil), .search("shawarma", nil)])
    }

    @Test func throttledOrOutOfRequestsMeansNoSearch() async throws {
        let clock = FixedClock(SearchFixture.now)
        let setup = try await Setup(budget: MapsBudget(perMinute: 30, capacity: 1, interactiveReserve: 0, clock: clock))
        setup.maps.failNext(.throttled)
        #expect(try await setup.resolve("Sufra Grill") == .notFound(.offline))
        #expect(await setup.budget.backoffUntil != nil, "a throttle backs every request off")
        #expect(try await setup.resolve("Santorini") == .notFound(.offline))
        #expect(setup.maps.calls.count == 1, "no request while backing off or out of tokens")
        // Own places still resolve.
        #expect(try await setup.resolve("Al-Nakheel Park").chosen?.photoCount == Self.hero.items(.nakheel).count)
    }

    @Test func theToggleOffKeepsSearchOnTheIndex() async throws {
        let setup = try await Setup()
        #expect(try await setup.resolve("Sufra Grill", environment: setup.environment(appleMaps: false)) == .notFound(.appleMapsOff))
        #expect(try await setup.resolve("Kingdom Centre", environment: setup.environment(appleMaps: false)).chosen != nil)
        #expect(setup.maps.calls.isEmpty)
    }

    @Test func aPlaceWithNoPhotosStillResolves() async throws {
        let setup = try await Setup()
        let paris = try await setup.resolve("Paris")
        #expect(paris.chosen?.subtitle == "Paris, France" && paris.chosen?.photoCount == 0, "search then says “No photos in Paris, France”")
        #expect(paris.candidates.contains { $0.source == .appleMaps && $0.subtitle.hasPrefix("Town") })
        guard case .area(_, let radius, _, _) = paris.candidates.first(where: { $0.source == .appleMaps })?.resolved else { return }
        #expect(radius == 3_000, "a town with no region from Apple: 3 km")
    }

    // MARK: Radii

    @Test func radiiNearAndHullRefinement() async throws {
        let setup = try await Setup()
        let kingdom = try await setup.resolve("near Kingdom Centre")
        #expect(area(kingdom)?.category == .landmark && area(kingdom)?.radius == 400, "200 m doubled; no minimum")
        #expect(kingdom.chosen?.photoCount == Self.hero.items(.kingdom).count)
        let beach = try await setup.resolve("JBR Beach")
        let radius = try #require(area(beach)?.radius)
        #expect(radius > 500 && radius <= 1_000, "at least 20 own photos within 1 km: fitted between r and 2r")

        struct Spread: PlaceDensity {
            func count(near center: Coordinate, within radius: Double) async throws -> Int { 30 }
            func ownDistances(from center: Coordinate, within radius: Double) async throws -> [Double] { Array(repeating: 600, count: 30) }
        }
        let spread = try await setup.resolve("Al-Nakheel Park", environment: setup.environment(density: Spread()))
        #expect(area(spread)?.radius == 650, "90th percentile 600 m + 50 m, between 400 and 800")
        struct Sparse: PlaceDensity {
            func count(near center: Coordinate, within radius: Double) async throws -> Int { 19 }
            func ownDistances(from center: Coordinate, within radius: Double) async throws -> [Double] { Array(repeating: 700, count: 19) }
        }
        #expect(area(try await setup.resolve("Al-Nakheel Park", environment: setup.environment(density: Sparse())))?.radius == 400, "under 20: unchanged")
    }

    @Test func categoriesUnionTheirPlacesWithPhotos() async throws {
        let setup = try await Setup()
        let beaches = try await setup.resolve("at the beach")
        guard case .categoryUnion(let places) = beaches.place else { Issue.record("expected a union: \(beaches)"); return }
        #expect(!places.isEmpty)
        #expect(places.allSatisfy { if case .area(_, _, let category, _) = $0 { category == .beach } else { false } })
        #expect(places.contains { $0.placeKey == "mk:seed.jbr-beach" })
        #expect(beaches.chosen?.name == "Beaches")
        #expect(try await setup.resolve("at the zoo") == .notFound(.noPlacesOfCategory))
        #expect(try await setup.resolve("near the park").place.map { if case .categoryUnion(let parks) = $0 { parks.count } else { 0 } } ?? 0 >= 3)
    }
}
