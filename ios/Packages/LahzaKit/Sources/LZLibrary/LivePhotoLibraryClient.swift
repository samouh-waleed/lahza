#if canImport(Photos)
import Foundation
import Photos
import Synchronization

/// ``PhotoLibraryClient`` over PhotoKit.
///
/// Nothing here touches the library before access is readable: reading the status never prompts,
/// counting checks the status first, and the change observer is registered with PhotoKit only once
/// access is limited or full (registering earlier can show the iOS prompt). The limited-library
/// picker is UIKit, so the app presents it.
public final class LivePhotoLibraryClient: PhotoLibraryClient {
    private let observer = LibraryChangeObserver()

    public init() {}

    deinit {
        if observer.isRegistered { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
    }

    public func currentAccess() -> PhotoAccess {
        let access = Self.status()
        observer.registerIfReadable(access)
        return access
    }

    public func requestAccess() async -> PhotoAccess {
        let access = PhotoAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        observer.registerIfReadable(access)
        return access
    }

    @concurrent public func readableCount() async -> Int {
        let access = Self.status()
        guard access.canRead else { return 0 }
        observer.registerIfReadable(access)
        // Hidden stays out (decision 14). The iCloud Shared Library is part of the user library, so
        // it is counted; Shared Albums are not the library and stay out.
        let options = LibraryFetchRules.options()
        return PHAsset.fetchAssets(with: .image, options: options).count
            + PHAsset.fetchAssets(with: .video, options: options).count
    }

    public func changes() -> AsyncStream<PhotoLibraryChange> {
        let stream = observer.subscribe()
        observer.registerIfReadable(Self.status())
        return stream
    }

    /// The read-write status (the level that has a limited selection). Never prompts.
    private static func status() -> PhotoAccess {
        PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }
}

/// Forwards PhotoKit's change callbacks (on an arbitrary serial queue) to every subscribed stream.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private struct State {
        var registered = false
        var continuations: [UUID: AsyncStream<PhotoLibraryChange>.Continuation] = [:]
    }

    private let state = Mutex(State())

    var isRegistered: Bool { state.withLock { $0.registered } }

    /// Registers with PhotoKit, once, when `access` is readable.
    func registerIfReadable(_ access: PhotoAccess) {
        guard access.canRead else { return }
        let first = state.withLock { state in
            defer { state.registered = true }
            return !state.registered
        }
        // Outside the lock: PhotoKit may call back on another queue straight away.
        if first { PHPhotoLibrary.shared().register(self) }
    }

    func subscribe() -> AsyncStream<PhotoLibraryChange> {
        let id = UUID()
        // A burst of changes while the subscriber is busy collapses into one pending event.
        let (stream, continuation) = AsyncStream<PhotoLibraryChange>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations { continuation.yield(PhotoLibraryChange()) }
    }
}
#endif
