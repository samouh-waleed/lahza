import Foundation
import LZCore
import LZGeo
import Observation

/// Saved places as Settings and moment detail see them (search spec §7.4): the places the person named, with their
/// photo counts, and what Lahza uses as home. Every change goes through the index's ``UserDataWriter`` (one
/// transaction each, mirrored into the place index), then reloads; the restructure it asks for relabels moments
/// ("My pitch") and bumps the index version, which reloads the list again. `changed` runs after each write, so search
/// can refresh its parse vocabulary at once.
///
/// Saved place names are the person's own words: never logged.
@MainActor @Observable public final class SavedPlacesStore {
    /// Every saved place but the home picked from the night places (it is the Home row, named "Home"), by name.
    public private(set) var places: [SavedPlaceRow] = []
    public private(set) var home: HomeSetting = .estimated(nil)
    /// Photos and videos inside each saved place, by id.
    public private(set) var photoCounts: [Int64: Int] = [:]
    /// Loaded since the index (re)opened.
    public private(set) var hasLoaded = false

    @ObservationIgnored private let index: IndexStore
    @ObservationIgnored private let changed: @MainActor () -> Void
    @ObservationIgnored private var loadedVersion: Int64 = -1
    @ObservationIgnored private var loadedGeneration = -1
    @ObservationIgnored private var reloads = 0
    /// The latest reload whose rows are shown: a reload applies unless a later-started one already has (its read is
    /// newer), so a write's own reload shows the write when the write returns.
    @ObservationIgnored private var applied = 0
    @ObservationIgnored private let log = Log("places")

    public init(index: IndexStore, changed: @escaping @MainActor () -> Void = {}) {
        self.index = index
        self.changed = changed
    }

    /// Whether saved places can be read and written (the index is on).
    public var isAvailable: Bool { index.reader != nil && index.writer != nil }

    /// Loads the places unless what is loaded is current.
    public func load() async {
        guard let reader = index.reader else { return clear() }
        guard reader.generation != loadedGeneration || index.version != loadedVersion else { return }
        await reload()
    }

    /// The index changed: reloads what is shown (nothing loads before the first ``load()``).
    public func indexChanged() async {
        guard index.reader != nil else { return clear() }
        guard hasLoaded else { return }
        await reload()
    }

    /// Photos and videos within `radius` metres of `center` (the sheet's live count); nil while the index is off.
    public func count(around center: Coordinate, radius: Double) async -> Int? {
        try? await index.reader?.countWithin(center, radius: radius)
    }

    /// The saved place with the same name (folded), other than `id`.
    public func place(named name: String, excluding id: Int64? = nil) -> SavedPlaceRow? {
        let folded = PlaceNames.fold(name)
        guard !folded.isEmpty else { return nil }
        let all = places + (homePlace.map { [$0] } ?? [])
        return all.first { PlaceNames.fold($0.name) == folded && $0.id != id }
    }

    /// The saved place that is the home, if any.
    public var homePlace: SavedPlaceRow? {
        if case .saved(let place) = home { return place }
        return nil
    }

    // MARK: Writes

    @discardableResult
    public func save(name: String, center: Coordinate, radius: Double, isHome: Bool) async throws -> Int64 {
        let writer = try writer()
        let id = try await perform("save") { try await writer.savePlace(name: name, center: center, radius: radius, isHome: isHome) }
        return id
    }

    /// The edit sheet: a new name, radius or home flag, each written only when it changed.
    public func update(_ place: SavedPlaceRow, name: String, radius: Double, isHome: Bool) async throws {
        let writer = try writer()
        try await perform("update") {
            if SavedPlaceRules.cleaned(name) != place.name { try await writer.renamePlace(place.id, to: name) }
            if radius != place.radius { try await writer.setRadius(place.id, radius) }
            if isHome != place.isHome { try await writer.setHome(isHome ? .place(place.id) : .estimated) }
        }
    }

    public func delete(_ id: Int64) async throws {
        let writer = try writer()
        try await perform("delete") { try await writer.deletePlace(id) }
    }

    public func setHome(_ choice: HomeChoice) async throws {
        let writer = try writer()
        try await perform("home") { try await writer.setHome(choice) }
    }

    /// The night places offered as home, most nights first.
    public func homeCandidates(limit: Int = 5) async -> [HomeCandidate] {
        (try? await index.reader?.homeCandidates(limit: limit)) ?? []
    }

    // MARK: Private

    private func writer() throws -> UserDataWriter {
        guard let writer = index.writer else { throw IndexError.closed }
        return writer
    }

    private func perform<T>(_ action: String, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            changed()
            await reload()
            return value
        } catch let error as SavedPlaceError {
            throw error
        } catch {
            log.error("Saved place \(action) failed: \(IndexDatabase.code(of: error))", privacy: .public)
            throw error
        }
    }

    private func reload() async {
        guard let reader = index.reader else { return clear() }
        let version = index.version
        reloads += 1
        let ticket = reloads
        do {
            async let saved = reader.savedPlaces()
            async let setting = reader.homeSetting()
            let (rows, home) = try await (saved, setting)
            var counts: [Int64: Int] = [:]
            for place in rows { counts[place.id] = try await reader.countWithin(place.center, radius: place.radius) }
            guard ticket > applied else { return }
            applied = ticket
            places = rows.filter { !($0.isHome && SavedPlaceRules.isHomeName($0.name)) }
            self.home = home
            photoCounts = counts
            loadedVersion = version
            loadedGeneration = reader.generation
            hasLoaded = true
        } catch {
            guard ticket > applied, !(error is CancellationError) else { return }
            applied = ticket
            clear()
        }
    }

    private func clear() {
        places = []
        home = .estimated(nil)
        photoCounts = [:]
        hasLoaded = false
        loadedVersion = -1
        loadedGeneration = -1
    }
}
