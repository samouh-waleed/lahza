import Foundation
import LZCore
import LZGeo
import LZLibrary

/// What the index needs from the app.
public struct IndexDependencies: Sendable {
    public var location: IndexLocation
    public var reader: any LibraryReader
    /// Nil when the bundled gazetteer failed to load (a build error): the index stays off.
    public var gazetteer: Gazetteer?
    public var maps: any MapsClient
    /// Shared with search (interactive requests).
    public var budget: MapsBudget
    public var clock: any AppClock
    public var network: any NetworkStatus
    public var kv: any KeyValueStore
    public var deviceTimeZone: @Sendable () -> TimeZone
    /// Library change events (``PhotoLibraryClient/changes()``); each burst becomes one sync after a debounce.
    public var changes: @Sendable () -> AsyncStream<PhotoLibraryChange>
    public var settings: IndexerSettings
    public var placeNamePolicy: PlaceNamePolicy
    /// Destroy an on-disk index before opening it (DEBUG `-LZIndex reset`).
    public var resetOnLaunch: Bool
    /// The index file can be opened (iOS: `UIApplication.isProtectedDataAvailable`).
    public var isProtectedDataAvailable: @MainActor @Sendable () -> Bool
    public var changeDebounce: Duration

    public init(location: IndexLocation, reader: any LibraryReader, gazetteer: Gazetteer?, maps: any MapsClient, budget: MapsBudget, clock: any AppClock,
                network: any NetworkStatus, kv: any KeyValueStore, deviceTimeZone: @escaping @Sendable () -> TimeZone = { .current },
                changes: @escaping @Sendable () -> AsyncStream<PhotoLibraryChange>, settings: IndexerSettings = .init(),
                placeNamePolicy: PlaceNamePolicy = .default, resetOnLaunch: Bool = false,
                isProtectedDataAvailable: @escaping @MainActor @Sendable () -> Bool = { true }, changeDebounce: Duration = .seconds(2)) {
        self.location = location
        self.reader = reader
        self.gazetteer = gazetteer
        self.maps = maps
        self.budget = budget
        self.clock = clock
        self.network = network
        self.kv = kv
        self.deviceTimeZone = deviceTimeZone
        self.changes = changes
        self.settings = settings
        self.placeNamePolicy = placeNamePolicy
        self.resetOnLaunch = resetOnLaunch
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.changeDebounce = changeDebounce
    }
}

/// One open index and the actors over it. ``IndexStore`` replaces the session whenever the index is purged
/// (revocation, Delete index) and opened again; `generation` tells readers of different sessions apart.
public final class IndexSession: Sendable {
    public let database: IndexDatabase
    public let indexer: LibraryIndexer
    public let placeNames: PlaceNameQueue
    public let reader: IndexReader
    public let generation: Int

    init(database: IndexDatabase, gazetteer: Gazetteer, dependencies: IndexDependencies, generation: Int) {
        self.database = database
        self.generation = generation
        let indexer = LibraryIndexer(database: database, reader: dependencies.reader, gazetteer: gazetteer, clock: dependencies.clock,
                                     deviceTimeZone: dependencies.deviceTimeZone, settings: dependencies.settings)
        self.indexer = indexer
        placeNames = PlaceNameQueue(database: database, maps: dependencies.maps, budget: dependencies.budget, clock: dependencies.clock,
                                    network: dependencies.network, notify: { await indexer.enqueue(.restructure) },
                                    policy: dependencies.placeNamePolicy)
        reader = IndexReader(database: database, generation: generation)
    }
}
