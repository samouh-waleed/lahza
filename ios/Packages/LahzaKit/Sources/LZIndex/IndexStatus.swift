import Foundation

/// Work for ``LibraryIndexer``'s queue.
public enum IndexJob: Sendable, Hashable {
    /// Bring the index up to date with the library (a delta, or a full scan when the history can't say).
    case sync(SyncReason)
    /// Recompute the structure of the dirty days (moments, trips, labels), without reading the library.
    case restructure
    /// Empty the derived tables and read the whole library again (Settings › Rebuild index).
    case rebuild
}

public enum SyncReason: Sendable, Hashable {
    case launch, foreground, libraryChanged, accessChanged, manual
}

/// The indexer's tunables. Defaults are the search spec's placeholders.
public struct IndexerSettings: Sendable {
    /// Assets per scan batch and per by-id re-read chunk; each batch commits as one transaction.
    public var batchSize: Int
    /// A progressive structure checkpoint every this many scanned assets, or every ``checkpointInterval``.
    public var checkpointAssets: Int
    public var checkpointInterval: Duration
    /// Reading progress is published at most this often.
    public var progressInterval: Duration
    /// A sleep after every scan batch (DEBUG `-LZIndexPace`), so progress can be watched and interrupted.
    public var pacePerBatch: Duration
    /// A delta larger than max(minimum, fraction × indexed assets) is applied as a full scan instead.
    public var reconcileThreshold: (minimum: Int, fraction: Double)
    /// After a change event finds an empty delta, the indexer asks once more after this long (persistent
    /// history can lag the change observer).
    public var changeRetryDelay: Duration

    public init(batchSize: Int = 500, checkpointAssets: Int = 5_000, checkpointInterval: Duration = .seconds(10),
                progressInterval: Duration = .milliseconds(250), pacePerBatch: Duration = .zero,
                reconcileThreshold: (minimum: Int, fraction: Double) = (5_000, 0.2), changeRetryDelay: Duration = .seconds(2)) {
        self.batchSize = batchSize
        self.checkpointAssets = checkpointAssets
        self.checkpointInterval = checkpointInterval
        self.progressInterval = progressInterval
        self.pacePerBatch = pacePerBatch
        self.reconcileThreshold = reconcileThreshold
        self.changeRetryDelay = changeRetryDelay
    }
}

/// What the index is doing, for the Ask cards, Settings and the stores.
public struct IndexStatus: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case off(OffReason)
        /// Taking the change token and counting before a full scan.
        case preparing
        /// A full scan: assets read so far of about `total`.
        case reading(done: Int, total: Int)
        /// The structure pass after a full scan (moments, trips, places).
        case organizing
        case ready
        case paused
        case failed(String)
    }

    public enum OffReason: Sendable, Hashable {
        case noAccess, deletedByUser, protectedDataUnavailable
    }

    public var phase: Phase
    /// The first build hasn't finished: only photos newer than ``coveredSince`` are searchable.
    public var isPartial: Bool
    /// The scan frontier during the first build: everything newer is searchable.
    public var coveredSince: Date?
    public var isLimited: Bool
    public var summary: LibrarySummary?
    public var placeNames: PlaceNameProgress
    /// The index version readers have seen committed (``IndexReader`` results change only when it does).
    public var version: Int64
    public var lastSync: Date?

    public init(phase: Phase, isPartial: Bool = false, coveredSince: Date? = nil, isLimited: Bool = false, summary: LibrarySummary? = nil,
                placeNames: PlaceNameProgress = .init(), version: Int64 = 0, lastSync: Date? = nil) {
        self.phase = phase
        self.isPartial = isPartial
        self.coveredSince = coveredSince
        self.isLimited = isLimited
        self.summary = summary
        self.placeNames = placeNames
        self.version = version
        self.lastSync = lastSync
    }
}

/// The library at a glance (Ask's summary card, Settings).
public struct LibrarySummary: Sendable, Hashable, Codable {
    /// Photos and videos indexed.
    public var assets: Int
    public var photos: Int
    public var videos: Int
    /// With their own GPS position.
    public var located: Int
    public var moments: Int
    public var trips: Int
    public var countries: Int
    /// Local years of the oldest and newest dated asset.
    public var firstYear: Int?
    public var lastYear: Int?
    public var homeCityName: String?

    public init(assets: Int = 0, photos: Int = 0, videos: Int = 0, located: Int = 0, moments: Int = 0, trips: Int = 0, countries: Int = 0,
                firstYear: Int? = nil, lastYear: Int? = nil, homeCityName: String? = nil) {
        self.assets = assets
        self.photos = photos
        self.videos = videos
        self.located = located
        self.moments = moments
        self.trips = trips
        self.countries = countries
        self.firstYear = firstYear
        self.lastYear = lastYear
        self.homeCityName = homeCityName
    }
}

/// How far naming places with Apple Maps has got (the place-name queue).
public struct PlaceNameProgress: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case idle, running, waitingForNetwork, throttled(until: Date), off, backgrounded, done
    }

    public var named: Int
    public var eligible: Int
    public var state: State

    public init(named: Int = 0, eligible: Int = 0, state: State = .idle) {
        self.named = named
        self.eligible = eligible
        self.state = state
    }
}
