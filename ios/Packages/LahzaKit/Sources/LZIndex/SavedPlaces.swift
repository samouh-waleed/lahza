import Foundation
import LZGeo
internal import GRDB

/// What Lahza uses as home (search spec §4.4): the estimate from night photos, a saved place the person set as home,
/// or no home at all (no trips).
public enum HomeSetting: Sendable, Hashable {
    /// Worked out from where photos are taken at night; nil until there are enough of them.
    case estimated(HomeBaseRow?)
    /// A saved place set as home ("Home" when it was picked from the night places).
    case saved(SavedPlaceRow)
    /// The person chose No home: Lahza groups no trips and "home" finds nothing.
    case noHome
}

/// Settings › Saved places › Home › Change…: what home becomes.
public enum HomeChoice: Sendable, Hashable {
    /// Back to the estimate.
    case estimated
    /// A saved place.
    case place(Int64)
    /// A night place from the picker: saved as "Home" (150 m).
    case point(Coordinate)
    /// No home.
    case noHome
}

/// A place where photos are taken at night (a geohash-6 tile), offered as home.
public struct HomeCandidate: Sendable, Hashable, Identifiable {
    /// Geohash-6.
    public var tile: String
    /// The median of its night photos.
    public var center: Coordinate
    /// What most of its night photos' moments are labelled (a park, a hotel, a town), else its town or city.
    public var name: String?
    /// Distinct days with night photos there.
    public var nights: Int
    /// The tile Lahza estimates as home (the latest year's best night tile).
    public var isEstimate: Bool

    public var id: String { tile }
}

/// Why a saved place couldn't be written.
public enum SavedPlaceError: Error, Sendable, Hashable {
    /// The name is empty once trimmed.
    case emptyName
    /// Another saved place has the same name (folded).
    case nameTaken
    /// The place is gone.
    case notFound
}

/// The saved-place rules shared by the writer and the screens.
public enum SavedPlaceRules {
    /// The radius choices, in metres.
    public static let radii: [Double] = [100, 250, 1_000]
    public static let defaultRadius: Double = 250
    /// A night place picked as home is saved with the home's radius.
    public static let homeRadius: Double = 150
    public static let maxNameLength = 40

    /// The name as it is stored: trimmed, single-spaced.
    public static func cleaned(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A place named "Home" is the home: the picker saves its night place under that name.
    public static func isHomeName(_ name: String) -> Bool { PlaceNames.fold(name) == "home" }
}

/// The saved-place writes inside one ``UserDataWriter`` transaction (search spec §2.4, §7.4): `saved_place`, its
/// mirror in `place` (kind 6, key `saved:<id>`, with its name variants), and the dirty days a change of area touches.
enum SavedPlaceRows {
    struct Stored: Hashable {
        var id: Int64
        var name: String
        var center: Coordinate
        var radius: Double
        var isHome: Bool
    }

    static func fetch(_ db: Database, id: Int64) throws -> Stored? {
        try Row.fetchOne(db, sql: "SELECT id, name, lat, lon, radius_m, is_home FROM saved_place WHERE id = ?", arguments: [id]).map(stored)
    }

    static func all(_ db: Database) throws -> [Stored] {
        try Row.fetchAll(db, sql: "SELECT id, name, lat, lon, radius_m, is_home FROM saved_place ORDER BY id").map(stored)
    }

    private static func stored(_ row: Row) -> Stored {
        Stored(id: row["id"], name: row["name"], center: Coordinate(latitude: row["lat"], longitude: row["lon"]), radius: row["radius_m"],
               isHome: row["is_home"])
    }

    /// Fails when the name is empty or another place (not `id`) already has it. A place named "Home" replaces the
    /// home picked earlier (the place that has that name).
    static func checkName(_ db: Database, _ name: String, excluding id: Int64?) throws -> String {
        let folded = PlaceNames.fold(name)
        guard !folded.isEmpty else { throw SavedPlaceError.emptyName }
        guard let other = try Int64.fetchOne(db, sql: "SELECT id FROM saved_place WHERE name_folded = ?", arguments: [folded]), other != id else {
            return folded
        }
        guard SavedPlaceRules.isHomeName(name), let home = try fetch(db, id: other) else { throw SavedPlaceError.nameTaken }
        try delete(db, home)
        return folded
    }

    /// Writes the place's `place` row and names (search finds it by name; the structure pass labels moments with it).
    static func mirror(_ db: Database, _ place: Stored) throws {
        let key = PlaceKey.saved(place.id)
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM place WHERE key = ?", arguments: [key]) {
            // A rename replaces the names (the FTS triggers follow).
            try db.execute(sql: "DELETE FROM place_name WHERE place_id = ?", arguments: [id])
        }
        var places = PlaceRows(db)
        _ = try places.id(PlaceSpec(key: key, kind: .saved, name: place.name, names: names(place.name), category: place.isHome ? .home : .saved,
                                    coordinate: place.center, radius: place.radius, source: .user), refresh: true)
    }

    /// Every saved place's mirror (after a rebuild at open imported `saved_place` into an empty file).
    static func mirrorAll(_ db: Database) throws {
        for place in try all(db) { try mirror(db, place) }
    }

    static func deleteMirror(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM place WHERE key = ?", arguments: [PlaceKey.saved(id)])
    }

    /// The display name and, like the parse vocabulary, the name without a leading "my", "our" or "the" ("My pitch" →
    /// "pitch").
    static func names(_ name: String) -> [String] {
        var names = [name]
        let words = name.split(separator: " ")
        if words.count > 1, ["my", "our", "the"].contains(words[0].lowercased()) { names.append(words.dropFirst().joined(separator: " ")) }
        return names
    }

    /// Marks dirty the days with photos or moments around `center` (a cell's width beyond `radius`), so their moments
    /// are labelled again.
    static func markDirty(_ db: Database, around center: Coordinate, radius: Double) throws {
        let reach = radius + 150
        let latitudeSpan = reach / 111_320
        let longitudeSpan = reach / (111_320 * max(0.01, cos(center.latitude * .pi / 180)))
        let box: StatementArguments = [center.latitude - latitudeSpan, center.latitude + latitudeSpan,
                                       center.longitude - longitudeSpan, center.longitude + longitudeSpan]
        try db.execute(sql: """
            INSERT OR IGNORE INTO dirty_day
            SELECT day FROM asset WHERE day IS NOT NULL AND eff_lat BETWEEN ? AND ? AND eff_lon BETWEEN ? AND ?
            UNION SELECT day FROM moment WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
            """, arguments: box + box)
    }

    /// Makes `id` the only home (nil: none) and drops a "Home" place picked earlier that isn't it.
    static func setHome(_ db: Database, id: Int64?) throws {
        for previous in try all(db) where previous.id != id && (previous.isHome || SavedPlaceRules.isHomeName(previous.name)) {
            if SavedPlaceRules.isHomeName(previous.name) {
                try delete(db, previous)
            } else {
                try db.execute(sql: "UPDATE saved_place SET is_home = 0 WHERE id = ?", arguments: [previous.id])
                var place = previous
                place.isHome = false
                try mirror(db, place)
            }
        }
        if let id, var place = try fetch(db, id: id), !place.isHome {
            try db.execute(sql: "UPDATE saved_place SET is_home = 1 WHERE id = ?", arguments: [id])
            place.isHome = true
            try mirror(db, place)
        }
    }

    /// Deletes the place, its mirror and the picks remembered for it (a later place may get its id).
    static func delete(_ db: Database, _ place: Stored) throws {
        try markDirty(db, around: place.center, radius: place.radius)
        try db.execute(sql: "DELETE FROM saved_place WHERE id = ?", arguments: [place.id])
        try deleteMirror(db, id: place.id)
        try db.execute(sql: "DELETE FROM place_choice WHERE place_key = ?", arguments: [PlaceKey.saved(place.id)])
    }
}
