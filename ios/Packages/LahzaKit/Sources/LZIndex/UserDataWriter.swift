import Foundation
import LZCore
import LZGeo
internal import GRDB

/// Search's targeted writes (search spec §2.4): Apple Maps search answers (the cache and their places, which join
/// the own index) and the places the person picked for a phrase. Saved-place writes come with PR 4. Each call is one
/// transaction that touches only these tables, so it never clobbers the indexer's or place naming's rows.
public struct UserDataWriter: Sendable {
    let database: IndexDatabase
    let clock: any AppClock

    init(database: IndexDatabase, clock: any AppClock) {
        self.database = database
        self.clock = clock
    }

    /// Keeps Apple Maps' answer to a search under `key` (an empty answer too, so the same search isn't asked again
    /// for a while) and stores each place as a search result (kind 8), refreshing earlier search results. A place
    /// that place naming already holds as a point of interest is left to it. Place counts read place rows, so a
    /// written place marks the library-wide structure steps due.
    public func rememberMapResults(key: String, results: [MapPlace]) async throws {
        let now = Int64(clock.now.timeIntervalSince1970)
        let payload = try JSONEncoder().encode(results)
        try await database.write { db in
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
}
