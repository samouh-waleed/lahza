import Foundation
import LZCore
import LZGeo
internal import GRDB

/// P2's tunables (search spec §4.6; placeholders to tune on a device).
public struct PlaceNamePolicy: Sendable {
    /// Metres around a cell's centroid Apple Maps is asked about.
    public var searchRadius: Double
    /// A cell within this many metres of a named cell takes its answer without a request.
    public var reuseDistance: Double
    /// The indexer recomputes labels after this many cells (and when the queue goes idle).
    public var notifyEvery: Int
    /// Offline: wait this long for the network before trying again.
    public var offlineWait: Duration
    /// Other errors: retry after base × 2^attempts, and give up after `maxAttempts`.
    public var retryBase: TimeInterval
    public var maxAttempts: Int
    /// Nothing found: ask again after this long.
    public var noneRetry: TimeInterval
    /// A request that takes longer counts as failed (MapKit ignores cancellation, so the queue never waits on it).
    public var requestTimeout: Duration

    public init(searchRadius: Double = 500, reuseDistance: Double = 150, notifyEvery: Int = 20, offlineWait: Duration = .seconds(300),
                retryBase: TimeInterval = 600, maxAttempts: Int = 5, noneRetry: TimeInterval = 30 * 86_400, requestTimeout: Duration = .seconds(20)) {
        self.searchRadius = searchRadius
        self.reuseDistance = reuseDistance
        self.notifyEvery = notifyEvery
        self.offlineWait = offlineWait
        self.retryBase = retryBase
        self.maxAttempts = maxAttempts
        self.noneRetry = noneRetry
        self.requestTimeout = requestTimeout
    }

    public static let `default` = PlaceNamePolicy()
}

/// P2: names photo cells with Apple Maps (search spec §4.5–4.6). One points-of-interest request per eligible
/// ~150 m cell, asking only for **area** categories (parks, beaches, stadiums, landmarks…), plus a reverse
/// geocode where the gazetteer has no city. Only the cell's centroid is sent, never a photo's position.
///
/// The best area for a cell is the one whose radius covers its centroid most tightly (distance ÷ radius; a tie
/// goes to the larger radius). Answers are cached per cell and reused by cells within 150 m, so a rebuild never
/// asks Apple again. The queue writes only its own columns (`cell`'s naming columns, Apple Maps places, the
/// cache) and the days to restructure, then asks the indexer to recompute labels (`notify`), so it never races
/// the indexer's rows.
///
/// It waits for the network and for the budget, backs off when Apple Maps throttles, and retries other errors
/// later. ``run()`` returns when nothing is left to name now, or when its task is cancelled; a cancelled
/// request never holds it up.
public actor PlaceNameQueue {
    private let database: IndexDatabase
    private let maps: any MapsClient
    private let budget: MapsBudget
    private let clock: any AppClock
    private let network: any NetworkStatus
    private let notify: @Sendable () async -> Void
    private let policy: PlaceNamePolicy
    private let broadcaster: Broadcaster<PlaceNameProgress>
    private let log = Log("places")

    /// Cells to name first (on screen), most recently asked first.
    private var boosted: [String] = []
    private var queue: [Candidate] = []
    /// Cells this run has handled (so a write that didn't apply can't loop).
    private var handled = Set<String>()
    private var restoredBackoff = false
    private var savedBackoff = false
    private var counts = (named: 0, eligible: 0)

    static let maxBoosted = 200

    public init(database: IndexDatabase, maps: any MapsClient, budget: MapsBudget, clock: any AppClock, network: any NetworkStatus,
                notify: @escaping @Sendable () async -> Void, policy: PlaceNamePolicy = .default) {
        self.database = database
        self.maps = maps
        self.budget = budget
        self.clock = clock
        self.network = network
        self.notify = notify
        self.policy = policy
        broadcaster = Broadcaster(PlaceNameProgress())
    }

    /// Named and eligible cells and what the queue is doing: a fresh stream per subscriber, newest only.
    public nonisolated var progress: AsyncStream<PlaceNameProgress> { broadcaster.stream() }

    /// Names these cells next (the moment cards on screen).
    public func prioritize(cells: [String]) {
        let fresh = cells.filter { !$0.isEmpty }
        boosted = Array((fresh + boosted.filter { !fresh.contains($0) }).prefix(Self.maxBoosted))
    }

    // MARK: Run

    private enum Outcome {
        case written
        case skipped
        case throttled
        case offline
        case cancelled
    }

    /// Names cells until none is due or the task is cancelled. The caller owns the task.
    public func run() async {
        handled = []
        queue = []
        if !restoredBackoff {
            restoredBackoff = true
            let saved = try? await database.read { db in try Meta.date(db, .mapsBackoffUntil) }
            if let saved = saved ?? nil {
                await budget.restoreBackoff(until: saved)
                savedBackoff = true
            }
        }
        await refreshCounts()
        var written = 0, sinceNotify = 0
        loop: while !Task.isCancelled {
            if !network.isReachable {
                publish(.waitingForNetwork)
                await waitForNetwork()
                continue
            }
            if let until = await budget.backoffUntil, until > clock.now {
                publish(.throttled(until: until))
                do { try await clock.sleep(for: .seconds(until.timeIntervalSince(clock.now))) } catch { break }
                continue
            }
            guard let candidate = await next() else { break }
            publish(.running)
            switch await name(candidate) {
            case .written:
                written += 1
                sinceNotify += 1
                await refreshCounts()
                publish(.running)
            case .skipped:
                break
            case .throttled:
                handled.remove(candidate.cell)
            case .offline:
                handled.remove(candidate.cell)
                publish(.waitingForNetwork)
                await waitForNetwork(afterFailure: true)
            case .cancelled:
                break loop
            }
            if sinceNotify >= policy.notifyEvery {
                sinceNotify = 0
                await notify()
            }
        }
        if sinceNotify > 0 { await notify() }
        if written > 0 { log.info("Place names: \(written) cells written, \(counts.named) of \(counts.eligible) named", privacy: .public) }
        if !Task.isCancelled { publish(.done) }
    }

    /// Until the network is reachable (after an offline error, until it comes back), or ``PlaceNamePolicy/offlineWait``.
    private func waitForNetwork(afterFailure: Bool = false) async {
        let changes = network.changes()
        let wasOffline = afterFailure ? false : !network.isReachable
        let clock = clock, wait = policy.offlineWait
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var sawOffline = wasOffline
                for await reachable in changes {
                    if !reachable { sawOffline = true } else if sawOffline { return }
                }
            }
            group.addTask { try? await clock.sleep(for: wait) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Picking

    private struct Candidate: Sendable {
        var cell: String
        var centroid: Coordinate
        var photos: Int
        var days: Int
        var last: Int64?
        var needsLocality: Bool
        var attempts: Int
        var status: Int

        init(_ row: Row) {
            cell = row["cell"]
            centroid = Coordinate(latitude: row["lat"], longitude: row["lon"])
            photos = row["photo_count"]
            days = row["day_count"]
            last = row["last_utc"]
            needsLocality = row["needs_locality"]
            attempts = row["attempts"]
            status = row["poi_status"]
        }
    }

    private static let candidateSQL = """
        SELECT cell, lat, lon, photo_count, day_count, last_utc, needs_locality, attempts, poi_status FROM cell
        WHERE (poi_status = 0 OR (poi_status IN (2, 3) AND retry_after <= ?))
        """

    /// The next cell to name: boosted ones first, then by ln(1 + photos) + 2·[recent] + 0.5·ln(1 + days).
    private func next() async -> Candidate? {
        let now = Int64(clock.now.timeIntervalSince1970)
        while let cell = boosted.first {
            boosted.removeFirst()
            guard !handled.contains(cell) else { continue }
            if let candidate = await candidate(cell, now: now) {
                handled.insert(cell)
                return candidate
            }
        }
        if queue.isEmpty {
            let recent = now - 90 * 86_400
            let rows = (try? await database.read { db in try Row.fetchAll(db, sql: Self.candidateSQL, arguments: [now]).map(Candidate.init) }) ?? []
            func score(_ c: Candidate) -> Double {
                log1p(Double(c.photos)) + ((c.last ?? .min) >= recent ? 2 : 0) + 0.5 * log1p(Double(c.days))
            }
            queue = rows.filter { !handled.contains($0.cell) }.sorted { (score($0), $1.cell) > (score($1), $0.cell) }
        }
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            guard handled.insert(candidate.cell).inserted else { continue }
            // Fresh values: the cell may have been named, or have left the queue, since the queue was read.
            if let fresh = await self.candidate(candidate.cell, now: now) { return fresh }
        }
        return nil
    }

    /// The cell, if it is due for naming now.
    private func candidate(_ cell: String, now: Int64) async -> Candidate? {
        let found = try? await database.read { db in
            try Row.fetchOne(db, sql: Self.candidateSQL + " AND cell = ?", arguments: [now, cell]).map(Candidate.init)
        }
        return found ?? nil
    }

    // MARK: Naming

    /// What a cell gets: Apple's areas around it, the one chosen, and its town and country.
    private struct Answer {
        var places: [MapPlace]
        var address: MapAddress?
        /// The cell whose answer this is, when not the cell's own.
        var coveredBy: String?
        /// A new answer from Apple Maps (cached for later).
        var fetched: Bool
    }

    private func name(_ candidate: Candidate) async -> Outcome {
        do {
            var answer = try await reusedAnswer(for: candidate)
            if answer == nil { answer = try await cachedAnswer(for: candidate) }
            if let answer { return try await write(candidate, answer) }
        } catch {
            return error is CancellationError ? .cancelled : .skipped
        }

        let places: [MapPlace]
        switch await request({ [maps, policy, candidate] in
            try await maps.pointsOfInterest(near: candidate.centroid, radius: policy.searchRadius, categories: PlaceCategory.areas)
        }) {
        case .success(let found): places = found
        case .failure(let failure): return await fail(candidate, failure)
        }
        var address: MapAddress?
        if candidate.needsLocality {
            switch await request({ [maps, candidate] in try await maps.reverseGeocode(candidate.centroid).map { [$0] } ?? [] }) {
            case .success(let found): address = found.first
            case .failure(let failure): return await fail(candidate, failure)
            }
        }
        await budget.reportSuccess()
        if savedBackoff {
            savedBackoff = false
            _ = try? await database.write { db in try Meta.set(db, .mapsBackoffUntil, nil) }
        }
        do {
            return try await write(candidate, Answer(places: places, address: address, fetched: true))
        } catch {
            return error is CancellationError ? .cancelled : .skipped
        }
    }

    private enum RequestFailure: Error {
        case throttled, offline, cancelled
        case other(String)
    }

    /// One Apple Maps call under the budget and a timeout. Nothing found is an empty answer.
    private func request<T: Sendable>(_ call: @escaping @Sendable () async throws -> [T]) async -> Result<[T], RequestFailure> {
        do {
            guard try await budget.acquire(.background) else { return .failure(.cancelled) }
            return .success(try await firstOf(timeout: policy.requestTimeout, orThrow: MapsError.other("timeout"), call))
        } catch let error as MapsError {
            switch error {
            case .notFound: return .success([])
            case .throttled: return .failure(.throttled)
            case .offline: return .failure(.offline)
            case .cancelled: return .failure(.cancelled)
            case .other(let code): return .failure(.other(code))
            }
        } catch {
            return .failure(Task.isCancelled || error is CancellationError ? .cancelled : .other("unknown"))
        }
    }

    private func fail(_ candidate: Candidate, _ failure: RequestFailure) async -> Outcome {
        switch failure {
        case .cancelled:
            return .cancelled
        case .offline:
            log.notice("Place names: offline", privacy: .public)
            return .offline
        case .throttled:
            await budget.reportThrottled()
            let until = await budget.backoffUntil
            savedBackoff = true
            _ = try? await database.write { db in try Meta.set(db, .mapsBackoffUntil, date: until) }
            log.notice("Place names: Apple Maps throttled", privacy: .public)
            return .throttled
        case .other(let code):
            let attempts = candidate.attempts + 1
            let gaveUp = attempts >= policy.maxAttempts
            let retry = Int64(clock.now.timeIntervalSince1970 + policy.retryBase * pow(2, Double(attempts)))
            log.notice("Place names: request failed (\(code)), attempt \(attempts)", privacy: .public)
            let written = try? await database.write { db in
                try db.execute(sql: "UPDATE cell SET poi_status = ?, attempts = ?, retry_after = ? WHERE cell = ? AND poi_status = ?",
                               arguments: [gaveUp ? PlaceNameStatus.gaveUp.rawValue : PlaceNameStatus.retry.rawValue, attempts,
                                           gaveUp ? nil : retry, candidate.cell, candidate.status])
                return db.changesCount > 0
            }
            if written == true { await refreshCounts() }
            return .skipped
        }
    }

    /// The answer of a named cell within ``PlaceNamePolicy/reuseDistance``, from its cached payload.
    private func reusedAnswer(for candidate: Candidate) async throws -> Answer? {
        let span = policy.reuseDistance / 111_320
        let lonSpan = span / max(0.01, cos(candidate.centroid.latitude * .pi / 180))
        let rows = try await database.read { [candidate] db in
            try Row.fetchAll(db, sql: """
                SELECT c.cell, c.lat, c.lon, p.payload, p.apple_locality, p.apple_country FROM cell c JOIN poi_cache p ON p.cell = c.cell
                WHERE c.poi_status = 1 AND c.covered_by IS NULL AND c.cell != ? AND c.lat BETWEEN ? AND ? AND c.lon BETWEEN ? AND ?
                """, arguments: [candidate.cell, candidate.centroid.latitude - span, candidate.centroid.latitude + span,
                                 candidate.centroid.longitude - lonSpan, candidate.centroid.longitude + lonSpan])
                .map { row in (cell: row["cell"] as String, centroid: Coordinate(latitude: row["lat"], longitude: row["lon"]),
                               payload: row["payload"] as Data?, locality: row["apple_locality"] as String?, country: row["apple_country"] as String?) }
        }
        guard let nearest = rows.filter({ $0.centroid.distance(to: candidate.centroid) <= policy.reuseDistance })
            .min(by: { $0.centroid.distance(to: candidate.centroid) < $1.centroid.distance(to: candidate.centroid) }) else { return nil }
        let address = nearest.locality == nil && nearest.country == nil ? nil : MapAddress(cityName: nearest.locality, countryCode: nearest.country)
        return Answer(places: Self.decode(nearest.payload), address: address, coveredBy: nearest.cell, fetched: false)
    }

    /// The cell's own cached answer: always for a named cell, for 30 days when nothing was found.
    private func cachedAnswer(for candidate: Candidate) async throws -> Answer? {
        let freshSince = Int64(clock.now.timeIntervalSince1970 - policy.noneRetry)
        guard let row = try await database.read({ [candidate] db in
            try Row.fetchOne(db, sql: "SELECT fetched_at, status, payload, apple_locality, apple_country FROM poi_cache WHERE cell = ?",
                             arguments: [candidate.cell]).map { row in
                (status: row["status"] as Int, fetched: row["fetched_at"] as Int64, payload: row["payload"] as Data?,
                 locality: row["apple_locality"] as String?, country: row["apple_country"] as String?)
            }
        }) else { return nil }
        guard row.status == PlaceNameStatus.named.rawValue || row.fetched >= freshSince else { return nil }
        let address = row.locality == nil && row.country == nil ? nil : MapAddress(cityName: row.locality, countryCode: row.country)
        return Answer(places: Self.decode(row.payload), address: address, fetched: false)
    }

    /// The area whose radius covers `centroid` most tightly (distance ÷ radius); a tie goes to the larger radius.
    static func assign(_ places: [MapPlace], to centroid: Coordinate) -> MapPlace? {
        places.filter(\.category.isArea).compactMap { place -> (place: MapPlace, ratio: Double, radius: Double)? in
            let radius = place.category.radius(boundingRadius: place.boundingRadius)
            let distance = place.coordinate.distance(to: centroid)
            return distance <= radius ? (place, distance / radius, radius) : nil
        }.min { ($0.ratio, -$0.radius) < ($1.ratio, -$1.radius) }?.place
    }

    /// One transaction of targeted writes: Apple's areas as places, the cell's naming columns, the cache for a
    /// new answer, and the cell's days for the indexer to restructure.
    private func write(_ candidate: Candidate, _ answer: Answer) async throws -> Outcome {
        let now = Int64(clock.now.timeIntervalSince1970)
        let assigned = Self.assign(answer.places, to: candidate.centroid)
        let status = assigned == nil ? PlaceNameStatus.none : .named
        let retry = status == .none ? now + Int64(policy.noneRetry) : nil
        let payload = try JSONEncoder().encode(answer.places)
        let written = try await database.write { db -> Bool in
            guard try Int.fetchOne(db, sql: "SELECT poi_status FROM cell WHERE cell = ?", arguments: [candidate.cell]) == candidate.status else { return false }
            var places = PlaceRows(db)
            var poi: Int64?
            for place in answer.places where place.category.isArea {
                let id = try places.id(PlaceSpec(poi: place), refresh: true)
                if place == assigned { poi = id }
            }
            try db.execute(sql: """
                UPDATE cell SET poi_status = ?, poi_place = ?, fetched_at = ?, covered_by = ?, apple_locality = ?, apple_country = ?, attempts = 0,
                                retry_after = ? WHERE cell = ?
                """, arguments: [status.rawValue, poi, now, answer.coveredBy, answer.address?.cityName, answer.address?.countryCode, retry, candidate.cell])
            if answer.fetched {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO poi_cache (cell, fetched_at, status, payload, apple_locality, apple_country) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [candidate.cell, now, status.rawValue, payload, answer.address?.cityName, answer.address?.countryCode])
            }
            try db.execute(sql: "INSERT OR IGNORE INTO dirty_day SELECT DISTINCT day FROM asset WHERE cell = ? AND day IS NOT NULL",
                           arguments: [candidate.cell])
            return true
        }
        return written ? .written : .skipped
    }

    static func decode(_ payload: Data?) -> [MapPlace] {
        guard let payload else { return [] }
        return (try? JSONDecoder().decode([MapPlace].self, from: payload)) ?? []
    }

    // MARK: Maintenance

    /// Forgets Apple Maps' answers (the inspector's "Reset POI cache"): every cell is pending or ineligible again
    /// and its days are restructured, so the next run asks Apple again.
    public func resetCache() async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO dirty_day SELECT DISTINCT day FROM asset WHERE day IS NOT NULL AND cell IN (SELECT cell FROM cell WHERE poi_status IN (1, 2, 3, 4));
                UPDATE cell SET poi_status = CASE WHEN poi_status IN (1, 2, 3, 4) THEN 0 ELSE poi_status END, attempts = 0, retry_after = NULL,
                                fetched_at = NULL, covered_by = NULL, poi_place = NULL, apple_locality = NULL, apple_country = NULL;
                DELETE FROM poi_cache;
                """)
            try Meta.set(db, .mapsBackoffUntil, nil)
        }
        await budget.reportSuccess()
        await refreshCounts()
        publish(.idle)
    }

    // MARK: Progress

    private func refreshCounts() async {
        let fresh = try? await database.read { db in
            (named: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cell WHERE poi_status = 1") ?? 0,
             eligible: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cell WHERE poi_status NOT IN (5, 6)") ?? 0)
        }
        if let fresh { counts = fresh }
    }

    private func publish(_ state: PlaceNameProgress.State) {
        let progress = PlaceNameProgress(named: counts.named, eligible: counts.eligible, state: state)
        if progress != broadcaster.latest { broadcaster.send(progress) }
    }
}
