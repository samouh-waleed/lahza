import AVFoundation
import Foundation
import Synchronization
#if os(iOS)
import Photos
#endif

/// What a video request gave back.
public enum LoadedVideo: Sendable {
    /// Ready to play from what the iPhone holds.
    case item(AVPlayerItem)
    /// The video is only in iCloud, and Lahza never downloads it.
    case inCloud
    /// No such video (deleted, hidden, no access, not a video).
    case missing
}

/// Videos to play in the viewer, by local identifier, from what the iPhone holds: network access is always off.
/// ``LiveVideoLoader`` asks PhotoKit; ``FakeVideoLoader`` plays seed clips.
public protocol VideoLoader: Sendable {
    func playerItem(for localID: String) async -> LoadedVideo
}

/// A ``VideoLoader`` for tests and the fake libraries: ids can be scripted as missing or only in iCloud; in DEBUG
/// builds a seed library video plays its seed clip (``SeedVideo``, written once to `folder`); anything else is
/// missing.
public final class FakeVideoLoader: VideoLoader {
    private let missing: Set<String>
    private let inCloud: Set<String>
    private let folder: URL

    public init(missing: Set<String> = [], inCloud: Set<String> = [],
                folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("lahza-seed-videos", isDirectory: true)) {
        self.missing = missing
        self.inCloud = inCloud
        self.folder = folder
    }

    public func playerItem(for localID: String) async -> LoadedVideo {
        if missing.contains(localID) { return .missing }
        if inCloud.contains(localID) { return .inCloud }
        #if DEBUG
        if let item = SeedScenario.hero.item(id: localID), item.isVideo, let url = await clip(item) {
            return .item(AVPlayerItem(url: url))
        }
        #endif
        return .missing
    }

    #if DEBUG
    /// The item's clip, written on first use (to a fresh name, then moved, so two requests never share a file).
    private func clip(_ item: SeedItem) async -> URL? {
        let files = FileManager.default
        let url = folder.appendingPathComponent(item.id.replacingOccurrences(of: "/", with: "-") + ".mov")
        if files.fileExists(atPath: url.path) { return url }
        let draft = folder.appendingPathComponent(UUID().uuidString + ".mov")
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try await SeedVideo.write(item, to: draft)
            if !files.fileExists(atPath: url.path) { try files.moveItem(at: draft, to: url) }
        } catch {
            try? files.removeItem(at: draft)
            return files.fileExists(atPath: url.path) ? url : nil
        }
        try? files.removeItem(at: draft)
        return url
    }
    #endif
}

#if os(iOS)
/// ``VideoLoader`` over PhotoKit, with ``LibraryFetchRules``. Network access is off, so a video only in iCloud comes
/// back ``LoadedVideo/inCloud``.
public final class LiveVideoLoader: VideoLoader {
    public init() {}

    public func playerItem(for localID: String) async -> LoadedVideo {
        guard !Task.isCancelled, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: LibraryFetchRules.options()).firstObject,
              LibraryFetchRules.admits(asset), asset.mediaType == .video else { return .missing }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .automatic
        options.version = .current
        return await withCheckedContinuation { continuation in
            let pending = Pending(continuation)
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
                let loaded: LoadedVideo = if let item {
                    .item(item)
                } else if (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true {
                    .inCloud
                } else {
                    .missing
                }
                pending.resume(loaded)
            }
        }
    }

    /// Resumes the request's continuation at most once (PhotoKit answers once; a second answer is ignored).
    private final class Pending: Sendable {
        private let continuation: Mutex<CheckedContinuation<LoadedVideo, Never>?>

        init(_ continuation: CheckedContinuation<LoadedVideo, Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume(_ video: LoadedVideo) {
            continuation.withLock { $0.take() }?.resume(returning: video)
        }
    }
}
#endif
