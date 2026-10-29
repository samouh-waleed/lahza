import Foundation
import LZGeo
internal import GRDB

/// `place.kind`.
public enum PlaceKind: Int, Sendable, Hashable, CaseIterable {
    case country = 1, region, city, locality, poi, saved, home, mapResult
}

/// `place.source`.
enum PlaceRowSource: Int, Sendable {
    case gazetteer = 1, appleMaps, user, inferred
}

/// The values of one `place` row and the names it is found by (folded into `place_name`).
struct PlaceSpec: Sendable, Hashable {
    /// `cc:SA`, `a1:<admin1 geonameid>`, `gn:<geonameid>`, `al:<CC>:<folded>`, `mk:<Apple id>`,
    /// `mkn:<folded>@<lat4>,<lon4>`, `home`, `saved:<id>`.
    var key: String
    var kind: PlaceKind
    var name: String
    /// Every display name and alias; each is folded with ``PlaceNames/variants(_:)``.
    var names: [String]
    var category: PlaceCategory?
    var coordinate: Coordinate?
    var radius: Double?
    var countryCode: String?
    var source: PlaceRowSource

    /// A gazetteer place: a city, or a locality for a city section (``DayBuilder`` makes it a locality where it
    /// is one).
    init(city: GazetteerCity) {
        key = "gn:\(city.geonameID)"
        kind = city.kind == .section ? .locality : .city
        name = city.name
        names = [city.name] + city.alternateNames
        coordinate = city.coordinate
        countryCode = city.countryCode
        source = .gazetteer
    }

    /// A first-level region; nil for the gazetteer's synthetic "no region" entry.
    init?(region: GazetteerAdmin1) {
        guard region.geonameID != 0 else { return nil }
        key = "a1:\(region.geonameID)"
        kind = .region
        name = region.name
        names = [region.name]
        countryCode = region.countryCode
        source = .gazetteer
    }

    /// A country, found by its English name and the common synonyms ("uae", "ksa").
    init(country code: String) {
        key = "cc:\(code)"
        kind = .country
        name = CountryNames.name(code)
        names = [name] + CountryNames.foldedNames(code)
        countryCode = code
        source = .gazetteer
    }

    /// A town Apple Maps' reverse geocode named where the gazetteer has no city.
    init(appleLocality name: String, countryCode: String?) {
        key = "al:\(countryCode ?? "--"):\(PlaceNames.fold(name))"
        kind = .locality
        self.name = name
        names = [name]
        self.countryCode = countryCode
        source = .appleMaps
    }

    /// An area Apple Maps named near a photo cell, with its category's radius.
    init(poi place: MapPlace) {
        self.init(mapPlace: place, kind: .poi)
    }

    /// A place an Apple Maps search found for a typed name (search's one request per query), with its category's
    /// radius (a region's half-diagonal for a natural feature or a town).
    init(mapResult place: MapPlace) {
        self.init(mapPlace: place, kind: .mapResult)
    }

    private init(mapPlace place: MapPlace, kind: PlaceKind) {
        key = PlaceKey.mapPlace(place)
        self.kind = kind
        name = place.name
        names = [place.name]
        category = place.category
        coordinate = place.coordinate
        radius = place.category.radius(boundingRadius: place.boundingRadius)
        countryCode = place.countryCode
        source = .appleMaps
    }

    init(key: String, kind: PlaceKind, name: String, names: [String], category: PlaceCategory? = nil, coordinate: Coordinate? = nil,
         radius: Double? = nil, countryCode: String? = nil, source: PlaceRowSource) {
        self.key = key
        self.kind = kind
        self.name = name
        self.names = names
        self.category = category
        self.coordinate = coordinate
        self.radius = radius
        self.countryCode = countryCode
        self.source = source
    }
}

/// Place row ids by key inside one write transaction: a row is inserted (with its names) on first use. Ids and
/// kinds are cached only for the transaction, so a rolled-back insert never leaves a stale id behind.
struct PlaceRows {
    let db: Database
    private var rows: [String: (id: Int64, kind: Int)] = [:]

    init(_ db: Database) {
        self.db = db
    }

    /// The row id for `spec`, inserting the row and its names when the key is new. With `refresh`, an existing
    /// row's name, category, position, radius and country are updated too (Apple Maps answers); its photo
    /// count never is.
    mutating func id(_ spec: PlaceSpec, refresh: Bool = false) throws -> Int64 {
        if !refresh, let cached = rows[spec.key] { return try upgraded(cached, to: spec) }
        if let row = try Row.fetchOne(db, sql: "SELECT id, kind FROM place WHERE key = ?", arguments: [spec.key]) {
            let id = try upgraded((row["id"], row["kind"]), to: spec)
            if refresh {
                try db.execute(sql: """
                    UPDATE place SET name = ?, category = ?, lat = ?, lon = ?, radius_m = ?, country_code = ? WHERE id = ?
                      AND (name IS NOT ? OR category IS NOT ? OR lat IS NOT ? OR lon IS NOT ? OR radius_m IS NOT ? OR country_code IS NOT ?)
                    """, arguments: [spec.name, spec.category?.rawValue, spec.coordinate?.latitude, spec.coordinate?.longitude, spec.radius,
                                     spec.countryCode, id, spec.name, spec.category?.rawValue, spec.coordinate?.latitude,
                                     spec.coordinate?.longitude, spec.radius, spec.countryCode])
                try insertNames(spec, id: id)
            }
            return id
        }
        try db.execute(sql: """
            INSERT INTO place (kind, key, name, category, lat, lon, radius_m, country_code, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [spec.kind.rawValue, spec.key, spec.name, spec.category?.rawValue, spec.coordinate?.latitude,
                             spec.coordinate?.longitude, spec.radius, spec.countryCode, spec.source.rawValue])
        let id = db.lastInsertedRowID
        try insertNames(spec, id: id)
        rows[spec.key] = (id, spec.kind.rawValue)
        return id
    }

    /// A gazetteer place first seen as a locality becomes a city once it is some photo's city, whichever came
    /// first in the transaction; an Apple Maps search result becomes a point of interest once place naming finds it
    /// near a photo cell (a point of interest never goes back to a search result).
    private mutating func upgraded(_ row: (id: Int64, kind: Int), to spec: PlaceSpec) throws -> Int64 {
        var kind = row.kind
        let upgrades: [(from: PlaceKind, to: PlaceKind)] = [(.locality, .city), (.mapResult, .poi)]
        if upgrades.contains(where: { $0.from.rawValue == kind && $0.to == spec.kind }) {
            try db.execute(sql: "UPDATE place SET kind = ? WHERE id = ?", arguments: [spec.kind.rawValue, row.id])
            kind = spec.kind.rawValue
        }
        rows[spec.key] = (row.id, kind)
        return row.id
    }

    private func insertNames(_ spec: PlaceSpec, id: Int64) throws {
        let statement = try db.cachedStatement(sql: "INSERT OR IGNORE INTO place_name (place_id, name) VALUES (?, ?)")
        var seen = Set<String>()
        for name in spec.names {
            for variant in PlaceNames.variants(name) where seen.insert(variant).inserted {
                try statement.execute(arguments: [id, variant])
            }
        }
    }
}
