#if canImport(Photos)
import Foundation
import LZCore
import Photos
import Synchronization

/// ``LibraryReader`` over PhotoKit, with ``LibraryFetchRules``.
///
/// It needs limited or full access and never prompts: scans and re-reads throw
/// ``LibraryReaderError/noAccess`` without it. Scans run off the main actor in batches inside
/// autorelease pools, read metadata only (no image data, no filenames, no network), and check for
/// cancellation between batches. Changes come from PhotoKit's persistent history, so they survive
/// relaunches; the availability observer is registered only once access is readable.
public final class LiveLibraryReader: LibraryReader {
    private static let idChunk = 500

    private let observer = AvailabilityObserver()
    private let log = Log("index")

    public init() {}

    deinit {
        if observer.isRegistered { PHPhotoLibrary.shared().unregisterAvailabilityObserver(observer) }
    }

    public func access() -> PhotoAccess {
        PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func currentToken() throws -> LibraryToken {
        guard access().canRead else { throw LibraryReaderError.noAccess }
        return try Self.archive(PHPhotoLibrary.shared().currentChangeToken)
    }

    @concurrent public func estimatedCount() async -> Int {
        guard access().canRead else { return 0 }
        let options = LibraryFetchRules.options()
        return PHAsset.fetchAssets(with: .image, options: options).count + PHAsset.fetchAssets(with: .video, options: options).count
    }

    @concurrent public func scanDated(createdAtOrBefore frontier: Date?, batchSize: Int,
                                      _ handle: @Sendable ([LibraryAsset]) async throws -> Void) async throws {
        guard access().canRead else { throw LibraryReaderError.noAccess }
        let assets = PHAsset.fetchAssets(with: LibraryFetchRules.options(sortedNewestFirst: true, createdAtOrBefore: frontier))
        try await walk(assets, batchSize: batchSize, selfies: Self.selfieIDs(), dated: true, handle)
    }

    @concurrent public func scanUndated(batchSize: Int, _ handle: @Sendable ([LibraryAsset]) async throws -> Void) async throws {
        guard access().canRead else { throw LibraryReaderError.noAccess }
        let options = LibraryFetchRules.options()
        // The seeded-simulator probe checks that PhotoKit accepts this predicate (SeedCapabilities).
        options.predicate = NSPredicate(format: "creationDate == nil")
        try await walk(PHAsset.fetchAssets(with: options), batchSize: batchSize, selfies: Self.selfieIDs(), dated: false, handle)
    }

    @concurrent public func delta(since token: LibraryToken) async -> LibraryDelta {
        guard access().canRead else { return .needsFullScan(.historyFailed) }
        guard let since = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token.data) else {
            return .needsFullScan(.undecodableToken)
        }
        do {
            var inserted = Set<String>(), updated = Set<String>(), deleted = Set<String>()
            var last: PHPersistentChangeToken?
            for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: since) {
                let details = try change.changeDetails(for: .asset)
                inserted.formUnion(details.insertedLocalIdentifiers)
                updated.formUnion(details.updatedLocalIdentifiers)
                deleted.formUnion(details.deletedLocalIdentifiers)
                last = change.changeToken
            }
            guard let last else { return .unchanged(token) }
            return .changes(inserted: inserted, updated: updated, deleted: deleted, through: try Self.archive(last))
        } catch let error as PHPhotosError {
            log.notice("Persistent history failed: PHPhotosError \(error.code.rawValue)", privacy: .public)
            switch error.code {
            case .persistentChangeTokenExpired: return .needsFullScan(.tokenExpired)
            case .persistentChangeDetailsUnavailable: return .needsFullScan(.detailsUnavailable)
            default: return .needsFullScan(.historyFailed)
            }
        } catch {
            log.notice("Persistent history failed: \((error as NSError).domain) \((error as NSError).code)", privacy: .public)
            return .needsFullScan(.historyFailed)
        }
    }

    @concurrent public func assets(withIDs ids: [String]) async throws -> [LibraryAsset] {
        guard access().canRead else { throw LibraryReaderError.noAccess }
        var found: [LibraryAsset] = []
        found.reserveCapacity(ids.count)
        for start in stride(from: 0, to: ids.count, by: Self.idChunk) {
            try Task.checkCancellation()
            let chunk = Array(ids[start..<min(ids.count, start + Self.idChunk)])
            autoreleasepool {
                let selfies = Self.selfieIDs(among: chunk)
                PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: LibraryFetchRules.options()).enumerateObjects { asset, _, _ in
                    guard LibraryFetchRules.admits(asset) else { return }
                    found.append(LibraryAsset(asset, isSelfie: selfies.contains(asset.localIdentifier)))
                }
            }
        }
        return found
    }

    public func availability() -> AsyncStream<LibraryAvailability> {
        let stream = observer.subscribe()
        if access().canRead { observer.registerOnce() }
        return stream
    }

    // MARK: PhotoKit

    /// Calls `handle` with the admitted assets of each batch of `assets` that are `dated` (or not), in order.
    private func walk(_ assets: PHFetchResult<PHAsset>, batchSize: Int, selfies: Set<String>, dated: Bool,
                      _ handle: @Sendable ([LibraryAsset]) async throws -> Void) async throws {
        let size = max(1, batchSize)
        let total = assets.count
        var start = 0
        while start < total {
            try Task.checkCancellation()
            let end = min(total, start + size)
            var batch: [LibraryAsset] = []
            batch.reserveCapacity(end - start)
            autoreleasepool {
                assets.enumerateObjects(at: IndexSet(integersIn: start..<end), options: []) { asset, _, _ in
                    guard LibraryFetchRules.admits(asset), (asset.creationDate != nil) == dated else { return }
                    batch.append(LibraryAsset(asset, isSelfie: selfies.contains(asset.localIdentifier)))
                }
            }
            start = end
            if !batch.isEmpty { try await handle(batch) }
        }
    }

    /// The members of the Selfies smart album (only those in `ids`, when given).
    private static func selfieIDs(among ids: [String]? = nil) -> Set<String> {
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
        guard let album = albums.firstObject else { return [] }
        let options = LibraryFetchRules.options()
        if let ids { options.predicate = NSPredicate(format: "localIdentifier IN %@", ids) }
        var members = Set<String>()
        PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in members.insert(asset.localIdentifier) }
        return members
    }

    private static func archive(_ token: PHPersistentChangeToken) throws -> LibraryToken {
        LibraryToken(data: try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true))
    }
}

extension LibraryAsset {
    /// What the index keeps of `asset` (metadata only).
    init(_ asset: PHAsset, isSelfie: Bool) {
        self.init(id: asset.localIdentifier, facts: AssetFacts(asset), isSelfie: isSelfie, hasAdjustments: asset.hasAdjustments,
                  adjustedDate: asset.adjustmentTimestamp)
    }
}

/// Forwards PhotoKit's "library became unavailable" callback to every subscribed stream.
private final class AvailabilityObserver: NSObject, PHPhotoLibraryAvailabilityObserver, Sendable {
    private struct State {
        var registered = false
        var continuations: [UUID: AsyncStream<LibraryAvailability>.Continuation] = [:]
    }

    private let state = Mutex(State())

    var isRegistered: Bool { state.withLock { $0.registered } }

    func registerOnce() {
        let first = state.withLock { state in
            defer { state.registered = true }
            return !state.registered
        }
        if first { PHPhotoLibrary.shared().register(self) }
    }

    func subscribe() -> AsyncStream<LibraryAvailability> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LibraryAvailability>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func photoLibraryDidBecomeUnavailable(_ photoLibrary: PHPhotoLibrary) {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations { continuation.yield(.unavailable) }
    }
}
#endif
