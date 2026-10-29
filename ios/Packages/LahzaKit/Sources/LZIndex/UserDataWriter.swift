import Foundation
import LZCore
import LZGeo
internal import GRDB

/// Search's and Settings' targeted writes (search spec §2.4): Apple Maps search answers (the cache and their places,
/// which join the own index), the places the person picked for a phrase, saved places and the home choice. Each call
/// is one transaction that touches only these tables (and `dirty_day`, `meta`), so it never clobbers the indexer's or
/// place naming's rows.
///
/// A saved-place write mirrors the place into `place` (kind 6) with its name variants, marks dirty the days around it,
/// marks the library-wide structure steps due (place counts, home, trips) and bumps the index version, then asks for
/// a restructure (`changed`), so moment labels read the saved name and screens and the parse vocabulary refresh.
public struct UserDataWriter: Sendable {
    let database: IndexDatabase
    let clock: any AppClock
    /// Asks the indexer to restructure (the session enqueues `.restructure`).
    let changed: @Sendable () async -> Void

    /// How long an Apple Maps search answer is kept: older ones are dropped at the next write.
    public static let mapSearchMaxAge: Duration = .seconds(30 * 86_400)

    init(database: IndexDatabase, clock: any AppClock, changed: @escaping @Sendable () async -> Void = {}) {
        self.database = database
        self.clock = clock
        self.changed = changed
    }

    /// Keeps Apple Maps' answer to a search under `key` (an empty answer too, so the same search isn't asked again
    /// for a while) and stores each place as a search result (kind 8), refreshing earlier search results. Answers
    /// older than ``mapSearchMaxAge`` are dropped, so the typed words don't stay on the iPhone. A place that place
    /// naming already holds as a point of interest is left to it. Place counts read place rows, so a written place
    /// marks the library-wide structure steps due.
    public func rememberMapResults(key: String, results: [MapPlace]) async throws {
        let now = Int64(clock.now.timeIntervalSince1970)
        let expired = now - Self.mapSearchMaxAge.components.seconds
        let payload = try JSONEncoder().encode(results)
        try await database.write { db in
            try db.execute(sql: "DELETE FROM map_search_cache WHERE fetched_at < ?", arguments: [expired])
            try db.execute(sql: "INSERT OR REPLACE INTO map_search_cache (key, fetched_at, payload) VALUES (?, ?, ?)", arguments: [key, now, payload])
            var places = PlaceRows(db)
            var wrote = false
            for place in results {
                let spec = PlaceSpec(mapResult: place)
                let kind = try Int.fetchOne(db, sql: "SELECT kind FROM place WHERE key = ?", arguments: [spec.key])
                guard kind == nil || kind == PlaceKind.mapResult.rawValue else { continue }
                _ = try places.id(spec, refresh: true)
                wrote = true
            }
            if wrote { try Meta.markStructureDue(db) }
        }
    }

    /// Remembers that the person picked `placeKey` (and optionally a radius in metres) for `phrase`, so the next
    /// search of the same words uses it.
    public func rememberChoice(phrase: String, placeKey: String, radius: Double?) async throws {
        let now = Int64(clock.now.timeIntervalSince1970)
        let folded = PlaceNames.fold(phrase)
        guard !folded.isEmpty else { return }
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO place_choice (phrase, place_key, radius_m, updated_utc) VALUES (?, ?, ?, ?)
                ON CONFLICT(phrase) DO UPDATE SET place_key = excluded.place_key, radius_m = excluded.radius_m, updated_utc = excluded.updated_utc
                """, arguments: [folded, placeKey, radius, now])
        }
    }

    // MARK: Saved places

    /// Saves a place and returns its id. A place set as home (or named "Home") becomes the only home.
    @discardableResult
    public func savePlace(name: String, center: Coordinate, radius: Double, isHome: Bool) async throws -> Int64 {
        let name = SavedPlaceRules.cleaned(name)
        let now = Int64(clock.now.timeIntervalSince1970)
        let id = try await database.write { db in
            let folded = try SavedPlaceRows.checkName(db, name, excluding: nil)
            try db.execute(sql: """
                INSERT INTO saved_place (name, name_folded, lat, lon, radius_m, is_home, created_utc, updated_utc) VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                """, arguments: [name, folded, center.latitude, center.longitude, radius, now, now])
            let id = db.lastInsertedRowID
            try SavedPlaceRows.mirror(db, SavedPlaceRows.Stored(id: id, name: name, center: center, radius: radius, isHome: false))
            if isHome || SavedPlaceRules.isHomeName(name) {
                try SavedPlaceRows.setHome(db, id: id)
                try Meta.set(db, .homeOverride, nil)
            }
            try SavedPlaceRows.markDirty(db, around: center, radius: radius)
            try Self.finish(db)
            return id
        }
        await changed()
        return id
    }

    /// Renames a saved place (its moments' labels follow at once: they read the place row's name). Named "Home", it
    /// becomes the home.
    public func renamePlace(_ id: Int64, to name: String) async throws {
        let name = SavedPlaceRules.cleaned(name)
        let now = Int64(clock.now.timeIntervalSince1970)
        try await database.write { db in
            guard var place = try SavedPlaceRows.fetch(db, id: id) else { throw SavedPlaceError.notFound }
            let folded = try SavedPlaceRows.checkName(db, name, excluding: id)
            try db.execute(sql: "UPDATE saved_place SET name = ?, name_folded = ?, updated_utc = ? WHERE id = ?", arguments: [name, folded, now, id])
            place.name = name
            try SavedPlaceRows.mirror(db, place)
            if SavedPlaceRules.isHomeName(name), !place.isHome {
                try SavedPlaceRows.setHome(db, id: id)
                try Meta.set(db, .homeOverride, nil)
            }
            try Self.finish(db)
        }
        await changed()
    }

    /// Changes a saved place's radius (metres): the days around its old and new area are labelled again.
    public func setRadius(_ id: Int64, _ radius: Double) async throws {
        let now = Int64(clock.now.timeIntervalSince1970)
        try await database.write { db in
            guard var place = try SavedPlaceRows.fetch(db, id: id) else { throw SavedPlaceError.notFound }
            try SavedPlaceRows.markDirty(db, around: place.center, radius: max(place.radius, radius))
            try db.execute(sql: "UPDATE saved_place SET radius_m = ?, updated_utc = ? WHERE id = ?", arguments: [radius, now, id])
            place.radius = radius
            try SavedPlaceRows.mirror(db, place)
            try Self.finish(db)
        }
        await changed()
    }

    /// Deletes a saved place; the home it was goes back to the estimate.
    public func deletePlace(_ id: Int64) async throws {
        try await database.write { db in
            guard let place = try SavedPlaceRows.fetch(db, id: id) else { return }
            try SavedPlaceRows.delete(db, place)
            try Self.finish(db)
        }
        await changed()
    }

    /// Sets what Lahza uses as home: the estimate, a saved place, a night place (saved as "Home") or none. Home bases,
    /// trips and the moments near the old and new home follow at the restructure.
    public func setHome(_ choice: HomeChoice) async throws {
        let now = Int64(clock.now.timeIntervalSince1970)
        try await database.write { db in
            switch choice {
            case .estimated, .noHome:
                try SavedPlaceRows.setHome(db, id: nil)
                try Meta.set(db, .homeOverride, choice == .noHome ? HomeOverride.none.rawValue : nil)
            case .place(let id):
                guard try SavedPlaceRows.fetch(db, id: id) != nil else { throw SavedPlaceError.notFound }
                try SavedPlaceRows.setHome(db, id: id)
                try Meta.set(db, .homeOverride, nil)
            case .point(let center):
                let radius = SavedPlaceRules.homeRadius
                let existing = try Int64.fetchOne(db, sql: "SELECT id FROM saved_place WHERE name_folded = 'home'")
                let id: Int64
                if let existing, let old = try SavedPlaceRows.fetch(db, id: existing) {
                    try SavedPlaceRows.markDirty(db, around: old.center, radius: old.radius)
                    try db.execute(sql: "UPDATE saved_place SET lat = ?, lon = ?, radius_m = ?, updated_utc = ? WHERE id = ?",
                                   arguments: [center.latitude, center.longitude, radius, now, existing])
                    id = existing
                } else {
                    try db.execute(sql: """
                        INSERT INTO saved_place (name, name_folded, lat, lon, radius_m, is_home, created_utc, updated_utc) VALUES ('Home', 'home', ?, ?, ?, 0, ?, ?)
                        """, arguments: [center.latitude, center.longitude, radius, now, now])
                    id = db.lastInsertedRowID
                }
                try SavedPlaceRows.mirror(db, SavedPlaceRows.Stored(id: id, name: "Home", center: center, radius: radius, isHome: false))
                try SavedPlaceRows.markDirty(db, around: center, radius: radius)
                try SavedPlaceRows.setHome(db, id: id)
                try Meta.set(db, .homeOverride, nil)
            }
            try Self.finish(db)
        }
        await changed()
    }

    /// The end of every saved-place transaction: place counts, the home and trips are due, and readers see a new
    /// version.
    private static func finish(_ db: Database) throws {
        try Meta.markStructureDue(db)
        try Meta.bumpVersion(db)
    }
}
