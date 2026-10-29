import Foundation
import LZCore
import LZGeo
import LZIndex
import Synchronization

/// Photo counts around a point: the index now, the in-memory search snapshot's grid later.
public protocol PlaceDensity: Sendable {
    /// Photos whose position (own or borrowed from their moment) is within `radius` metres of `center`.
    func count(near center: Coordinate, within radius: Double) async throws -> Int
    /// Photos placed in a country, region, city (its metro too) or locality: a place's photos before the structure
    /// pass has counted them (the first build).
    func members(level: MembershipLevel, placeID: Int64) async throws -> Int
    /// Distances of the photos with their own GPS within `radius` of `center` (hull refinement).
    func ownDistances(from center: Coordinate, within radius: Double) async throws -> [Double]
    /// The own GPS positions of the photos placed in a locality (an Apple Maps town's extent).
    func positions(inLocality placeID: Int64) async throws -> [Coordinate]
}

extension PlaceDensity {
    public func positions(inLocality placeID: Int64) async throws -> [Coordinate] { [] }
    public func members(level: MembershipLevel, placeID: Int64) async throws -> Int { 0 }
}

extension IndexReader: PlaceDensity {
    public func count(near center: Coordinate, within radius: Double) async throws -> Int {
        try await countWithin(center, radius: radius)
    }
}

/// The one Apple Maps search a query may make, shared by its place slots.
public final class MapsAllowance: Sendable {
    private let state: Mutex<(used: Bool, sent: Bool)>

    /// `spent`: the query may read cached answers only (a re-run).
    public init(spent: Bool = false) {
        state = Mutex((used: spent, sent: false))
    }

    /// Takes the search; false when this query already took it.
    func take() -> Bool {
        state.withLock { state in
            defer { state.used = true }
            return !state.used
        }
    }

    /// The request went out (the shared budget let it).
    func markSent() {
        state.withLock { $0.sent = true }
    }

    /// Whether this query sent Apple Maps a request.
    public var searched: Bool { state.withLock { $0.sent } }
}

/// What resolving a query's places may use.
public struct PlaceEnvironment: Sendable {
    public var reader: IndexReader
    /// Keeps Apple Maps answers and their places; nil to keep nothing.
    public var writer: UserDataWriter?
    public var density: any PlaceDensity
    /// Settings › Search index › Apple Maps place names.
    public var appleMapsEnabled: Bool
    /// Biases the Apple Maps search (home ±2°).
    public var searchRegion: GeoRegion?
    public var allowance: MapsAllowance

    public init(reader: IndexReader, writer: UserDataWriter?, density: (any PlaceDensity)? = nil, appleMapsEnabled: Bool, searchRegion: GeoRegion?,
                allowance: MapsAllowance = MapsAllowance()) {
        self.reader = reader
        self.writer = writer
        self.density = density ?? reader
        self.appleMapsEnabled = appleMapsEnabled
        self.searchRegion = searchRegion
        self.allowance = allowance
    }
}

/// Resolves place expressions (search spec §6.4), in order: saved places and home; a place the person picked for
/// these words before; the own index (FTS5, then a typo pass); the offline gazetteer and country names; and, only when
/// nothing found has a good match with photos, one Apple Maps search per query (cached for 30 days, its places kept in
/// the index). Then it picks: automatically when one candidate is clearly ahead, otherwise the best with a picker.
public actor PlaceResolver {
    /// How long an Apple Maps search answer is reused.
    public static let mapCacheAge = UserDataWriter.mapSearchMaxAge
    /// Areas with this many own photos within twice their radius get a radius fitted to those photos.
    static let hullMinimumPhotos = 20

    private let gazetteer: Gazetteer
    private let maps: any MapsClient
    private let budget: MapsBudget
    private let network: any NetworkStatus
    private let clock: any AppClock
    private let log = Log("places")

    public init(gazetteer: Gazetteer, maps: any MapsClient, budget: MapsBudget, network: any NetworkStatus, clock: any AppClock) {
        self.gazetteer = gazetteer
        self.maps = maps
        self.budget = budget
        self.network = network
        self.clock = clock
    }

    /// Resolves one place slot; `override` is what the person picked for it (a place, a radius, "near").
    public func resolve(_ expression: PlaceExpression, override: PlaceOverride? = nil, in environment: PlaceEnvironment) async throws -> PlaceResolution {
        let started = ContinuousClock.now
        var resolution: PlaceResolution
        if let key = override?.placeKey, let picked = try await candidate(forKey: key, in: environment) {
            resolution = .resolved(picked, alternatives: [])
        } else {
            resolution = try await resolveExpression(expression, in: environment)
        }
        let near = override?.near ?? (expression.relation == .near)
        resolution = adjusted(resolution, radius: override?.radius, near: near)
        log.debug("Place slot resolved: \(Self.outcome(resolution)), \(resolution.candidates.count) candidates, Apple Maps \(environment.allowance.searched ? 1 : 0), "
                  + "\(ContinuousClock.now - started)", privacy: .public)
        return resolution
    }

    private func resolveExpression(_ expression: PlaceExpression, in environment: PlaceEnvironment) async throws -> PlaceResolution {
        switch expression {
        case .alias(.home, _):
            return try await home(in: environment).map { .resolved($0, alternatives: []) } ?? .notFound(.noHome)
        case .alias(.saved(let id), _):
            guard let saved = try await environment.reader.savedPlaces().first(where: { $0.id == id }) else { return .notFound(.notFound) }
            return .resolved(try await savedCandidate(saved, in: environment), alternatives: [])
        case .category(let category, _):
            return try await categoryUnion(category, in: environment)
        case .picked(let key, _, _):
            return try await candidate(forKey: key, in: environment).map { .resolved($0, alternatives: []) } ?? .notFound(.notFound)
        case .named(let text, _, let confidence):
            return try await named(text, confidence: confidence, in: environment)
        case .anyOf(let parts):
            var chosen: [PlaceCandidate] = []
            var firstFailure: PlaceNotFound?
            for part in parts {
                let resolution = try await resolveExpression(part, in: environment)
                if let candidate = resolution.chosen { chosen.append(candidate) } else if case .notFound(let reason) = resolution { firstFailure = firstFailure ?? reason }
            }
            guard !chosen.isEmpty else { return .notFound(firstFailure ?? .notFound) }
            guard chosen.count > 1 else { return .resolved(chosen[0], alternatives: []) }
            let combined = PlaceCandidate(id: chosen.map(\.id).joined(separator: "|"), name: chosen.map(\.name).joined(separator: " or "), subtitle: "",
                                          photoCount: chosen.reduce(0) { $0 + $1.photoCount }, match: chosen.map(\.match).min() ?? .exact,
                                          source: chosen.map(\.source).min() ?? .ownIndex, resolved: .anyOf(chosen.map(\.resolved)))
            return .resolved(combined, alternatives: [])
        }
    }

    // MARK: Named places

    private func named(_ text: String, confidence: Confidence, in environment: PlaceEnvironment) async throws -> PlaceResolution {
        let folded = PlaceNames.fold(text)
        guard !folded.isEmpty else { return .notFound(confidence == .maybe ? .unconfirmed : .notFound) }
        let variants = PlaceNames.variants(text)
        var pool = CandidatePool()

        // Own index, then the typo pass inside it: a single typo hit is taken as is, without asking Apple Maps.
        let rows = try await environment.reader.searchPlaces(text, limit: 8)
        let typoHits = rows.filter { $0.match == .typo }
        for row in rows {
            let match = MatchQuality(row.match ?? .prefix)
            if confidence == .maybe, match == .prefix { continue }
            let candidate = try await ownCandidate(row, match: match, in: environment)
            // An Apple Maps place kept from an earlier search, without photos, takes maybe words only as a fresh answer
            // would: "Louvre" stays unconfirmed every time when Apple named it "Musée du Louvre".
            if confidence == .maybe, row.kind == .mapResult, candidate.photoCount == 0, !Self.acceptsMaybe(row.name, phrase: variants) { continue }
            pool.add(candidate)
        }

        // Gazetteer cities, regions and countries (offline; they may have no photos: "No photos in Paris, France").
        try await addGazetteerCandidates(variants: variants, folded: folded, confidence: confidence, to: &pool, in: environment)

        // A remembered pick wins; the rest stay as alternatives.
        if let choice = try await environment.reader.placeChoice(for: folded), var picked = try await candidate(forKey: choice.placeKey, in: environment) {
            if let radius = choice.radius { picked.resolved = Self.withRadius(picked.resolved, radius) }
            return .resolved(picked, alternatives: pool.sorted.filter { $0.id != picked.id })
        }
        if typoHits.count == 1, rows.count == 1, let only = pool.sorted.first(where: { $0.id == typoHits[0].key }) {
            return .resolved(only, alternatives: [])
        }

        // At most one Apple Maps search per query, only when nothing found is a good match with photos.
        var unavailable: PlaceNotFound?
        if !pool.candidates.contains(where: { $0.match >= .allTokens && $0.photoCount >= 1 }) {
            switch try await searchAppleMaps(text, folded: folded, in: environment) {
            case .places(let places):
                for place in places where confidence == .certain || Self.acceptsMaybe(place.name, phrase: variants) {
                    pool.add(try await mapCandidate(place, variants: variants, in: environment))
                }
            case .unavailable(let reason):
                unavailable = reason
            }
        }
        return pick(pool, confidence: confidence, unavailable: unavailable)
    }

    /// Exactly one candidate, or a top one with photos at least twice the next one's of an equal match, is taken
    /// automatically; otherwise search runs with the top one and offers a picker. A top one without photos is never
    /// taken over one with photos that matched less well ("Istanbul" and the person's Istanbul Grill): the picker
    /// offers it. With no photos anywhere the top one is taken (its search then finds nothing, which says so).
    private func pick(_ pool: CandidatePool, confidence: Confidence, unavailable: PlaceNotFound?) -> PlaceResolution {
        let sorted = pool.sorted
        guard let top = sorted.first else {
            // Words that only might be a place and match nothing exactly, Apple Maps included, are unconfirmed.
            if confidence == .maybe, unavailable == nil { return .notFound(.unconfirmed) }
            return .notFound(unavailable ?? .notFound)
        }
        let alternatives = Array(sorted.dropFirst())
        // A region or country named like the city on top ("Dubai", the emirate) holds the city: not a rival.
        let rivals = alternatives.filter { $0.match >= top.match && !$0.holds(top) }
        guard let runnerUp = rivals.first else {
            if top.photoCount == 0, alternatives.contains(where: { $0.photoCount > 0 }) {
                let withPhotos = alternatives.filter { $0.photoCount > 0 }, without = alternatives.filter { $0.photoCount == 0 }
                return .ambiguous(top: top, candidates: [top] + (withPhotos + without).prefix(4))
            }
            return .resolved(top, alternatives: alternatives)
        }
        if top.photoCount >= 1, top.photoCount >= 2 * runnerUp.photoCount { return .resolved(top, alternatives: alternatives) }
        if sorted.allSatisfy({ $0.photoCount == 0 }) { return .resolved(top, alternatives: alternatives) }
        return .ambiguous(top: top, candidates: Array(sorted.prefix(5)))
    }

    private func addGazetteerCandidates(variants: [String], folded: String, confidence: Confidence, to pool: inout CandidatePool,
                                        in environment: PlaceEnvironment) async throws {
        var found: [(key: String, build: (PlaceRow?) -> PlaceCandidate)] = []
        for variant in variants {
            for code in CountryNames.codes(matching: variant) {
                found.append((PlaceKey.country(code), { self.countryCandidate(code, row: $0) }))
            }
            for city in gazetteer.cities(exactlyNamed: variant, limit: 5) {
                found.append((PlaceKey.city(geonameID: city.geonameID), { self.cityCandidate(city, row: $0, match: .exact) }))
            }
            for region in gazetteer.admin1s(exactlyNamed: variant, limit: 3) where region.geonameID != 0 {
                found.append((PlaceKey.region(geonameID: region.geonameID), { self.regionCandidate(region, row: $0) }))
            }
        }
        if found.isEmpty, confidence == .certain, folded.count >= 4, !pool.candidates.contains(where: { $0.match == .exact }) {
            let exact = Set(gazetteer.cities(exactlyNamed: folded, limit: 50).map(\.geonameID))
            for city in gazetteer.cities(named: folded, limit: 6) where !exact.contains(city.geonameID) {
                found.append((PlaceKey.city(geonameID: city.geonameID), { self.cityCandidate(city, row: $0, match: .prefix) }))
            }
        }
        guard !found.isEmpty else { return }
        let rows = try await environment.reader.places(keys: found.map(\.key))
        for item in found {
            var candidate = item.build(rows[item.key])
            if let row = rows[item.key], case .membership(let level, _, _, _) = candidate.resolved {
                candidate.photoCount = try await photoCount(row, level, in: environment)
            }
            pool.add(candidate)
        }
    }

    /// A place row's photos: its count, or before the structure pass has counted them (the first build), its members
    /// in the snapshot, so a place already read is a good match and doesn't send its name to Apple Maps.
    private func photoCount(_ row: PlaceRow, _ level: MembershipLevel, in environment: PlaceEnvironment) async throws -> Int {
        row.photoCount > 0 ? row.photoCount : try await environment.density.members(level: level, placeID: row.id)
    }

    // MARK: Apple Maps

    private enum MapsAnswer {
        case places([MapPlace])
        case unavailable(PlaceNotFound)
    }

    /// The cached answer for these words, else one search if the query hasn't made it, the toggle is on, the network
    /// is up and the shared budget has an interactive token. The answer is cached (an empty one too) and its places
    /// join the index.
    private func searchAppleMaps(_ text: String, folded: String, in environment: PlaceEnvironment) async throws -> MapsAnswer {
        let key = Self.mapSearchKey(folded, region: environment.searchRegion)
        if let cached = try await environment.reader.cachedMapSearch(key: key, maxAge: Self.mapCacheAge, now: clock.now) { return .places(cached) }
        guard environment.appleMapsEnabled else { return .unavailable(.appleMapsOff) }
        guard network.isReachable else { return .unavailable(.offline) }
        guard environment.allowance.take() else { return .unavailable(.notFound) }
        guard try await budget.acquire(.interactive) else { return .unavailable(.mapsBusy) }
        environment.allowance.markSent()
        do {
            let places = try await maps.search(text, near: environment.searchRegion)
            await budget.reportSuccess()
            try? await environment.writer?.rememberMapResults(key: key, results: places)
            log.info("Apple Maps search: \(places.count) places", privacy: .public)
            return .places(places)
        } catch .notFound {
            await budget.reportSuccess()
            try? await environment.writer?.rememberMapResults(key: key, results: [])
            log.info("Apple Maps search: no places", privacy: .public)
            return .places([])
        } catch .throttled {
            await budget.reportThrottled()
            log.notice("Apple Maps search throttled", privacy: .public)
            return .unavailable(.mapsBusy)
        } catch .cancelled {
            throw CancellationError()
        } catch {
            log.notice("Apple Maps search failed: \(Self.code(error))", privacy: .public)
            return .unavailable(error == .offline ? .offline : .mapsBusy)
        }
    }

    /// The cache key: the folded words and the coarse region the search was biased to.
    static func mapSearchKey(_ folded: String, region: GeoRegion?) -> String {
        "\(folded)|\(region.map { GeoHash.encode($0.center, precision: 2) } ?? "-")"
    }

    /// Words that only might be a place accept an Apple Maps place whose name is the words themselves, or the words
    /// and a category word ("santorini" takes Santorini, "nakheel" Nakheel Park; "shawarma" never takes Shawarma House).
    static func acceptsMaybe(_ name: String, phrase variants: [String]) -> Bool {
        let categories = Lexicon.english.categories
        return PlaceNames.variants(name).contains { name in
            variants.contains { phrase in
                name == phrase || (name.hasPrefix(phrase + " ") && categories[String(name.dropFirst(phrase.count + 1))] != nil)
            }
        }
    }

    private static func code(_ error: MapsError) -> String {
        switch error {
        case .throttled: "throttled"
        case .offline: "offline"
        case .notFound: "notFound"
        case .cancelled: "cancelled"
        case .other: "other"
        }
    }

    // MARK: Candidates

    /// A candidate for a place key: an own place, else a gazetteer city or a country, home or a saved place.
    private func candidate(forKey key: String, in environment: PlaceEnvironment) async throws -> PlaceCandidate? {
        if key == PlaceKey.home { return try await home(in: environment) }
        if key.hasPrefix("saved:"), let id = Int64(key.dropFirst(6)),
           let saved = try await environment.reader.savedPlaces().first(where: { $0.id == id }) {
            return try await savedCandidate(saved, in: environment)
        }
        let row = try await environment.reader.places(keys: [key])[key]
        if let row, row.kind != .saved, row.kind != .home { return try await ownCandidate(row, match: .exact, in: environment) }
        if key.hasPrefix("gn:"), let id = Int32(key.dropFirst(3)), let city = gazetteer.city(geonameID: id) {
            return cityCandidate(city, row: row, match: .exact)
        }
        if key.hasPrefix("cc:") { return countryCandidate(String(key.dropFirst(3)), row: row) }
        return nil
    }

    private func ownCandidate(_ row: PlaceRow, match: MatchQuality, in environment: PlaceEnvironment) async throws -> PlaceCandidate {
        let country = row.countryCode.map(CountryNames.name)
        switch row.kind {
        case .country:
            return PlaceCandidate(id: row.key, name: row.name, subtitle: "Country", photoCount: try await photoCount(row, .country, in: environment),
                                  match: match, source: .ownIndex, resolved: .membership(level: .country, placeID: row.id, placeKey: row.key, center: nil))
        case .region:
            return PlaceCandidate(id: row.key, name: row.name, subtitle: ["Region", country].compactMap { $0 }.joined(separator: " · "), context: country,
                                  photoCount: try await photoCount(row, .region, in: environment), match: match, source: .ownIndex,
                                  resolved: .membership(level: .region, placeID: row.id, placeKey: row.key, center: row.center))
        case .city, .locality:
            let level: MembershipLevel = row.kind == .city ? .city : .locality
            let membership = ResolvedPlace.membership(level: level, placeID: row.id, placeKey: row.key, center: row.center)
            var candidate = PlaceCandidate(id: row.key, name: row.name, subtitle: [row.name, country].compactMap { $0 }.joined(separator: ", "),
                                           context: country, photoCount: try await photoCount(row, level, in: environment), match: match,
                                           source: .ownIndex, resolved: membership)
            if row.kind == .locality, row.isFromAppleMaps, let extent = try await localityExtent(row.id, in: environment) {
                // Apple names a town only for the photo cells it was asked about: its photos' area counts the
                // neighbouring cells too.
                candidate.resolved = .anyOf([membership, .area(center: extent.center, radius: extent.radius, category: .locality, placeKey: row.key)])
                candidate.photoCount = max(row.photoCount, try await environment.density.count(near: extent.center, within: extent.radius))
            }
            return candidate
        case .poi, .mapResult, .saved, .home:
            guard let center = row.center else {
                return PlaceCandidate(id: row.key, name: row.name, subtitle: "", photoCount: row.photoCount, match: match, source: .ownIndex,
                                      resolved: .membership(level: .locality, placeID: row.id, placeKey: row.key, center: nil))
            }
            let category = row.category ?? (row.kind == .home ? .home : .otherPOI)
            let base = row.radius ?? category.defaultRadius
            let radius = row.kind == .poi || row.kind == .mapResult ? try await refined(center, base, in: environment) : base
            let city = self.city(near: center)
            return PlaceCandidate(id: row.key, name: row.kind == .home ? Self.estimatedHome : row.name,
                                  subtitle: [Self.categoryName(category), city ?? country].compactMap { $0 }.joined(separator: " · "),
                                  context: city ?? country, photoCount: try await environment.density.count(near: center, within: radius), match: match,
                                  source: row.kind == .mapResult ? .appleMaps : row.kind == .home ? .home : row.kind == .saved ? .saved : .ownIndex,
                                  resolved: .area(center: center, radius: radius, category: category, placeKey: row.key))
        }
    }

    private func mapCandidate(_ place: MapPlace, variants: [String], in environment: PlaceEnvironment) async throws -> PlaceCandidate {
        let key = PlaceKey.mapPlace(place)
        let base = place.category.radius(boundingRadius: place.boundingRadius)
        let radius = place.kind == .poi ? try await refined(place.coordinate, base, in: environment) : base
        let names = PlaceNames.variants(place.name)
        let words = Set(variants.first?.split(separator: " ").map(String.init) ?? [])
        let match: MatchQuality = names.contains(where: variants.contains) ? .exact
            : names.contains(where: { words.isSubset(of: $0.split(separator: " ").map(String.init)) }) ? .allTokens : .prefix
        let context = place.cityName ?? city(near: place.coordinate) ?? place.countryCode.map(CountryNames.name)
        return PlaceCandidate(id: key, name: place.name, subtitle: [Self.categoryName(place.category), context].compactMap { $0 }.joined(separator: " · "),
                              context: context, photoCount: try await environment.density.count(near: place.coordinate, within: radius), match: match,
                              source: .appleMaps, resolved: .area(center: place.coordinate, radius: radius, category: place.category, placeKey: key))
    }

    private func cityCandidate(_ city: GazetteerCity, row: PlaceRow?, match: MatchQuality) -> PlaceCandidate {
        let country = CountryNames.name(city.countryCode)
        let level: MembershipLevel = row.map { $0.kind == .city ? .city : .locality } ?? (city.kind == .section ? .locality : .city)
        return PlaceCandidate(id: PlaceKey.city(geonameID: city.geonameID), name: city.name, subtitle: "\(city.name), \(country)", context: country,
                              photoCount: row?.photoCount ?? 0, match: match, source: row == nil ? .gazetteer : .ownIndex,
                              resolved: .membership(level: level, placeID: row?.id, placeKey: PlaceKey.city(geonameID: city.geonameID), center: city.coordinate))
    }

    private func regionCandidate(_ region: GazetteerAdmin1, row: PlaceRow?) -> PlaceCandidate {
        let country = CountryNames.name(region.countryCode)
        return PlaceCandidate(id: PlaceKey.region(geonameID: region.geonameID), name: region.name, subtitle: "Region · \(country)", context: country,
                              photoCount: row?.photoCount ?? 0, match: .exact, source: row == nil ? .gazetteer : .ownIndex,
                              resolved: .membership(level: .region, placeID: row?.id, placeKey: PlaceKey.region(geonameID: region.geonameID), center: nil))
    }

    private func countryCandidate(_ code: String, row: PlaceRow?) -> PlaceCandidate {
        PlaceCandidate(id: PlaceKey.country(code), name: CountryNames.name(code), subtitle: "Country", photoCount: row?.photoCount ?? 0, match: .exact,
                       source: row == nil ? .gazetteer : .ownIndex,
                       resolved: .membership(level: .country, placeID: row?.id, placeKey: PlaceKey.country(code), center: nil))
    }

    /// The saved home, else the estimated one (150 m around the latest home base).
    private func home(in environment: PlaceEnvironment) async throws -> PlaceCandidate? {
        if let saved = try await environment.reader.savedPlaces().first(where: \.isHome) { return try await savedCandidate(saved, in: environment) }
        guard let base = try await environment.reader.homeBase(year: nil) else { return nil }
        let radius = PlaceCategory.home.defaultRadius
        return PlaceCandidate(id: PlaceKey.home, name: Self.estimatedHome, subtitle: "Worked out from your photos",
                              photoCount: try await environment.density.count(near: base.center, within: radius), match: .alias, source: .home,
                              resolved: .area(center: base.center, radius: radius, category: .home, placeKey: PlaceKey.home))
    }

    private func savedCandidate(_ saved: SavedPlaceRow, in environment: PlaceEnvironment) async throws -> PlaceCandidate {
        PlaceCandidate(id: saved.key, name: saved.name, subtitle: saved.isHome ? "Home" : "Saved place",
                       photoCount: try await environment.density.count(near: saved.center, within: saved.radius), match: .alias, source: .saved,
                       resolved: .area(center: saved.center, radius: saved.radius, category: saved.isHome ? .home : .saved, placeKey: saved.key))
    }

    /// "at the beach": every point of interest or found place of the category with photos.
    private func categoryUnion(_ category: PlaceCategory, in environment: PlaceEnvironment) async throws -> PlaceResolution {
        let rows = try await environment.reader.places(kinds: [.poi, .mapResult, .saved], minPhotos: 1, limit: 500).filter { $0.category == category }
        var areas: [ResolvedPlace] = []
        var photos = 0
        for row in rows {
            guard let center = row.center else { continue }
            let radius = try await refined(center, row.radius ?? category.defaultRadius, in: environment)
            areas.append(.area(center: center, radius: radius, category: category, placeKey: row.key))
            photos += row.photoCount
        }
        guard !areas.isEmpty else { return .notFound(.noPlacesOfCategory) }
        let name = Self.categoryPlural(category)
        return .resolved(PlaceCandidate(id: "category:\(category.rawValue)", name: name, subtitle: "\(areas.count) places", photoCount: photos,
                                        match: .exact, source: .ownIndex, resolved: .categoryUnion(areas)), alternatives: [])
    }

    // MARK: Radius

    /// Hull refinement: with at least 20 own photos within 2r, the radius becomes the 90th-percentile distance plus
    /// 50 m, kept between r and 2r.
    private func refined(_ center: Coordinate, _ radius: Double, in environment: PlaceEnvironment) async throws -> Double {
        let distances = try await environment.density.ownDistances(from: center, within: 2 * radius).sorted()
        guard distances.count >= Self.hullMinimumPhotos else { return radius }
        let p90 = distances[Int((Double(distances.count - 1) * 0.9).rounded(.up))]
        return min(max(p90 + 50, radius), 2 * radius)
    }

    /// The area an Apple Maps town's photos cover: their median position, out to the 90th-percentile distance plus
    /// 1 km (2–10 km).
    private func localityExtent(_ placeID: Int64, in environment: PlaceEnvironment) async throws -> (center: Coordinate, radius: Double)? {
        let positions = try await environment.density.positions(inLocality: placeID)
        guard !positions.isEmpty else { return nil }
        let latitudes = positions.map(\.latitude).sorted(), longitudes = positions.map(\.longitude).sorted()
        let center = Coordinate(latitude: latitudes[latitudes.count / 2], longitude: longitudes[longitudes.count / 2])
        let distances = positions.map { $0.distance(to: center) }.sorted()
        let p90 = distances[Int((Double(distances.count - 1) * 0.9).rounded(.up))]
        return (center, min(max(p90 + Self.localityMargin, Self.localityMinimumRadius), Self.localityMaximumRadius))
    }

    static let localityMargin: Double = 1_000
    static let localityMinimumRadius: Double = 2_000
    static let localityMaximumRadius: Double = 10_000

    /// The person's radius replaces an area's; "near" doubles it (there is no minimum).
    private func adjusted(_ resolution: PlaceResolution, radius: Double?, near: Bool) -> PlaceResolution {
        func adjust(_ candidate: PlaceCandidate) -> PlaceCandidate {
            var candidate = candidate
            if let radius { candidate.resolved = Self.withRadius(candidate.resolved, radius) }
            if near { candidate.resolved = candidate.resolved.scaled(by: 2) }
            return candidate
        }
        switch resolution {
        case .resolved(let candidate, let alternatives): return .resolved(adjust(candidate), alternatives: alternatives.map(adjust))
        case .ambiguous(let top, let candidates): return .ambiguous(top: adjust(top), candidates: candidates.map(adjust))
        case .notFound: return resolution
        }
    }

    static func withRadius(_ place: ResolvedPlace, _ radius: Double) -> ResolvedPlace {
        if case .area(let center, _, let category, let key) = place { return .area(center: center, radius: radius, category: category, placeKey: key) }
        return place
    }

    // MARK: Words

    static let estimatedHome = "Home (estimated)"

    private func city(near center: Coordinate) -> String? {
        gazetteer.locate(center).city?.name
    }

    private static func outcome(_ resolution: PlaceResolution) -> String {
        switch resolution {
        case .resolved: "resolved"
        case .ambiguous: "ambiguous"
        case .notFound(let reason): "not found (\(reason.rawValue))"
        }
    }

    static func categoryName(_ category: PlaceCategory) -> String {
        switch category {
        case .restaurant: "Restaurant"
        case .cafe: "Café"
        case .bakery: "Bakery"
        case .store: "Shop"
        case .foodMarket: "Market"
        case .fitness: "Gym"
        case .address: "Address"
        case .hotel: "Hotel"
        case .home: "Home"
        case .otherPOI: "Place"
        case .museum: "Museum"
        case .landmark: "Landmark"
        case .castle: "Castle"
        case .school: "School"
        case .sportsField: "Sports field"
        case .stadium: "Stadium"
        case .marina: "Marina"
        case .park: "Park"
        case .campground: "Campground"
        case .zoo: "Zoo"
        case .amusementPark: "Amusement park"
        case .beach: "Beach"
        case .university: "University"
        case .golf: "Golf course"
        case .airport: "Airport"
        case .nationalPark: "National park"
        case .hiking: "Trail"
        case .physicalFeature: "Area"
        case .locality: "Town"
        case .saved: "Saved place"
        }
    }

    static func categoryPlural(_ category: PlaceCategory) -> String {
        switch category {
        case .beach: "Beaches"
        case .cafe: "Cafés"
        case .university: "Universities"
        case .store: "Malls"
        default: categoryName(category) + "s"
        }
    }
}

extension PlaceCandidate {
    /// A region or country with the same name as a city or locality it holds ("Dubai", the emirate, and Dubai).
    func holds(_ other: PlaceCandidate) -> Bool {
        guard case .membership = resolved, case .membership = other.resolved, resolved.breadth > other.resolved.breadth else { return false }
        return PlaceNames.fold(name) == PlaceNames.fold(other.name)
    }
}

extension ResolvedPlace {
    /// How much a place holds: areas, then localities, cities, regions and countries.
    var breadth: Int {
        switch self {
        case .area, .categoryUnion, .anyOf: 0
        case .membership(let level, _, _, _):
            switch level {
            case .locality: 1
            case .city: 2
            case .region: 3
            case .country: 4
            }
        }
    }
}

extension PlaceResolution {
    /// Every candidate it carries, chosen first.
    public var candidates: [PlaceCandidate] {
        switch self {
        case .resolved(let candidate, let alternatives): [candidate] + alternatives
        case .ambiguous(_, let candidates): candidates
        case .notFound: []
        }
    }
}

/// Candidates by place key: a place found twice keeps its best match, its photos and its earliest source.
private struct CandidatePool {
    private(set) var candidates: [PlaceCandidate] = []
    private var positions: [String: Int] = [:]

    mutating func add(_ candidate: PlaceCandidate) {
        guard let position = positions[candidate.id] else {
            positions[candidate.id] = candidates.count
            candidates.append(candidate)
            return
        }
        var kept = candidates[position]
        if candidate.match > kept.match { kept.match = candidate.match }
        if candidate.photoCount > kept.photoCount { kept.photoCount = candidate.photoCount }
        if candidate.source < kept.source {
            kept.source = candidate.source
            kept.resolved = candidate.resolved
        }
        candidates[position] = kept
    }

    /// Best match first, then (for places of the same name) the narrower one, then most photos, then the earlier
    /// source, then the order found.
    var sorted: [PlaceCandidate] {
        candidates.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if left.match != right.match { return left.match > right.match }
            if left.holds(right) || right.holds(left) { return right.holds(left) }
            if left.photoCount != right.photoCount { return left.photoCount > right.photoCount }
            if left.source != right.source { return left.source < right.source }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
