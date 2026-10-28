import Foundation
import Synchronization

/// A scripted ``LibraryReader`` for tests, previews and DEBUG launches. It never touches PhotoKit.
///
/// It starts from a fixed library (empty, the DEBUG seed scenario, the census's synthetic library or
/// explicit assets) and records scripted inserts, updates, deletes and hides in a change history,
/// as PhotoKit's persistent history would. A scan reads a snapshot taken when it starts, like a
/// PhotoKit fetch result, so changes made meanwhile show up only in the next delta. Tokens can be
/// expired and change details made unavailable, to drive the full-scan paths.
///
/// Access is scripted with ``setAccess(_:)``; under limited access only the assets in
/// ``setLimitedSelection(_:)`` are visible. A synthetic library, or any library made `following` a
/// ``FakePhotoLibraryClient``, follows that client instead: its access, and under limited access its
/// first `count(for: .limited)` assets by id (so the app's access store and the index agree).
public final class FakeLibraryReader: LibraryReader {
    public enum Contents: Sendable {
        case empty
        #if DEBUG
        /// A DEBUG seed scenario (``SeedScenario``): every item, the undated ones included.
        case seed(SeedScenario.Name)
        #endif
        /// The census's synthetic library at the client's full count (12,480 by default).
        case synthetic(FakePhotoLibraryClient)
        case explicit([LibraryAsset])
    }

    private struct Change {
        var sequence: Int
        var inserted: Set<String> = []
        var updated: Set<String> = []
        var deleted: Set<String> = []
    }

    private struct State {
        var access: PhotoAccess
        var assets: [String: LibraryAsset]
        var hidden: Set<String> = []
        var selection: Set<String> = []
        var history: [Change] = []
        var sequence = 0
        /// Tokens older than this sequence are expired.
        var oldestValid = 0
        var detailsUnavailable = false
        var continuations: [UUID: AsyncStream<LibraryAvailability>.Continuation] = [:]
    }

    private static let tokenPrefix = "fake-library-token:"

    private let state: Mutex<State>
    private let library: FakePhotoLibraryClient?

    /// A library holding `contents`, readable at `access` (ignored for a synthetic library, which
    /// follows its client, and when `client` is given, which it then follows the same way).
    public init(_ contents: Contents, access: PhotoAccess = .full, following client: FakePhotoLibraryClient? = nil) {
        var assets: [LibraryAsset] = []
        var library: FakePhotoLibraryClient?
        switch contents {
        case .empty:
            break
        #if DEBUG
        case .seed(let name):
            assets = SeedScenario.named(name).libraryAssets
        #endif
        case .synthetic(let client):
            library = client
            let synthetic = SyntheticLibrary(count: client.count(for: .full), seed: 2026)
            let width = String(synthetic.facts.count).count
            assets = synthetic.facts.enumerated().map { index, facts in
                LibraryAsset(id: "synthetic/" + String(repeating: "0", count: max(0, width - String(index).count)) + String(index), facts: facts)
            }
        case .explicit(let explicit):
            assets = explicit
        }
        self.library = library ?? client
        state = Mutex(State(access: access, assets: Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { $1 })))
    }

    // MARK: Scripting

    /// Every asset in the library, hidden ones included, ignoring access.
    public var allAssets: [LibraryAsset] { state.withLock { $0.assets.values.sorted { $0.id < $1.id } } }

    /// Changes access, as iPhone Settings would (for a synthetic library, its client's access).
    public func setAccess(_ access: PhotoAccess) {
        if let library { library.setAccess(access) } else { state.withLock { $0.access = access } }
    }

    /// The assets visible under limited access.
    public func setLimitedSelection(_ ids: Set<String>) {
        state.withLock { $0.selection = ids }
    }

    /// Adds assets (a capture, an import, an iCloud download).
    public func insert(_ assets: [LibraryAsset]) {
        record { state, change in
            for asset in assets {
                state.assets[asset.id] = asset
                change.inserted.insert(asset.id)
            }
        }
    }

    /// Replaces assets' facts (an edited date or position, a favourite).
    public func update(_ assets: [LibraryAsset]) {
        record { state, change in
            for asset in assets where state.assets[asset.id] != nil {
                state.assets[asset.id] = asset
                change.updated.insert(asset.id)
            }
        }
    }

    public func delete(_ ids: [String]) {
        record { state, change in
            for id in ids where state.assets.removeValue(forKey: id) != nil {
                state.hidden.remove(id)
                change.deleted.insert(id)
            }
        }
    }

    /// Moves assets to the Hidden album. PhotoKit reports that as an update; a re-read misses them.
    public func hide(_ ids: [String]) {
        record { state, change in
            for id in ids where state.assets[id] != nil {
                state.hidden.insert(id)
                change.updated.insert(id)
            }
        }
    }

    public func unhide(_ ids: [String]) {
        record { state, change in
            for id in ids where state.hidden.remove(id) != nil { change.updated.insert(id) }
        }
    }

    /// Expires every token handed out so far (PhotoKit error 3105).
    public func expireTokens() {
        state.withLock { state in
            // Tokens handed out from now on are newer than every expired one.
            state.sequence += 1
            state.oldestValid = state.sequence
        }
    }

    /// Makes deltas report that change details are unavailable (PhotoKit error 3210), or not.
    public func setDetailsUnavailable(_ unavailable: Bool) {
        state.withLock { $0.detailsUnavailable = unavailable }
    }

    /// Tells every ``availability()`` stream the library became unavailable.
    public func makeUnavailable() {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations { continuation.yield(.unavailable) }
    }

    // MARK: LibraryReader

    public func access() -> PhotoAccess {
        library?.access ?? state.withLock { $0.access }
    }

    public func currentToken() throws -> LibraryToken {
        guard access().canRead else { throw LibraryReaderError.noAccess }
        return Self.token(state.withLock { $0.sequence })
    }

    public func estimatedCount() async -> Int {
        visible().count
    }

    public func scanDated(createdAtOrBefore frontier: Date?, batchSize: Int,
                          _ handle: @Sendable ([LibraryAsset]) async throws -> Void) async throws {
        guard access().canRead else { throw LibraryReaderError.noAccess }
        var dated = visible().compactMap { asset in asset.facts.creationDate.map { (date: $0, asset: asset) } }
        if let frontier { dated.removeAll { $0.date > frontier } }
        dated.sort { $0.date != $1.date ? $0.date > $1.date : $0.asset.id < $1.asset.id }
        try await deliver(dated.map(\.asset), batchSize: batchSize, handle)
    }

    public func scanUndated(batchSize: Int, _ handle: @Sendable ([LibraryAsset]) async throws -> Void) async throws {
        guard access().canRead else { throw LibraryReaderError.noAccess }
        try await deliver(visible().filter { $0.facts.creationDate == nil }.sorted { $0.id < $1.id }, batchSize: batchSize, handle)
    }

    public func delta(since token: LibraryToken) async -> LibraryDelta {
        guard access().canRead else { return .needsFullScan(.historyFailed) }
        guard let since = Self.sequence(of: token) else { return .needsFullScan(.undecodableToken) }
        return state.withLock { state in
            if since < state.oldestValid { return .needsFullScan(.tokenExpired) }
            let changes = state.history.filter { $0.sequence > since }
            guard !changes.isEmpty else { return .unchanged(token) }
            if state.detailsUnavailable { return .needsFullScan(.detailsUnavailable) }
            return .changes(inserted: changes.reduce(into: []) { $0.formUnion($1.inserted) },
                            updated: changes.reduce(into: []) { $0.formUnion($1.updated) },
                            deleted: changes.reduce(into: []) { $0.formUnion($1.deleted) },
                            through: Self.token(state.sequence))
        }
    }

    public func assets(withIDs ids: [String]) async throws -> [LibraryAsset] {
        guard access().canRead else { throw LibraryReaderError.noAccess }
        let visible = Dictionary(visible().map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        return ids.compactMap { visible[$0] }
    }

    public func availability() -> AsyncStream<LibraryAvailability> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LibraryAvailability>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Internals

    /// What a fetch sees now: not hidden, and under limited access only the selection.
    private func visible() -> [LibraryAsset] {
        let access = access()
        guard access.canRead else { return [] }
        let limitedCount = library?.count(for: .limited)
        return state.withLock { state in
            let shown = state.assets.values.filter { !state.hidden.contains($0.id) }
            guard access == .limited else { return shown }
            if let limitedCount { return Array(shown.sorted { $0.id < $1.id }.prefix(limitedCount)) }
            return shown.filter { state.selection.contains($0.id) }
        }
    }

    private func record(_ change: (inout State, inout Change) -> Void) {
        state.withLock { state in
            var next = Change(sequence: state.sequence + 1)
            change(&state, &next)
            guard !(next.inserted.isEmpty && next.updated.isEmpty && next.deleted.isEmpty) else { return }
            state.sequence = next.sequence
            state.history.append(next)
        }
    }

    private func deliver(_ assets: [LibraryAsset], batchSize: Int, _ handle: @Sendable ([LibraryAsset]) async throws -> Void) async throws {
        let size = max(1, batchSize)
        for start in stride(from: 0, to: assets.count, by: size) {
            try Task.checkCancellation()
            try await handle(Array(assets[start..<min(assets.count, start + size)]))
        }
    }

    private static func token(_ sequence: Int) -> LibraryToken {
        LibraryToken(data: Data((tokenPrefix + String(sequence)).utf8))
    }

    private static func sequence(of token: LibraryToken) -> Int? {
        guard let text = String(data: token.data, encoding: .utf8), text.hasPrefix(tokenPrefix) else { return nil }
        return Int(text.dropFirst(tokenPrefix.count))
    }
}
