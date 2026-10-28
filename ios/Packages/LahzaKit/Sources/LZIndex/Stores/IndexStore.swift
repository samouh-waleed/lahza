import Foundation
import LZCore
import LZLibrary
import Observation

/// The search index as screens see it: its status, a reader while it is on, and the controls Settings offers.
///
/// It opens the index whenever photo access is readable and purges it (the whole `Index/` folder, saved places
/// included) whenever access is unreadable and an index exists, at launch too: iOS relaunches an app whose
/// access was revoked. Library changes become one sync after a 2 s debounce; returning to the foreground syncs,
/// going to the background pauses at the next batch. Apple Maps place naming runs only while Lahza is open,
/// access is readable, the toggle is on and some of the index is built.
///
/// Every transition (open, purge, delete, build again) runs in order, one at a time.
@MainActor @Observable public final class IndexStore {
    public private(set) var status: IndexStatus
    /// Nil while the index is off.
    public private(set) var reader: IndexReader?
    /// The `lahza.index.appleMapsNames` preference (on unless turned off).
    public private(set) var appleMapsNames: Bool

    /// Bumps on every committed change readers can see.
    public var version: Int64 { status.version }

    @ObservationIgnored private let dependencies: IndexDependencies
    @ObservationIgnored private var session: IndexSession?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var lastAccess: PhotoAccess?
    @ObservationIgnored private var transitions: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var accessTask: Task<Void, Never>?
    @ObservationIgnored private var placeNamesTask: Task<Void, Never>?
    /// Tells a finished naming pass from a newer one.
    @ObservationIgnored private var placeNamesRun = 0
    /// The index version the latest place-naming run started at.
    @ObservationIgnored private var placeNamesVersion: Int64 = -1
    @ObservationIgnored private var queueProgress = PlaceNameProgress()
    /// A damaged index was repaired since launch.
    @ObservationIgnored private var repaired = false
    @ObservationIgnored private let log = Log("index")

    static let pausedKey = KVKey.device("index.paused")
    static let appleMapsNamesKey = KVKey.device("index.appleMapsNames")
    static let unavailableMessage = "Search is unavailable"
    static let openFailedMessage = "Couldn't open the search index"

    public init(_ dependencies: IndexDependencies) {
        self.dependencies = dependencies
        appleMapsNames = dependencies.kv.string(forKey: Self.appleMapsNamesKey) != "0"
        status = IndexStatus(phase: dependencies.reader.access().canRead ? .preparing : .off(.noAccess))
    }

    // MARK: Lifecycle

    /// Opens the index if access is readable (purging it at once if not), then follows library changes and,
    /// with `photoAccess`, access changes. Calling it again does nothing.
    public func start(observing photoAccess: PhotoAccessStore? = nil) {
        guard !started else { return }
        started = true
        if dependencies.resetOnLaunch {
            try? IndexDatabase.destroy(dependencies.location)
            log.notice("Index reset at launch", privacy: .public)
        }
        let changes = dependencies.changes()
        changesTask = Task { [weak self] in
            for await _ in changes { self?.libraryChanged() }
        }
        if let photoAccess {
            accessTask = Task { [weak self] in
                for await _ in Observations({ photoAccess.access }) { self?.accessChanged() }
            }
        } else {
            accessChanged()
        }
    }

    /// Re-reads access: opens, purges or asks for a sync as it requires.
    func accessChanged() {
        transition { [weak self] in await self?.evaluate(reason: .accessChanged) }
    }

    /// The scene became active (resume, sync, name places) or went to the background (pause at the next batch,
    /// stop naming places, let SQLite optimise).
    public func setSceneActive(_ active: Bool) {
        guard active != sceneActive else { return }
        sceneActive = active
        if !active { stopPlaceNames() }
        transition { [weak self] in
            guard let self else { return }
            if active {
                if let session = self.session {
                    await session.indexer.resume()
                    await session.indexer.enqueue(.sync(.foreground))
                } else {
                    await self.evaluate(reason: .foreground)
                }
            } else if let session = self.session {
                await session.indexer.pause()
                try? await session.database.optimize(truncatingWAL: false)
            }
            self.refreshPlaceNames()
        }
    }

    /// Settings › Rebuild index: reads the library again from an empty index, keeping saved places and the
    /// Apple Maps cache.
    public func rebuild() async {
        await transition { [weak self] in await self?.session?.indexer.enqueue(.rebuild) }.value
    }

    /// Settings › Delete index: purges it and stays off until ``buildAgain()``.
    public func deleteIndex() async {
        await transition { [weak self] in
            guard let self else { return }
            self.dependencies.kv.setString("1", forKey: Self.pausedKey)
            await self.purge(.deletedByUser)
        }.value
    }

    /// Builds the index again after Delete index.
    public func buildAgain() {
        dependencies.kv.removeValue(forKey: Self.pausedKey)
        transition { [weak self] in await self?.evaluate(reason: .manual) }
    }

    /// Settings › Apple Maps place names. Off stops naming; names already found stay in the index.
    public func setAppleMapsNames(_ on: Bool) {
        dependencies.kv.setString(on ? "1" : "0", forKey: Self.appleMapsNamesKey)
        appleMapsNames = on
        if on { placeNamesVersion = -1 } else { stopPlaceNames() }
        refreshPlaceNames()
    }

    /// Names the cells of the moment cards on screen first.
    public func prioritizePlaceNames(cells: [String]) {
        guard let session, !cells.isEmpty else { return }
        Task { await session.placeNames.prioritize(cells: cells) }
    }

    /// Returns once every transition has run and the indexer's queue is empty (tests).
    public func settled() async {
        await transitions?.value
        guard let session else { return }
        await session.indexer.settled()
        apply(await session.indexer.currentStatus(), generation: session.generation)
    }

    /// Returns once the running place-naming pass and the restructure it asked for are done (tests).
    public func placeNamesSettled() async {
        await settled()
        await placeNamesTask?.value
        await settled()
    }

    // MARK: DEBUG tools

    /// The index inspector's actions.
    public enum Maintenance: Sendable {
        /// Every day's moments, trips and labels again, without reading the library.
        case restructureAll
        /// Forgets the change token: the next sync reads the whole library.
        case forgetChangeToken
        /// Forgets Apple Maps' answers, so place naming asks again.
        case resetPlaceNameCache
    }

    public func perform(_ maintenance: Maintenance) async {
        guard let session else { return }
        do {
            switch maintenance {
            case .restructureAll:
                try await session.indexer.restructureAll()
            case .forgetChangeToken:
                try await session.indexer.forgetChangeToken()
                await session.indexer.enqueue(.sync(.manual))
            case .resetPlaceNameCache:
                stopPlaceNames()
                try await session.placeNames.resetCache()
                await session.indexer.enqueue(.restructure)
                placeNamesVersion = -1
            }
        } catch {
            log.error("Index maintenance failed: \(IndexDatabase.code(of: error))", privacy: .public)
        }
        await settled()
        refreshPlaceNames()
    }

    // MARK: Transitions

    @discardableResult
    private func transition(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = transitions
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        transitions = task
        return task
    }

    /// Opens, purges or syncs, as access, the Delete index preference and data protection allow.
    private func evaluate(reason: SyncReason) async {
        let access = dependencies.reader.access()
        defer { lastAccess = access }
        guard access.canRead else {
            if session != nil || IndexDatabase.exists(dependencies.location) {
                log.notice("Photo access unreadable: purging the index", privacy: .public)
                await purge(.noAccess)
            } else {
                status = IndexStatus(phase: .off(.noAccess))
            }
            return
        }
        if dependencies.kv.string(forKey: Self.pausedKey) != nil {
            // Also a file a failed or interrupted Delete index left behind.
            if session != nil || IndexDatabase.exists(dependencies.location) { await purge(.deletedByUser) }
            status = IndexStatus(phase: .off(.deletedByUser))
            return
        }
        if let session {
            if let lastAccess, lastAccess != access { await session.indexer.enqueue(.sync(.accessChanged)) }
            return
        }
        guard dependencies.isProtectedDataAvailable() else {
            status = IndexStatus(phase: .off(.protectedDataUnavailable))
            return
        }
        guard await open() else { return }
        await session?.indexer.enqueue(.sync(reason == .accessChanged && lastAccess == nil ? .launch : reason))
    }

    private func open() async -> Bool {
        guard let gazetteer = dependencies.gazetteer else {
            status = IndexStatus(phase: .failed(Self.unavailableMessage))
            return false
        }
        do {
            let database = try await Self.openDatabase(dependencies.location)
            generation += 1
            let session = IndexSession(database: database, gazetteer: gazetteer, dependencies: dependencies, generation: generation)
            self.session = session
            reader = session.reader
            placeNamesVersion = -1
            queueProgress = PlaceNameProgress()
            observe(session)
            return true
        } catch {
            log.error("Index open failed: \(IndexDatabase.code(of: error))", privacy: .public)
            status = IndexStatus(phase: .failed(Self.openFailedMessage))
            return false
        }
    }

    @concurrent private nonisolated static func openDatabase(_ location: IndexLocation) async throws -> IndexDatabase {
        try IndexDatabase.open(location)
    }

    /// Stops everything over the index, closes it and removes its folder (search spec §2.5's order).
    private func purge(_ reason: IndexStatus.OffReason) async {
        stopPlaceNames()
        statusTask?.cancel()
        progressTask?.cancel()
        if let session {
            self.session = nil
            reader = nil
            await session.indexer.stop()
            await session.database.close()
        }
        do {
            try IndexDatabase.destroy(dependencies.location)
        } catch {
            log.error("Index purge failed: \(IndexDatabase.code(of: error))", privacy: .public)
        }
        status = IndexStatus(phase: .off(reason))
    }

    private func observe(_ session: IndexSession) {
        let generation = session.generation
        let statuses = session.indexer.status, progress = session.placeNames.progress
        statusTask = Task { [weak self] in
            for await status in statuses { self?.apply(status, generation: generation) }
        }
        progressTask = Task { [weak self] in
            for await value in progress {
                guard let self, self.generation == generation else { return }
                self.queueProgress = value
                self.status.placeNames = self.placeNameProgress
            }
        }
    }

    private func apply(_ indexer: IndexStatus, generation: Int) {
        guard generation == self.generation, let session else { return }
        var status = indexer
        status.placeNames = placeNameProgress
        self.status = status
        refreshPlaceNames()
        if case .failed = status.phase, session.database.needsRebuild, !repaired {
            repaired = true
            transition { [weak self] in await self?.repair() }
        }
    }

    /// A job found the file damaged: closes it and opens it again, which rebuilds it (keeping saved places), then
    /// reads the library. Once per launch, so a file that keeps getting damaged can't loop; it stays failed.
    func repair() async {
        guard let session else { return }
        log.fault("Index damaged: reopening to rebuild", privacy: .public)
        stopPlaceNames()
        statusTask?.cancel()
        progressTask?.cancel()
        self.session = nil
        reader = nil
        await session.indexer.stop()
        await session.database.close()
        await evaluate(reason: .launch)
    }

    private func libraryChanged() {
        debounceTask?.cancel()
        let clock = dependencies.clock, delay = dependencies.changeDebounce
        debounceTask = Task { [weak self] in
            guard (try? await clock.sleep(for: delay)) != nil, let session = self?.session else { return }
            await session.indexer.enqueue(.sync(.libraryChanged))
        }
    }

    // MARK: Place names

    /// What the place-name queue is doing, as Settings shows it.
    private var placeNameProgress: PlaceNameProgress {
        var progress = queueProgress
        if !appleMapsNames {
            progress.state = .off
        } else if !sceneActive {
            progress.state = .backgrounded
        }
        return progress
    }

    /// Starts a naming pass when it may run and the index changed since the last one; stops it when it may not.
    private func refreshPlaceNames() {
        let phase = status.phase
        let indexOn: Bool = switch phase {
        case .off, .failed, .paused: false
        default: true
        }
        let mayRun = session != nil && sceneActive && appleMapsNames && indexOn && status.version > 0 && dependencies.reader.access().canRead
        if mayRun, placeNamesTask == nil, status.version != placeNamesVersion, let session {
            placeNamesVersion = status.version
            placeNamesRun += 1
            let queue = session.placeNames, run = placeNamesRun
            placeNamesTask = Task { [weak self] in
                await queue.run()
                self?.placeNamesFinished(run)
            }
        } else if !mayRun {
            stopPlaceNames()
        }
        status.placeNames = placeNameProgress
    }

    private func placeNamesFinished(_ run: Int) {
        guard run == placeNamesRun else { return }
        placeNamesTask = nil
        refreshPlaceNames()
    }

    /// Cancels the running pass; the next time naming may run, it starts again whatever the version.
    private func stopPlaceNames() {
        if placeNamesTask != nil {
            placeNamesVersion = -1
            log.info("Place names stopped\(sceneActive ? "" : ": Lahza is in the background")", privacy: .public)
        }
        placeNamesTask?.cancel()
        placeNamesTask = nil
        placeNamesRun += 1
        status.placeNames = placeNameProgress
    }
}
