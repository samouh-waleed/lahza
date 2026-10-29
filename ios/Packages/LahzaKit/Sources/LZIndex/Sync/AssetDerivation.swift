import Foundation
import LZGeo
import Synchronization
internal import GRDB

/// Where an asset's zone came from (`asset.tz_src`).
enum ZoneSource: Int, Sendable {
    /// The nearest gazetteer place to its own GPS (within 1,000 km).
    case gps = 0
    /// A located asset within ±12 h (the structure pass).
    case borrowed = 1
    /// The home base's zone for its local year (the structure pass).
    case home = 2
    /// The device's zone: GPS-less assets until the structure pass borrows a better one.
    case device = 3
    /// `Etc/GMT∓n` from its longitude, when no gazetteer place is within 1,000 km.
    case etcFallback = 4
}

/// Where an asset's effective position came from (`asset.place_src`).
enum PlaceSource: Int, Sendable {
    case none = 0, gps = 1, momentNear = 2, momentFar = 3
}

/// Gazetteer answers per geohash-7 cell (about 150 m), and `TimeZone` objects per identifier, shared across
/// batches. Lookups use the cell's centre, so an asset's zone and places don't depend on which neighbour was read
/// first. A cell keeps only its zone and place keys; each place's row values are kept once, by key.
final class GeoCache: Sendable {
    struct Cell: Sendable {
        var zone: String
        var zoneSource: ZoneSource
        /// `place.key`s from the gazetteer (``PlaceSpec``), nil where it has none.
        var city: String?
        var metro: String?
        var locality: String?
        var region: String?
        var country: String?
        /// The nearest place is within 50 km, or the 3 nearest within 150 km share the country.
        var countryConfident: Bool
    }

    private struct State {
        var cells: [String: Cell] = [:]
        var places: [String: PlaceSpec] = [:]
        var zones: [String: TimeZone] = [:]
    }

    /// Bounds the cache (a cell entry holds a few short keys); it starts over when full.
    static let capacity = 20_000

    let gazetteer: Gazetteer
    private let state = Mutex(State())

    init(gazetteer: Gazetteer) {
        self.gazetteer = gazetteer
    }

    func cell(_ hash: String) -> Cell {
        if let cached = state.withLock({ $0.cells[hash] }) { return cached }
        let centre = GeoHash.center(hash)
        let placement = gazetteer.locate(centre)
        var cell = placement.timeZone.map { Cell(zone: $0, zoneSource: .gps, countryConfident: placement.countryConfident) }
            ?? Cell(zone: LocalTime.etcZoneIdentifier(longitude: centre.longitude), zoneSource: .etcFallback,
                    countryConfident: placement.countryConfident)
        var specs: [PlaceSpec] = []
        func keep(_ spec: PlaceSpec?) -> String? {
            guard let spec else { return nil }
            specs.append(spec)
            return spec.key
        }
        cell.city = keep(placement.city.map(PlaceSpec.init(city:)))
        cell.metro = keep(placement.metro.map(PlaceSpec.init(city:)))
        cell.locality = keep(placement.locality.map(PlaceSpec.init(city:)))
        cell.region = keep(placement.admin1.flatMap(PlaceSpec.init(region:)))
        cell.country = keep(placement.countryCode.map(PlaceSpec.init(country:)))
        state.withLock { state in
            if state.cells.count >= Self.capacity { state.cells.removeAll(keepingCapacity: true) }
            state.cells[hash] = cell
            for spec in specs where state.places[spec.key] == nil { state.places[spec.key] = spec }
        }
        return cell
    }

    /// The row values of a gazetteer place key a ``Cell`` holds.
    func place(_ key: String) -> PlaceSpec? {
        state.withLock { $0.places[key] }
    }

    func timeZone(_ identifier: String) -> TimeZone {
        if let cached = state.withLock({ $0.zones[identifier] }) { return cached }
        let zone = TimeZone(identifier: identifier) ?? .gmt
        state.withLock { $0.zones[identifier] = zone }
        return zone
    }
}

/// The columns P0 derives inline for one asset: zone, wall time, moment day, cell and effective position.
/// The place columns (city … country) are the structure pass's: it places every asset of a dirty day.
struct DerivedColumns: Sendable, Hashable {
    var zone: Int64?
    var zoneSource: ZoneSource
    var wallSeconds: Int64?
    var day: Int32?
    var cell: String?
    var placeSource: PlaceSource
    var effectiveLatitude: Double?
    var effectiveLongitude: Double?
}

/// Derives an asset's columns inside one write transaction (zone ids are read per transaction, so a rolled-back
/// insert never leaves a stale id behind).
///
/// A located asset takes the zone of the gazetteer place nearest its cell (else the `Etc` zone for its
/// longitude). A GPS-less asset takes the device zone for now; the structure pass (P0b) borrows a better one
/// from located neighbours and marks the days it moves.
struct AssetDerivation {
    let geo: GeoCache
    let deviceZone: String
    private var zoneIDs: [String: Int64]

    init(_ db: Database, geo: GeoCache, deviceZone: String) throws {
        self.geo = geo
        self.deviceZone = deviceZone
        zoneIDs = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, name FROM zone") {
            zoneIDs[row["name"]] = row["id"]
        }
    }

    mutating func derive(_ record: AssetRecord, _ db: Database) throws -> DerivedColumns {
        try derive(created: record.created, coordinate: record.coordinate, db)
    }

    /// The columns for an asset created at `created` (unix seconds) at `coordinate` (a valid one, or nil).
    mutating func derive(created: Int64?, coordinate: Coordinate?, _ db: Database) throws -> DerivedColumns {
        var derived = DerivedColumns(zoneSource: .device, placeSource: .none)
        let zoneName: String?
        if let coordinate {
            let hash = GeoHash.encode(coordinate, precision: 7)
            let cell = geo.cell(hash)
            zoneName = cell.zone
            derived.zoneSource = cell.zoneSource
            derived.cell = hash
            derived.placeSource = .gps
            derived.effectiveLatitude = coordinate.latitude
            derived.effectiveLongitude = coordinate.longitude
        } else {
            // An undated GPS-less asset has no wall time to derive, so no zone either.
            zoneName = created == nil ? nil : deviceZone
        }
        if let zoneName {
            derived.zone = try zoneID(zoneName, db)
            if let created {
                let wall = LocalTime.wallSeconds(Date(timeIntervalSince1970: TimeInterval(created)), in: geo.timeZone(zoneName))
                derived.wallSeconds = wall
                derived.day = LocalTime.momentDay(wallSeconds: wall)
            }
        }
        return derived
    }

    /// The `zone` row for an IANA identifier, inserted on first use.
    mutating func zoneID(_ name: String, _ db: Database) throws -> Int64 {
        if let id = zoneIDs[name] { return id }
        try db.execute(sql: "INSERT OR IGNORE INTO zone (name) VALUES (?)", arguments: [name])
        let id = try Int64.fetchOne(db, sql: "SELECT id FROM zone WHERE name = ?", arguments: [name]) ?? db.lastInsertedRowID
        zoneIDs[name] = id
        return id
    }
}
