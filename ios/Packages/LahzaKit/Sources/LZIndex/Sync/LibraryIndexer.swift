import Foundation
import LZCore
import LZGeo
import LZLibrary
import Synchronization
internal import GRDB

/// The one writer of the library-derived tables: it syncs the index with the photo library (P0, P5) and runs
/// the structure pass (P0b) over what changed.
///
/// Jobs queue up and run one at a time, so actor reentrancy never interleaves two of them: an enqueue during a
/// job only adds to the pending set (syncs coalesce; a rebuild supersedes them). A sync applies PhotoKit's
/// persistent-history delta, or reads the whole library when the history can't say (first run, an expired or
/// undecodable token, too many changes, limited access, a changed access scope, the library having been
/// unavailable). A full scan reads newest first in batches, each committed with its frontier, so a kill costs
/// at most one batch and the next launch resumes; it sweeps what it didn't see and then applies the delta since
/// it started, writing the new token in the same transaction as the last rows it covers.
public actor LibraryIndexer {
    private let database: IndexDatabase
    private let reader: any LibraryReader
    private let clock: any AppClock
    private let deviceTimeZone: @Sendable () -> TimeZone
    private let settings: IndexerSettings
    private let structure: any StructurePass
    private let faults: IndexFaults?
    private let geo: GeoCache
    /// The gazetteer's identity: sourceDate·2³² + CRC32.
    private let gazetteerVersion: Int64
    private let broadcaster: StatusBroadcaster
    private let availabilityEvents: AsyncStream<LibraryAvailability>
    private let log = Log("index")

    static let unavailableMessage = "Photo library unavailable"
    static let failureMessage = "Couldn't update the search index"

    private var pending = Set<IndexJob>()
    private var runner: Task<Void, Never>?
    private var paused = false
    private var stopped = false
    private var libraryUnavailable = false
    private var versionsChecked = false
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    private var availabilityTask: Task<Void, Never>?
    private var current = IndexStatus(phase: .preparing)
    /// The device zone the running job derives GPS-less assets with.
    private var deviceZone = TimeZone.current.identifier
    private var scan = ScanProgress()
    /// The running rebuild has emptied the derived tables: from then on, an interruption resumes rather than restarts it.
    private var rebuildCleared = false
    /// Counters since this indexer started (logs, the inspector, tests).
    private(set) var stats = IndexerStats()

    public init(database: IndexDatabase, reader: any LibraryReader, gazetteer: Gazetteer, clock: any AppClock,
                deviceTimeZone: @escaping @Sendable () -> TimeZone, settings: IndexerSettings = .init()) {
        self.init(database: database, reader: reader, gazetteer: gazetteer, clock: clock, deviceTimeZone: deviceTimeZone,
                  settings: settings, structure: LiveStructurePass(), faults: nil)
    }

    init(database: IndexDatabase, reader: any LibraryReader, gazetteer: Gazetteer, clock: any AppClock,
         deviceTimeZone: @escaping @Sendable () -> TimeZone, settings: IndexerSettings = .init(),
         structure: any StructurePass, faults: IndexFaults?) {
        self.database = database
        self.reader = reader
        self.clock = clock
        self.deviceTimeZone = deviceTimeZone
        self.settings = settings
        self.structure = structure
        self.faults = faults
        geo = GeoCache(gazetteer: gazetteer)
        gazetteerVersion = Int64(gazetteer.sourceDate) << 32 | Int64(gazetteer.dataVersion)
        broadcaster = StatusBroadcaster(IndexStatus(phase: .preparing))
        // Subscribed now (it buffers the latest event); listened to once the first job is enqueued.
        availabilityEvents = reader.availability()
    }

    deinit {
        availabilityTask?.cancel()
    }

    /// The indexer's status: a fresh stream per subscriber, starting with the current status and keeping only
    /// the newest one when the subscriber lags.
    public nonisolated var status: AsyncStream<IndexStatus> { broadcaster.stream() }

    // MARK: Queue

    /// Adds a job; it coalesces with pending ones and runs after the current job.
    public func enqueue(_ job: IndexJob) {
        guard !stopped else { return }
        listenForAvailability()
        pending.insert(job)
        startRunnerIfNeeded()
    }

    /// Stops at the next batch boundary and returns once the current job has stopped. The interrupted job goes
    /// back into the queue; a scan resumes from its frontier.
    public func pause() async {
        guard !stopped else { return }
        paused = true
        if let runner {
            await runner.value
        } else {
            publish(libraryUnavailable ? .failed(Self.unavailableMessage) : .paused)
        }
    }

    public func resume() {
        guard paused, !stopped else { return }
        paused = false
        if pending.isEmpty, !libraryUnavailable { publish(.ready) }
        startRunnerIfNeeded()
    }

    /// Cancels the current job, drops the queue and returns once nothing runs (before a purge or teardown).
    /// The status stream ends.
    public func stop() async {
        stopped = true
        pending.removeAll()
        runner?.cancel()
        if let runner { await runner.value }
        availabilityTask?.cancel()
        availabilityTask = nil
        broadcaster.finish()
        resumeSettleWaiters()
    }

    /// Returns when the queue is empty (or paused, or stopped). For tests.
    public func settled() async {
        guard runner != nil else { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }

    /// The latest status (what a new ``status`` subscriber gets first).
    public func currentStatus() -> IndexStatus { current }

    /// Forgets the change token, so the next sync reads the whole library (the inspector's "Forget change token").
    public func forgetChangeToken() async throws {
        try await database.write { db in try Meta.set(db, .libraryToken, nil) }
    }

    /// Marks every day dirty and restructures (the inspector's "Re-run structure").
    public func restructureAll() async throws {
        try await database.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO dirty_day SELECT DISTINCT day FROM asset WHERE day IS NOT NULL")
        }
        enqueue(.restructure)
    }

    private func startRunnerIfNeeded() {
        guard runner == nil, !paused, !stopped, !pending.isEmpty else { return }
        runner = Task { await self.drain() }
    }

    private func resumeSettleWaiters() {
        let waiters = settleWaiters
        settleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// What one turn of the loop runs: the pending jobs it covers.
    private enum Work {
        case rebuild
        case sync(Set<SyncReason>)
        case restructure

        var jobs: [IndexJob] {
            switch self {
            case .rebuild: [.rebuild]
            case .sync(let reasons): reasons.map { .sync($0) }
            case .restructure: [.restructure]
            }
        }
    }

    /// A rebuild covers everything pending; a sync covers the other syncs and a restructure (it ends with the
    /// structure pass over every dirty day).
    private func takeNext() -> Work? {
        if pending.contains(.rebuild) {
            pending.removeAll()
            return .rebuild
        }
        var reasons = Set<SyncReason>()
        for case .sync(let reason) in pending { reasons.insert(reason) }
        if !reasons.isEmpty {
            pending = pending.filter { if case .sync = $0 { false } else { $0 != .restructure } }
            return .sync(reasons)
        }
        return pending.remove(.restructure).map { _ in .restructure }
    }

    private func drain() async {
        while !paused, !stopped, !Task.isCancelled, let work = takeNext() {
            do {
                try await perform(work)
            } catch {
                if stopped || Task.isCancelled { break }
                if case IndexerInterruption.paused = error {
                    // A rebuild that has emptied the tables continues as a sync, which resumes its scan.
                    pending.formUnion(rebuildCleared ? [.sync(.manual)] : work.jobs)
                    break
                }
                if case LibraryReaderError.noAccess = error {
                    pending.removeAll()
                    publish(.off(.noAccess))
                    break
                }
                if case IndexError.closed = error {
                    pending.removeAll()
                    break
                }
                if IndexDatabase.isDamaged(error) { database.noteCorruption() }
                log.error("Index job failed: \(IndexDatabase.code(of: error))", privacy: .public)
                publish(.failed(Self.failureMessage))
            }
        }
        runner = nil
        if paused, !stopped { publish(libraryUnavailable ? .failed(Self.unavailableMessage) : .paused) }
        resumeSettleWaiters()
    }

    // MARK: Jobs

    private func perform(_ work: Work) async throws {
        rebuildCleared = false
        let started = ContinuousClock.now
        let before = stats.writes
        guard reader.access().canRead else { throw LibraryReaderError.noAccess }
        deviceZone = deviceTimeZone().identifier
        try await refreshStatus(nil)
        var changed = try await checkDerivedVersions()
        var scanned = false
        switch work {
        case .rebuild:
            try await clearDerivedTables()
            rebuildCleared = true
            scanned = try await fullScan(.rebuild)
        case .sync(let reasons):
            scanned = try await sync(reasons)
        case .restructure:
            break
        }
        changed = changed || scanned || stats.writes.changed != before.changed
        try checkInterruption()
        if scanned { publish(.organizing) }
        changed = try await structure.run(database, structureRun(daysAfter: nil, final: true)) || changed
        if changed { try await database.write { db in _ = try Meta.bumpVersion(db) } }
        if scanned { try await database.optimize() }
        try await refreshStatus(.ready)
        let delta = stats.writes - before
        let milliseconds = Int((ContinuousClock.now - started).seconds * 1_000)
        log.info("Index job done in \(milliseconds) ms: \(delta.inserted) inserted, \(delta.updated) updated, \(delta.deleted) deleted, \(delta.unchanged) unchanged",
                 privacy: .public)
    }

    /// Applies the history's delta, or reads everything when it can't be trusted. Returns whether a full
    /// scan ran.
    private func sync(_ reasons: Set<SyncReason>) async throws -> Bool {
        let access = reader.access()
        let state = try await database.read { db in try SyncState(db) }
        if libraryUnavailable {
            libraryUnavailable = false
            return try await fullScan(.libraryUnavailable)
        }
        if state.phase != .idle {
            // A limited selection is small and may have changed: read it again rather than resume.
            if access == .limited { return try await fullScan(.limitedAccess) }
            if state.accessScope != access.scope { return try await fullScan(.accessScopeChanged) }
            stats.resumedScans += 1
            log.notice("Full scan resumed (\(state.phase.rawValue))", privacy: .public)
            return try await continueFullScan(restarts: 0)
        }
        guard let token = state.libraryToken else { return try await fullScan(state.firstBuildDone ? .tokenExpired : .firstRun) }
        if state.accessScope != access.scope { return try await fullScan(.accessScopeChanged) }
        if access == .limited { return try await fullScan(.limitedAccess) }
        var retried = false
        while true {
            try checkInterruption()
            switch await reader.delta(since: token) {
            case .unchanged:
                if reasons.contains(.libraryChanged), !retried {
                    retried = true
                    try await clock.sleep(for: settings.changeRetryDelay)
                    continue
                }
                let now = clock.now
                try await database.write { db in try Meta.set(db, .lastSync, date: now) }
                return false
            case .needsFullScan(let reason):
                return try await fullScan(reason)
            case .changes(let inserted, let updated, let deleted, let through):
                let delta = Delta(inserted: inserted, updated: updated, deleted: deleted)
                let indexed = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0 }
                let threshold = max(settings.reconcileThreshold.minimum, Int(settings.reconcileThreshold.fraction * Double(indexed)))
                if delta.count > threshold { return try await fullScan(.tooManyChanges) }
                stats.deltas += 1
                try await apply(delta, through: through, finishingScan: false)
                return false
            }
        }
    }

    // MARK: Full scan

    /// Starts a full scan: takes the change token before reading anything, so the catch-up delta covers every
    /// change made while the scan runs.
    private func fullScan(_ reason: FullScanReason, restarts: Int = 0) async throws -> Bool {
        stats.fullScans[reason, default: 0] += 1
        log.notice("Full scan: \(reason.rawValue)", privacy: .public)
        publish(.preparing)
        let token = try reader.currentToken()
        let total = await reader.estimatedCount()
        let scope = reader.access().scope
        try await database.write { db in
            try Meta.set(db, .pendingToken, token.data)
            try Meta.set(db, .scanGen, (try Meta.int(db, .scanGen) ?? 0) + 1)
            try Meta.set(db, .scanPhase, ScanPhase.dated.rawValue)
            try Meta.set(db, .scanTotal, total)
            try Meta.set(db, .scanDone, 0)
            try Meta.set(db, .scanFrontier, nil)
            try Meta.set(db, .scanReason, reason.rawValue)
            try Meta.set(db, .accessScope, scope)
        }
        return try await continueFullScan(restarts: restarts)
    }

    /// Runs (or resumes) a full scan from the phase and frontier in `meta`: dated assets newest first, then the
    /// undated ones, the sweep, and the catch-up delta.
    private func continueFullScan(restarts: Int) async throws -> Bool {
        let state = try await database.read { db in try SyncState(db) }
        guard let pendingToken = state.pendingToken else { return try await fullScan(.historyFailed, restarts: restarts + 1) }
        let now = clock.now
        scan = ScanProgress(generation: state.generation, done: state.done, total: state.total, frontier: state.frontier,
                            isPartial: !state.firstBuildDone, lastCheckpoint: now)
        current.isPartial = scan.isPartial
        if state.phase == .dated {
            publishProgress(force: true)
            let frontier = state.frontier.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            try await reader.scanDated(createdAtOrBefore: frontier, batchSize: settings.batchSize) { batch in
                try await self.ingest(batch, dated: true)
            }
            try checkInterruption()
            try await database.write { db in try Meta.set(db, .scanPhase, ScanPhase.undated.rawValue) }
        }
        if state.phase == .dated || state.phase == .undated {
            try await reader.scanUndated(batchSize: settings.batchSize) { batch in
                try await self.ingest(batch, dated: false)
            }
            try checkInterruption()
            let generation = scan.generation
            let counts = try await database.write { [geo, deviceZone, faults] db in
                var writer = try AssetWriter(db, geo: geo, deviceZone: deviceZone)
                try writer.sweep(olderThan: generation)
                try writer.finish()
                try Meta.set(db, .scanPhase, ScanPhase.catchup.rawValue)
                try faults?.beforeCommit(.sweep)
                return writer.counts
            }
            stats.writes += counts
        }
        try checkInterruption()
        switch await reader.delta(since: LibraryToken(data: pendingToken)) {
        case .unchanged(let token):
            let now = clock.now
            try await database.write { db in try Self.finishScan(db, token: token, now: now) }
        case .changes(let inserted, let updated, let deleted, let through):
            try await apply(Delta(inserted: inserted, updated: updated, deleted: deleted), through: through, finishingScan: true)
        case .needsFullScan(let reason):
            guard restarts < 2 else { throw IndexerFailure.scanKeepsRestarting }
            return try await fullScan(reason, restarts: restarts + 1)
        }
        log.notice("Full scan finished", privacy: .public)
        return true
    }

    /// One scan batch, in one transaction with the frontier and the progress counters.
    private func ingest(_ batch: [LibraryAsset], dated: Bool) async throws {
        try checkInterruption()
        let now = clock.now
        let records = batch.compactMap { AssetRecord($0, now: now) }
        // Rounded up: re-reading the frontier's second is a harmless upsert; rounding down could skip assets.
        let frontier = dated ? batch.compactMap(\.facts.creationDate).min().map { Int64($0.timeIntervalSince1970.rounded(.up)) } : nil
        let generation = scan.generation, before = scan.done
        let point: IndexFaults.Point = dated ? .scanBatch(scan.datedBatches) : .undatedBatch(scan.undatedBatches)
        let (counts, done) = try await database.write { [geo, deviceZone, faults] db in
            var writer = try AssetWriter(db, geo: geo, deviceZone: deviceZone)
            try writer.upsert(records, generation: generation)
            try writer.finish()
            // What a resumed scan reads again was counted before it stopped.
            let done = before + batch.count - writer.repeated
            if let frontier { try Meta.set(db, .scanFrontier, frontier) }
            try Meta.set(db, .scanDone, done)
            try faults?.beforeCommit(point)
            return (writer.counts, done)
        }
        stats.writes += counts
        scan.done = done
        if dated { scan.datedBatches += 1 } else { scan.undatedBatches += 1 }
        scan.sinceCheckpoint += batch.count
        if let frontier { scan.frontier = frontier }
        publishProgress(force: false)
        if dated { try await checkpointIfDue() }
        if settings.pacePerBatch > .zero { try await Task.sleep(for: settings.pacePerBatch) }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Every ``IndexerSettings/checkpointAssets`` assets or ``IndexerSettings/checkpointInterval``: the structure
    /// pass over the days the scan has finished, then a new index version, so recent photos are searchable long
    /// before a large library is read.
    private func checkpointIfDue() async throws {
        let now = clock.now
        let due = scan.sinceCheckpoint >= settings.checkpointAssets
            || now.timeIntervalSince(scan.lastCheckpoint) >= settings.checkpointInterval.seconds
        guard due, let frontier = scan.frontier else { return }
        scan.sinceCheckpoint = 0
        scan.lastCheckpoint = now
        _ = try await structure.run(database, structureRun(daysAfter: Self.lastOpenDay(frontier: frontier), final: false))
        try await database.write { db in _ = try Meta.bumpVersion(db) }
        stats.checkpoints += 1
        try await refreshStatus(current.phase)
    }

    /// The structure pass's inputs for the running job; it stops between transactions for a pause or a cancel.
    private func structureRun(daysAfter: Int32?, final: Bool) -> StructureRun {
        StructureRun(daysAfter: daysAfter, final: final, deviceZone: deviceZone, now: clock.now, geo: geo) { [weak self] in
            try await self?.checkInterruption()
        }
    }

    /// The latest moment day the rest of a scan can still add to (or borrow a zone into): assets not read yet were
    /// created at or before `frontier`, so their wall time is at most 14 h later (the widest zone offset), and zone
    /// borrowing reaches 12 h further.
    static func lastOpenDay(frontier: Int64) -> Int32 {
        LocalTime.momentDay(wallSeconds: frontier + (14 + 12) * 3_600)
    }

    /// The end of a full scan, in the same transaction as its last catch-up rows.
    private static func finishScan(_ db: Database, token: LibraryToken, now: Date) throws {
        try Meta.set(db, .libraryToken, token.data)
        try Meta.set(db, .pendingToken, nil)
        try Meta.set(db, .scanPhase, ScanPhase.idle.rawValue)
        try Meta.set(db, .scanFrontier, nil)
        try Meta.set(db, .firstBuildDone, 1)
        try Meta.set(db, .lastFullScan, date: now)
        try Meta.set(db, .lastSync, date: now)
    }

    // MARK: Delta

    /// Re-reads inserted and updated assets by id (missing ones are hidden, gone or no longer shared, and are
    /// deleted), then deletes the deleted ones. Each chunk is one transaction; the token is written only with the
    /// last, so a crash in between replays the delta from the old token (upserts and deletes are idempotent).
    private func apply(_ delta: Delta, through token: LibraryToken, finishingScan: Bool) async throws {
        let ids = delta.reRead
        let size = max(1, settings.batchSize)
        let chunks = stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min(ids.count, $0 + size)]) }
        let count = max(1, chunks.count)
        let generation = try await database.read { db in try Meta.int(db, .scanGen) ?? 0 }
        for index in 0..<count {
            try checkInterruption()
            let chunk = index < chunks.count ? chunks[index] : []
            let present = chunk.isEmpty ? [] : try await reader.assets(withIDs: chunk)
            let now = clock.now
            let records = present.compactMap { AssetRecord($0, now: now) }
            let isLast = index == count - 1
            let gone = Set(chunk).subtracting(records.map(\.localID)).sorted() + (isLast ? delta.deleted.sorted() : [])
            let counts = try await database.write { [geo, deviceZone, faults] db in
                var writer = try AssetWriter(db, geo: geo, deviceZone: deviceZone)
                try writer.upsert(records, generation: generation)
                try writer.delete(localIDs: gone)
                try writer.finish()
                if isLast {
                    if finishingScan {
                        try Self.finishScan(db, token: token, now: now)
                    } else {
                        try Meta.set(db, .libraryToken, token.data)
                        try Meta.set(db, .lastSync, date: now)
                    }
                }
                try faults?.beforeCommit(.deltaChunk(index: index, isLast: isLast))
                return writer.counts
            }
            stats.writes += counts
        }
    }

    // MARK: Derivation versions

    /// Once per indexer: a new structure version or gazetteer marks every day dirty (a new gazetteer also
    /// derives located assets again). Every job: a new device zone derives the GPS-less, unborrowed assets
    /// again. Returns whether anything was marked.
    private func checkDerivedVersions() async throws -> Bool {
        let checkVersions = !versionsChecked
        let zone = deviceZone
        let check = try await database.write { [gazetteerVersion] db in
            var dirtied = false
            let hasAssets = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM asset)") ?? false
            if checkVersions {
                let structureChanged = try Meta.int(db, .structureVersion) != Int64(IndexSchema.structureVersion)
                let gazetteerChanged = try Meta.int(db, .gazetteerVersion) != gazetteerVersion
                if hasAssets, structureChanged || gazetteerChanged {
                    try db.execute(sql: "INSERT OR IGNORE INTO dirty_day SELECT DISTINCT day FROM asset WHERE day IS NOT NULL")
                    dirtied = true
                }
                if hasAssets, gazetteerChanged { try Meta.set(db, .rederiveLocated, 1) }
                try Meta.set(db, .structureVersion, IndexSchema.structureVersion)
                try Meta.set(db, .gazetteerVersion, gazetteerVersion)
            }
            // A changed zone is recorded only once the assets are derived again, so an interrupted pass reruns.
            let storedZone = try Meta.string(db, .deviceTimeZone)
            let zoneChanged = hasAssets && storedZone != nil && storedZone != zone
            if !zoneChanged { try Meta.set(db, .deviceTimeZone, zone) }
            return (dirtied: dirtied, zoneChanged: zoneChanged, rederiveLocated: try Meta.int(db, .rederiveLocated) == 1)
        }
        versionsChecked = true
        if check.zoneChanged {
            log.notice("Device zone changed: deriving GPS-less assets again", privacy: .public)
            try await rederive(where: "tz_src = \(ZoneSource.device.rawValue) AND created_utc IS NOT NULL")
            try await database.write { db in try Meta.set(db, .deviceTimeZone, zone) }
        }
        if check.rederiveLocated {
            log.notice("Gazetteer changed: deriving located assets again", privacy: .public)
            try await rederive(where: "lat IS NOT NULL")
            try await database.write { db in try Meta.set(db, .rederiveLocated, nil) }
        }
        return check.dirtied || check.zoneChanged || check.rederiveLocated
    }

    /// Derives the zone, wall time, day and cell of the matching assets again, in batches, marking changed days.
    private func rederive(where condition: String) async throws {
        var after: Int64 = 0
        while true {
            try checkInterruption()
            let last = try await database.write { [after, geo, deviceZone, settings] db -> Int64? in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT \(AssetWriter.Rederivable.columns) FROM asset WHERE \(condition) AND id > ? ORDER BY id LIMIT ?
                    """, arguments: [after, max(1, settings.batchSize) * 4]).map(AssetWriter.Rederivable.init)
                var writer = try AssetWriter(db, geo: geo, deviceZone: deviceZone)
                for row in rows { try writer.rederive(row) }
                try writer.finish()
                return rows.last?.id
            }
            guard let last else { return }
            after = last
        }
    }

    /// Settings › Rebuild index: in one transaction, empties every library-derived table, keeping saved places,
    /// remembered picks, their place rows and the Apple Maps caches.
    private func clearDerivedTables() async throws {
        try await database.write { db in
            try db.execute(sql: """
                DELETE FROM asset; DELETE FROM moment; DELETE FROM trip; DELETE FROM home_base;
                DELETE FROM place WHERE kind NOT IN (6, 8); DELETE FROM cell; DELETE FROM dirty_day;
                """)
            let scanKeys: [MetaKey] = [.libraryToken, .pendingToken, .scanPhase, .scanFrontier, .scanTotal, .scanDone, .scanReason,
                                       .accessScope, .firstBuildDone, .lastFullScan, .rederiveLocated]
            for key in scanKeys { try Meta.set(db, key, nil) }
            // Place counts must be redone even if the library turns out empty.
            try Meta.markStructureDue(db)
            try Meta.bumpVersion(db)
        }
    }

    // MARK: Interruption, availability, status

    /// Between batches: stop for a cancel (``stop()``) or a ``pause()``.
    private func checkInterruption() throws {
        try Task.checkCancellation()
        if paused { throw IndexerInterruption.paused }
    }

    private func listenForAvailability() {
        guard availabilityTask == nil else { return }
        let events = availabilityEvents
        availabilityTask = Task { [weak self] in
            for await event in events where event == .unavailable {
                await self?.libraryBecameUnavailable()
            }
        }
    }

    /// Pauses; the next sync after ``resume()`` reads the whole library again.
    private func libraryBecameUnavailable() {
        log.notice("Photo library unavailable: indexing paused", privacy: .public)
        libraryUnavailable = true
        paused = true
        publish(.failed(Self.unavailableMessage))
    }

    private func publish(_ phase: IndexStatus.Phase) {
        current.phase = phase
        current.isLimited = reader.access() == .limited
        broadcaster.send(current)
    }

    /// Reading progress, at most every ``IndexerSettings/progressInterval``.
    private func publishProgress(force: Bool) {
        let now = clock.now
        if !force, let last = scan.lastProgress, now.timeIntervalSince(last) < settings.progressInterval.seconds { return }
        scan.lastProgress = now
        current.coveredSince = scan.isPartial ? scan.frontier.map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        publish(.reading(done: scan.done, total: max(scan.total, scan.done)))
    }

    /// Reloads the persisted parts of the status (version, coverage, last sync, summary) and publishes it with
    /// `phase` (nil: ready once the first build is done, else preparing).
    private func refreshStatus(_ phase: IndexStatus.Phase?) async throws {
        let (state, summary) = try await database.read { db in (try SyncState(db), try IndexQueries.summary(db)) }
        current.isPartial = !state.firstBuildDone
        current.coveredSince = current.isPartial ? state.frontier.map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        current.version = state.version
        current.lastSync = state.lastSync
        current.summary = summary
        publish(phase ?? (state.firstBuildDone ? .ready : .preparing))
    }
}

// MARK: - Supporting types

/// Why a job stopped early without failing.
enum IndexerInterruption: Error {
    case paused
}

enum IndexerFailure: Error {
    /// The catch-up delta asked for yet another full scan, three times in a row.
    case scanKeepsRestarting
}

/// Test hooks: called inside write transactions just before they commit; a throw rolls the transaction back,
/// as if the app were killed there.
struct IndexFaults: Sendable {
    enum Point: Sendable, Hashable {
        /// The n-th dated batch (from 0) read by this run of a scan.
        case scanBatch(Int)
        case undatedBatch(Int)
        case sweep
        /// The n-th chunk of a delta; the last one writes the token.
        case deltaChunk(index: Int, isLast: Bool)
    }

    var beforeCommit: @Sendable (Point) throws -> Void
}

/// Counters since an indexer started.
struct IndexerStats: Sendable, Hashable {
    var writes = WriteCounts()
    var fullScans: [FullScanReason: Int] = [:]
    /// Incremental deltas applied (catch-up deltas not included).
    var deltas = 0
    var resumedScans = 0
    var checkpoints = 0
}

extension WriteCounts {
    static func - (lhs: WriteCounts, rhs: WriteCounts) -> WriteCounts {
        WriteCounts(inserted: lhs.inserted - rhs.inserted, updated: lhs.updated - rhs.updated,
                    unchanged: lhs.unchanged - rhs.unchanged, deleted: lhs.deleted - rhs.deleted)
    }
}

/// A delta normalised: a deletion wins over an insertion or update, and an insertion over an update.
struct Delta: Sendable, Hashable {
    var inserted: Set<String>
    var updated: Set<String>
    var deleted: Set<String>

    init(inserted: Set<String>, updated: Set<String>, deleted: Set<String>) {
        self.deleted = deleted
        self.inserted = inserted.subtracting(deleted)
        self.updated = updated.subtracting(deleted).subtracting(self.inserted)
    }

    var count: Int { inserted.count + updated.count + deleted.count }

    /// The ids to re-read, in a stable order.
    var reRead: [String] { inserted.union(updated).sorted() }
}

/// The running scan's counters (the persisted ones live in `meta`).
private struct ScanProgress {
    var generation: Int64 = 0
    var done = 0
    var total = 0
    var frontier: Int64?
    var isPartial = true
    var lastCheckpoint = Date.distantPast
    var lastProgress: Date?
    var sinceCheckpoint = 0
    var datedBatches = 0
    var undatedBatches = 0
}

/// The sync state in `meta`, read in one query.
struct SyncState {
    var phase: ScanPhase
    var libraryToken: LibraryToken?
    var pendingToken: Data?
    var accessScope: String?
    var firstBuildDone: Bool
    var generation: Int64
    var frontier: Int64?
    var total: Int
    var done: Int
    var version: Int64
    var lastSync: Date?

    init(_ db: Database) throws {
        var values: [String: DatabaseValue] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, value FROM meta") { values[row["key"]] = row["value"] as DatabaseValue }
        func value(_ key: MetaKey) -> DatabaseValue { values[key.rawValue] ?? .null }
        phase = String.fromDatabaseValue(value(.scanPhase)).flatMap(ScanPhase.init(rawValue:)) ?? .idle
        libraryToken = Data.fromDatabaseValue(value(.libraryToken)).map(LibraryToken.init(data:))
        pendingToken = Data.fromDatabaseValue(value(.pendingToken))
        accessScope = String.fromDatabaseValue(value(.accessScope))
        firstBuildDone = Int64.fromDatabaseValue(value(.firstBuildDone)) == 1
        generation = Int64.fromDatabaseValue(value(.scanGen)) ?? 0
        frontier = Int64.fromDatabaseValue(value(.scanFrontier))
        total = Int.fromDatabaseValue(value(.scanTotal)) ?? 0
        done = Int.fromDatabaseValue(value(.scanDone)) ?? 0
        version = Int64.fromDatabaseValue(value(.indexVersion)) ?? 0
        lastSync = Int64.fromDatabaseValue(value(.lastSync)).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

extension PhotoAccess {
    /// `meta.accessScope`: a change between full and limited means a full scan.
    var scope: String { self == .limited ? "limited" : "full" }
}

extension Duration {
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
