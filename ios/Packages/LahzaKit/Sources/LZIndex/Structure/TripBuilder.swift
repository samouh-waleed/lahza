import Foundation
import LZGeo
import LZLibrary
internal import GRDB

/// Trips, recomputed for every year at the end of each job (search spec §4.4; milliseconds over day summaries):
/// 1. A day with located photos is **home** if one of them is within 25 km of that year's home, otherwise
///    **away**. Days without located photos are neutral.
/// 2. A trip is a run of away days at most 3 days apart (up to 2 neutral days between) with no home day inside.
/// 3. It spans 2 to 30 days: one day is a day trip, more than 30 is living away.
/// 4. Its members are every asset of its days.
/// 5. Label: the dominant city if it holds at least 70% of the located members, else the dominant country.
///
/// Trips are kept by their first day, so their ids stay stable while they don't change.
enum TripBuilder {
    static let homeMetres: Double = 25_000
    static let maxGap: Int32 = 3
    static let spans: ClosedRange<Int32> = 2...30
    static let cityShare = 0.7

    struct Trip: Hashable {
        var startDay: Int32
        var endDay: Int32
        var label: String
        var labelPlace: Int64?
        var countryPlace: Int64?
        var abroad: Bool
        var moments: Int
        var items: Int
        var videos: Int
        var maxKm: Double
        var cover: Int64?
    }

    /// Recomputes the trips and their members' `trip_id`. Returns whether anything changed.
    static func update(_ db: Database) throws -> Bool {
        var homes: [Int: (center: Coordinate, country: String?)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT year, lat, lon, country_code FROM home_base") {
            homes[row["year"]] = (Coordinate(latitude: row["lat"], longitude: row["lon"]), row["country_code"])
        }

        // Each located day: home or away.
        var away: [Int32: Bool] = [:]
        let located = try Row.fetchCursor(db, sql: "SELECT day, lat, lon FROM asset WHERE lat IS NOT NULL AND day IS NOT NULL")
        while let row = try located.next() {
            let day: Int32 = row["day"]
            guard let home = homes[day.civilYear], away[day] != false else { continue }
            away[day] = Coordinate(latitude: row["lat"], longitude: row["lon"]).distance(to: home.center) > homeMetres
        }

        var runs: [ClosedRange<Int32>] = []
        var run: ClosedRange<Int32>?
        for day in away.keys.sorted() {
            if away[day] == true {
                if let current = run, day - current.upperBound <= maxGap {
                    run = current.lowerBound...day
                } else {
                    if let current = run { runs.append(current) }
                    run = day...day
                }
            } else if let current = run {
                runs.append(current)
                run = nil
            }
        }
        if let run { runs.append(run) }

        var trips: [Trip] = []
        for days in runs where spans.contains(days.upperBound - days.lowerBound + 1) {
            if let trip = try trip(db, days: days, homes: homes) { trips.append(trip) }
        }
        return try write(db, trips)
    }

    private static func trip(_ db: Database, days: ClosedRange<Int32>, homes: [Int: (center: Coordinate, country: String?)]) throws -> Trip? {
        let members = try Row.fetchAll(db, sql: """
            SELECT id, kind, flags, subtypes, day, lat, lon, city_place, country_place, moment_id FROM asset
            WHERE day BETWEEN ? AND ? ORDER BY created_utc, id
            """, arguments: [days.lowerBound, days.upperBound])
        guard !members.isEmpty else { return nil }
        let located = members.filter { $0["lat"] as Double? != nil }
        let cities = located.compactMap { $0["city_place"] as Int64? }
        let countries = located.compactMap { $0["country_place"] as Int64? }
        let city = DayBuilder.dominant(cities)
        let country = DayBuilder.dominant(countries)
        let labelPlace: Int64?
        if let city, Double(cities.filter { $0 == city }.count) >= cityShare * Double(located.count) {
            labelPlace = city
        } else {
            labelPlace = country
        }
        let label = try labelPlace.flatMap { try String.fetchOne(db, sql: "SELECT name FROM place WHERE id = ?", arguments: [$0]) } ?? "Trip"
        let countryCode = try country.flatMap { try String.fetchOne(db, sql: "SELECT country_code FROM place WHERE id = ?", arguments: [$0]) }
        let homeCountry = homes[days.lowerBound.civilYear]?.country
        let maxKm = located.compactMap { row -> Double? in
            let day: Int32 = row["day"]
            guard let home = homes[day.civilYear] else { return nil }
            return Coordinate(latitude: row["lat"], longitude: row["lon"]).distance(to: home.center) / 1_000
        }.max() ?? 0
        let isVideo = { (row: Row) in (row["kind"] as Int) == 1 }
        let photos = members.filter { !isVideo($0) && (($0["subtypes"] as Int) & AssetFacts.Subtypes.screenshot.rawValue) == 0 }
        let cover = members.first { (($0["flags"] as Int) & AssetFlags.favorite.rawValue) != 0 }
            ?? (photos.isEmpty ? members[members.count / 2] : photos[photos.count / 2])
        return Trip(startDay: days.lowerBound, endDay: days.upperBound, label: label, labelPlace: labelPlace, countryPlace: country,
                    abroad: countryCode != nil && homeCountry != nil && countryCode != homeCountry,
                    moments: Set(members.compactMap { $0["moment_id"] as Int64? }).count, items: members.count,
                    videos: members.filter(isVideo).count, maxKm: (maxKm * 10).rounded() / 10, cover: cover["id"])
    }

    /// Upserts by first day, deletes the rest and points members and moments at their trip.
    private static func write(_ db: Database, _ trips: [Trip]) throws -> Bool {
        var changed = false
        var existing: [Int32: (id: Int64, trip: Trip)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM trip") {
            existing[row["start_day"]] = (row["id"], Trip(startDay: row["start_day"], endDay: row["end_day"], label: row["label"],
                                                          labelPlace: row["label_place"], countryPlace: row["country_place"], abroad: row["abroad"],
                                                          moments: row["moment_count"], items: row["item_count"], videos: row["video_count"],
                                                          maxKm: row["max_km"], cover: row["cover_asset"]))
        }
        var kept: [(id: Int64, days: ClosedRange<Int32>)] = []
        for trip in trips {
            let values: [(any DatabaseValueConvertible)?] = [trip.endDay, trip.label, trip.labelPlace, trip.countryPlace, trip.abroad, trip.moments,
                                                             trip.items, trip.videos, trip.maxKm, trip.cover]
            if let old = existing.removeValue(forKey: trip.startDay) {
                if old.trip != trip {
                    try db.execute(sql: """
                        UPDATE trip SET end_day = ?, label = ?, label_place = ?, country_place = ?, abroad = ?, moment_count = ?, item_count = ?,
                                        video_count = ?, max_km = ?, cover_asset = ? WHERE id = ?
                        """, arguments: StatementArguments(values + [old.id]))
                    changed = true
                }
                kept.append((old.id, trip.startDay...trip.endDay))
            } else {
                try db.execute(sql: """
                    INSERT INTO trip (start_day, end_day, label, label_place, country_place, abroad, moment_count, item_count, video_count, max_km, cover_asset)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: StatementArguments([trip.startDay] + values))
                kept.append((db.lastInsertedRowID, trip.startDay...trip.endDay))
                changed = true
            }
        }
        for gone in existing.values {
            try db.execute(sql: "DELETE FROM trip WHERE id = ?", arguments: [gone.id])
            changed = true
        }

        // Members: every asset and moment of a trip's days points at it; nothing else points anywhere. One pass clears
        // what no longer lies in its trip's days (or whose trip is gone), then each trip's days are set by the day index.
        for table in ["asset", "moment"] {
            try db.execute(sql: """
                UPDATE \(table) SET trip_id = NULL WHERE trip_id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM trip WHERE trip.id = \(table).trip_id AND \(table).day BETWEEN trip.start_day AND trip.end_day)
                """)
            changed = changed || db.changesCount > 0
            let assign = try db.cachedStatement(sql: "UPDATE \(table) SET trip_id = ? WHERE day BETWEEN ? AND ? AND trip_id IS NOT ?")
            for trip in kept {
                try assign.execute(arguments: [trip.id, trip.days.lowerBound, trip.days.upperBound, trip.id])
                changed = changed || db.changesCount > 0
            }
        }
        return changed
    }
}
