import Foundation
import LZGeo
import LZLibrary
internal import GRDB

/// The index's assets as in-memory columns, newest first, for search to score in one pass (search spec §6.6): about
/// 8 MB per 100,000 assets, built off the main actor in one read (one consistent snapshot of the database) and kept
/// per index version by the session. Missing values are NaN (positions), `Int64.min` (times) or −1 (days, places,
/// moments, trips). Row ids are `Int32`-sized in practice; ids that don't fit are left out of the place columns.
public struct SearchSnapshot: Sendable {
    /// The `asset.flags` bits search reads.
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let favorite = Flags(rawValue: UInt16(AssetFlags.favorite.rawValue))
        public static let selfie = Flags(rawValue: UInt16(AssetFlags.selfie.rawValue))
        public static let likelyReceived = Flags(rawValue: UInt16(AssetFlags.likelyReceived.rawValue))
        public static let burstMember = Flags(rawValue: UInt16(AssetFlags.burstMember.rawValue))
        /// No creation date, before 2000, or more than a day in the future.
        public static let dateUnreliable = Flags(rawValue: UInt16(AssetFlags.dateUnreliable.rawValue))
    }

    /// Where an asset's effective position comes from (`asset.place_src`).
    public enum PositionSource: UInt8, Sendable {
        case none = 0
        /// Its own GPS.
        case gps = 1
        /// A located item of its moment within 10 minutes.
        case momentNear = 2
        /// A located item of its moment within 2 hours.
        case momentFar = 3
    }

    /// One moment, as scoring needs it.
    public struct Moment: Sendable, Hashable {
        public var day: Int32
        public var startUTC: Int64
        /// The median position of its located items.
        public var centroid: Coordinate?
        public var trip: Int32
        /// The index of its located item nearest the centroid (its places stand for the moment's), −1 without one.
        public var representative: Int32

        public var key: MomentKey { MomentKey(day: day, startUTC: startUTC) }
    }

    /// One trip, as scoring needs it.
    public struct Trip: Sendable, Hashable {
        /// The dominant city (or the country when no city dominates).
        public var labelPlace: Int32
        public var countryPlace: Int32
        public var abroad: Bool
    }

    public let generation: Int
    public let version: Int64
    public let count: Int
    public let id: [Int64]
    public let utc: [Int64]
    public let wall: [Int64]
    /// The 04:00-to-04:00 local day.
    public let day: [Int32]
    /// The effective position (own GPS or borrowed from the moment).
    public let lat: [Float]
    public let lon: [Float]
    /// Metres; −1 when unknown.
    public let hAcc: [Float]
    public let placeSource: [UInt8]
    /// 0 photo, 1 video.
    public let kind: [UInt8]
    /// ``AssetFacts/Subtypes`` raw values.
    public let subtypes: [UInt32]
    public let flags: [UInt16]
    /// Seconds (videos).
    public let duration: [Float]
    public let city: [Int32]
    public let metro: [Int32]
    public let locality: [Int32]
    public let region: [Int32]
    public let country: [Int32]
    public let moment: [Int32]
    public let trip: [Int32]
    public let moments: [Int32: Moment]
    public let trips: [Int32: Trip]
    /// Moment day → the moments of that day with a located item (the same-day rule for received photos).
    public let dayLocatedMoments: [Int32: [Int32]]
    /// Indices of the assets without an effective position.
    public let unlocated: [Int32]
    public let grid: LocatedGrid
    /// The index has a Vision pass (content search is on); the columns below are empty without one.
    public let hasVisualPass: Bool
    /// ``VisualStatus`` raw values; 0 (pending) for photos not reached yet.
    public let visualStatus: [UInt8]
    public let faces: [UInt8]
    public let humans: [UInt8]
    /// Vision's utility verdict (receipts, documents, screenshots).
    public let utility: [Bool]
    /// Asset row id → index, for reading tags.
    public let indexByID: [Int64: Int32]

    // MARK: Per asset

    public func has(_ flag: Flags, _ index: Int) -> Bool { Flags(rawValue: flags[index]).contains(flag) }

    public func has(_ subtype: AssetFacts.Subtypes, _ index: Int) -> Bool { Int(subtypes[index]) & subtype.rawValue != 0 }

    public func isVideo(_ index: Int) -> Bool { kind[index] == 1 }

    public func isDated(_ index: Int) -> Bool { utc[index] != Int64.min && wall[index] != Int64.min }

    public func isLocated(_ index: Int) -> Bool { !lat[index].isNaN }

    public func position(_ index: Int) -> Coordinate? {
        guard !lat[index].isNaN else { return nil }
        return Coordinate(latitude: Double(lat[index]), longitude: Double(lon[index]))
    }

    public func source(_ index: Int) -> PositionSource { PositionSource(rawValue: placeSource[index]) ?? .none }

    /// Tagged by the Vision pass.
    public func isChecked(_ index: Int) -> Bool { hasVisualPass && visualStatus[index] == UInt8(VisualStatus.done.rawValue) }

    public func isUtility(_ index: Int) -> Bool { hasVisualPass && utility[index] }

    /// Photos tagged, photos waiting for an image only in iCloud, and photos the pass hasn't reached yet.
    public var visualCounts: (checked: Int, pendingCloud: Int, unchecked: Int) {
        guard hasVisualPass else { return (0, 0, 0) }
        var checked = 0, cloud = 0, unchecked = 0
        for status in visualStatus {
            switch status {
            case UInt8(VisualStatus.done.rawValue): checked += 1
            case UInt8(VisualStatus.pendingCloud.rawValue): cloud += 1
            case UInt8(VisualStatus.pending.rawValue): unchecked += 1
            default: break
            }
        }
        return (checked, cloud, unchecked)
    }

    /// A screenshot or screen recording.
    public func isScreenCapture(_ index: Int) -> Bool {
        Int(subtypes[index]) & (AssetFacts.Subtypes.screenshot.rawValue | AssetFacts.Subtypes.screenRecording.rawValue) != 0
    }

    // MARK: Counts around a point

    /// Assets whose effective position is within `radius` metres of `center` (`ownGPSOnly`: their own GPS only).
    public func indices(near center: Coordinate, within radius: Double, ownGPSOnly: Bool = false) -> [Int32] {
        grid.candidates(near: center, within: radius, in: self).filter { index in
            let i = Int(index)
            guard !ownGPSOnly || placeSource[i] == PositionSource.gps.rawValue, let position = position(i) else { return false }
            return position.distance(to: center) <= radius
        }
    }
}

/// Located assets bucketed by 0.01° of latitude and longitude (about 1.1 km), for counts around a point and for
/// pruning area searches.
public struct LocatedGrid: Sendable {
    static let cell: Double = 0.01
    /// A search wider than this many buckets per side scans every located asset instead.
    static let maxSpan = 400

    private let buckets: [Int64: [Int32]]
    private let located: [Int32]

    init(lat: [Float], lon: [Float]) {
        var buckets: [Int64: [Int32]] = [:]
        var located: [Int32] = []
        for index in lat.indices where !lat[index].isNaN {
            buckets[Self.key(Self.bucket(Double(lat[index])), Self.bucket(Double(lon[index]))), default: []].append(Int32(index))
            located.append(Int32(index))
        }
        self.buckets = buckets
        self.located = located
    }

    static func bucket(_ degrees: Double) -> Int { Int((degrees / cell).rounded(.down)) }

    static func key(_ latitude: Int, _ longitude: Int) -> Int64 { Int64(latitude) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: longitude))) }

    /// Every located asset whose bucket may hold a point within `radius` metres of `center` (a superset).
    public func candidates(near center: Coordinate, within radius: Double, in snapshot: SearchSnapshot) -> [Int32] {
        let latitudeSpan = radius / 111_320
        let longitudeSpan = radius / (111_320 * max(0.01, cos(center.latitude * .pi / 180)))
        let latitudes = Self.bucket(center.latitude - latitudeSpan)...Self.bucket(center.latitude + latitudeSpan)
        let longitudes = Self.bucket(center.longitude - longitudeSpan)...Self.bucket(center.longitude + longitudeSpan)
        guard latitudes.count <= Self.maxSpan, longitudes.count <= Self.maxSpan, latitudes.count * longitudes.count <= buckets.count * 4 else {
            return located
        }
        var found: [Int32] = []
        for latitude in latitudes {
            for longitude in longitudes {
                if let bucket = buckets[Self.key(latitude, longitude)] { found += bucket }
            }
        }
        return found
    }
}

extension IndexQueries {
    /// Builds the snapshot in one read; `version` is read in the same transaction, so it names exactly these rows.
    static func snapshot(_ db: Database, generation: Int) throws -> SearchSnapshot {
        let version = try Meta.int(db, .indexVersion) ?? 0
        let hasVisualPass = try Meta.int(db, .visualVersion) != nil
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
        var id: [Int64] = [], utc: [Int64] = [], wall: [Int64] = [], day: [Int32] = []
        var lat: [Float] = [], lon: [Float] = [], hAcc: [Float] = []
        var placeSource: [UInt8] = [], kind: [UInt8] = [], subtypes: [UInt32] = [], flags: [UInt16] = [], duration: [Float] = []
        var city: [Int32] = [], metro: [Int32] = [], locality: [Int32] = [], region: [Int32] = [], country: [Int32] = []
        var moment: [Int32] = [], trip: [Int32] = []
        var visualStatus: [UInt8] = [], faces: [UInt8] = [], humans: [UInt8] = [], utility: [Bool] = []
        id.reserveCapacity(total); utc.reserveCapacity(total); wall.reserveCapacity(total); day.reserveCapacity(total)
        lat.reserveCapacity(total); lon.reserveCapacity(total); hAcc.reserveCapacity(total); placeSource.reserveCapacity(total)
        kind.reserveCapacity(total); subtypes.reserveCapacity(total); flags.reserveCapacity(total); duration.reserveCapacity(total)
        city.reserveCapacity(total); metro.reserveCapacity(total); locality.reserveCapacity(total); region.reserveCapacity(total)
        country.reserveCapacity(total); moment.reserveCapacity(total); trip.reserveCapacity(total)
        if hasVisualPass {
            visualStatus.reserveCapacity(total); faces.reserveCapacity(total); humans.reserveCapacity(total); utility.reserveCapacity(total)
        }

        func small(_ value: Int64?) -> Int32 {
            guard let value, value >= 0, value <= Int64(Int32.max) else { return -1 }
            return Int32(value)
        }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT id, created_utc, wall_s, day, eff_lat, eff_lon, h_acc, place_src, kind, subtypes, flags, duration,
                   city_place, metro_place, locality_place, region_place, country_place, moment_id, trip_id,
                   v.status, v.faces, v.humans, v.is_utility
            FROM asset LEFT JOIN asset_visual v ON v.asset_id = asset.id ORDER BY created_utc DESC, id DESC
            """)
        while let row = try rows.next() {
            id.append(row[0])
            utc.append(row[1] ?? Int64.min)
            wall.append(row[2] ?? Int64.min)
            day.append(row[3] ?? -1)
            let latitude: Double? = row[4], longitude: Double? = row[5]
            if let latitude, let longitude {
                lat.append(Float(latitude))
                lon.append(Float(longitude))
            } else {
                lat.append(.nan)
                lon.append(.nan)
            }
            hAcc.append((row[6] as Double?).map(Float.init) ?? -1)
            placeSource.append(UInt8(clamping: row[7] as Int))
            kind.append(UInt8(clamping: row[8] as Int))
            subtypes.append(UInt32(truncatingIfNeeded: row[9] as Int))
            flags.append(UInt16(truncatingIfNeeded: row[10] as Int))
            duration.append(Float(row[11] as Double))
            city.append(small(row[12]))
            metro.append(small(row[13]))
            locality.append(small(row[14]))
            region.append(small(row[15]))
            country.append(small(row[16]))
            moment.append(small(row[17]))
            trip.append(small(row[18]))
            if hasVisualPass {
                visualStatus.append(UInt8(clamping: (row[19] as Int?) ?? 0))
                faces.append(UInt8(clamping: (row[20] as Int?) ?? 0))
                humans.append(UInt8(clamping: (row[21] as Int?) ?? 0))
                utility.append((row[22] as Bool?) ?? false)
            }
        }
        var indexByID: [Int64: Int32] = [:]
        if hasVisualPass {
            indexByID.reserveCapacity(id.count)
            for (index, value) in id.enumerated() { indexByID[value] = Int32(index) }
        }

        var moments: [Int32: SearchSnapshot.Moment] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, day, start_utc, lat, lon, trip_id FROM moment") {
            let latitude: Double? = row[3], longitude: Double? = row[4]
            moments[small(row[0])] = SearchSnapshot.Moment(day: row[1], startUTC: row[2],
                                                          centroid: latitude.flatMap { lat in longitude.map { Coordinate(latitude: lat, longitude: $0) } },
                                                          trip: small(row[5]), representative: -1)
        }
        var trips: [Int32: SearchSnapshot.Trip] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, label_place, country_place, abroad FROM trip") {
            trips[small(row[0])] = SearchSnapshot.Trip(labelPlace: small(row[1]), countryPlace: small(row[2]), abroad: row[3])
        }

        // Each moment's located item nearest its centroid, and the days' located moments.
        var nearest: [Int32: (index: Int32, distance: Double)] = [:]
        var unlocated: [Int32] = []
        for index in id.indices {
            guard !lat[index].isNaN else {
                unlocated.append(Int32(index))
                continue
            }
            let owner = moment[index]
            guard owner >= 0, placeSource[index] == SearchSnapshot.PositionSource.gps.rawValue, let centroid = moments[owner]?.centroid else { continue }
            let distance = Coordinate(latitude: Double(lat[index]), longitude: Double(lon[index])).distance(to: centroid)
            if nearest[owner].map({ distance < $0.distance }) ?? true { nearest[owner] = (Int32(index), distance) }
        }
        var dayLocatedMoments: [Int32: [Int32]] = [:]
        for (key, value) in nearest {
            moments[key]?.representative = value.index
            if let day = moments[key]?.day { dayLocatedMoments[day, default: []].append(key) }
        }

        return SearchSnapshot(generation: generation, version: version, count: id.count, id: id, utc: utc, wall: wall, day: day, lat: lat, lon: lon,
                              hAcc: hAcc, placeSource: placeSource, kind: kind, subtypes: subtypes, flags: flags, duration: duration, city: city,
                              metro: metro, locality: locality, region: region, country: country, moment: moment, trip: trip, moments: moments,
                              trips: trips, dayLocatedMoments: dayLocatedMoments, unlocated: unlocated, grid: LocatedGrid(lat: lat, lon: lon),
                              hasVisualPass: hasVisualPass, visualStatus: visualStatus, faces: faces, humans: humans, utility: utility,
                              indexByID: indexByID)
    }
}

/// The session's snapshot: rebuilt when the index version changes, at most once a second while versions churn (the
/// first build bumps them every few hundred milliseconds), shared by concurrent callers and dropped on a memory
/// warning.
actor SnapshotStore {
    static let minimumAge: Duration = .seconds(1)

    private var cached: (snapshot: SearchSnapshot, built: ContinuousClock.Instant)?
    private var building: Task<SearchSnapshot, any Error>?

    func snapshot(version: Int64, build: @escaping @Sendable () async throws -> SearchSnapshot) async throws -> SearchSnapshot {
        if let cached, cached.snapshot.version == version || ContinuousClock.now - cached.built < Self.minimumAge { return cached.snapshot }
        if let building { return try await building.value }
        let task = Task { try await build() }
        building = task
        defer { building = nil }
        let snapshot = try await task.value
        cached = (snapshot, ContinuousClock.now)
        return snapshot
    }

    func release() {
        cached = nil
    }
}
