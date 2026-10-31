import CoreGraphics
import Foundation
import Synchronization
#if os(iOS)
import Photos
import UIKit
#endif

/// What an image request gave back.
public enum AssetImage: Sendable {
    case image(CGImage)
    /// A smaller version the iPhone holds: the full-quality original is only in iCloud (screen-size images only).
    case reduced(CGImage)
    /// The data is only in iCloud, and Lahza never downloads it.
    case inCloud
    /// No such asset (deleted, hidden, no access) or no image.
    case missing
}

/// Thumbnails and screen-size images of library assets, by local identifier, from what the iPhone
/// holds: network access is always off. ``LiveAssetImageProvider`` asks PhotoKit;
/// ``FakeAssetImageProvider`` draws placeholders.
public protocol AssetImageProvider: Sendable {
    /// A thumbnail whose short side is about `side` pixels (aspect fill).
    func thumbnail(for localID: String, side: Int) async -> AssetImage
    /// An image whose long side is at most `maxPixel` pixels (aspect fit). When the original is only in iCloud, the
    /// best version the iPhone holds, ``AssetImage/reduced(_:)``.
    func displayImage(for localID: String, maxPixel: Int) async -> AssetImage
    /// Starts preparing thumbnails of `ids` at `side` (a grid about to scroll into view).
    func startCaching(_ ids: [String], side: Int)
    func stopCaching(_ ids: [String], side: Int)
    func stopAll()
    /// The image the Vision pass looks at: the whole picture with its short side about `side` pixels. When the iPhone
    /// holds only a smaller version, that one if its short side is at least `minimumSide` (``AssetImage/reduced(_:)``),
    /// else ``AssetImage/inCloud``.
    func analysisImage(for localID: String, side: Int, minimumSide: Int) async -> AssetImage
}

extension AssetImageProvider {
    /// The thumbnail, which is never cropped (aspect fill sizes it; it doesn't cut it).
    public func analysisImage(for localID: String, side: Int, minimumSide: Int) async -> AssetImage {
        await thumbnail(for: localID, side: side)
    }
}

/// An ``AssetImageProvider`` that draws a gradient with the asset's date (when known), or the seed
/// artwork for seed library ids in DEBUG builds. Ids can be scripted as missing, only in iCloud, or
/// with only a smaller version on the iPhone (`reduced`: a quarter-size screen image); caching calls
/// are recorded.
public final class FakeAssetImageProvider: AssetImageProvider {
    private let dates: [String: Date]
    private let missing: Set<String>
    private let inCloud: Set<String>
    private let reduced: Set<String>
    private let cached = Mutex<Set<String>>([])

    public init(dates: [String: Date] = [:], missing: Set<String> = [], inCloud: Set<String> = [], reduced: Set<String> = []) {
        self.dates = dates
        self.missing = missing
        self.inCloud = inCloud
        self.reduced = reduced
    }

    /// Ids being cached now.
    public var cachedIDs: Set<String> { cached.withLock { $0 } }

    public func thumbnail(for localID: String, side: Int) async -> AssetImage {
        render(localID) { width, height in
            let scale = Double(side) / Double(max(1, min(width, height)))
            return (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
        }
    }

    public func displayImage(for localID: String, maxPixel: Int) async -> AssetImage {
        let side = reduced.contains(localID) ? max(1, maxPixel / 4) : maxPixel
        let image = render(localID) { width, height in
            let scale = min(1, Double(side) / Double(max(1, max(width, height))))
            return (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
        }
        if reduced.contains(localID), case .image(let cgImage) = image { return .reduced(cgImage) }
        return image
    }

    public func startCaching(_ ids: [String], side: Int) {
        cached.withLock { $0.formUnion(ids) }
    }

    public func stopCaching(_ ids: [String], side: Int) {
        cached.withLock { $0.subtract(ids) }
    }

    public func stopAll() {
        cached.withLock { $0.removeAll() }
    }

    /// Draws `localID` at the size `fit` picks from its full size.
    private func render(_ localID: String, fit: (Int, Int) -> (Int, Int)) -> AssetImage {
        if missing.contains(localID) { return .missing }
        if inCloud.contains(localID) { return .inCloud }
        #if DEBUG
        if let item = SeedScenario.hero.item(id: localID) {
            let (width, height) = fit(item.pixelWidth, item.pixelHeight)
            return SeedArtwork.image(for: item, width: width, height: height).map(AssetImage.image) ?? .missing
        }
        #endif
        let title = dates[localID].map { $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "Photo"
        let artwork = PlaceholderArtwork(title: title, lines: [], hue: PlaceholderArtwork.hue(for: localID))
        let (width, height) = fit(4032, 3024)
        return artwork.image(width: width, height: height).map(AssetImage.image) ?? .missing
    }
}

#if os(iOS)
/// ``AssetImageProvider`` over PhotoKit's caching image manager, with ``LibraryFetchRules``.
/// Network access is off, so an image only in iCloud comes back ``AssetImage/inCloud``.
public final class LiveAssetImageProvider: AssetImageProvider {
    private let manager = Mutex(PHCachingImageManager())

    public init() {}

    public func thumbnail(for localID: String, side: Int) async -> AssetImage {
        await request(localID, size: CGSize(width: side, height: side), mode: .aspectFill)
    }

    /// The original at screen size; when it is only in iCloud, the best version the iPhone holds (fast delivery
    /// answers once, with whatever is local).
    public func displayImage(for localID: String, maxPixel: Int) async -> AssetImage {
        let size = CGSize(width: maxPixel, height: maxPixel)
        let full = await request(localID, size: size, mode: .aspectFit)
        guard case .inCloud = full, !Task.isCancelled else { return full }
        if case .image(let cgImage) = await request(localID, size: size, mode: .aspectFit, delivery: .fastFormat) { return .reduced(cgImage) }
        return full
    }

    /// High quality first; when that is only in iCloud, the fast local version if it is large enough.
    public func analysisImage(for localID: String, side: Int, minimumSide: Int) async -> AssetImage {
        let size = CGSize(width: side, height: side)
        let full = await request(localID, size: size, mode: .aspectFill)
        guard case .inCloud = full, !Task.isCancelled else { return full }
        if case .image(let cgImage) = await request(localID, size: size, mode: .aspectFill, delivery: .fastFormat),
           min(cgImage.width, cgImage.height) >= minimumSide {
            return .reduced(cgImage)
        }
        return .inCloud
    }

    public func startCaching(_ ids: [String], side: Int) {
        let assets = Self.assets(ids)
        guard !assets.isEmpty else { return }
        manager.withLock {
            $0.startCachingImages(for: assets, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: Self.options())
        }
    }

    public func stopCaching(_ ids: [String], side: Int) {
        let assets = Self.assets(ids)
        guard !assets.isEmpty else { return }
        manager.withLock {
            $0.stopCachingImages(for: assets, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: Self.options())
        }
    }

    public func stopAll() {
        manager.withLock { $0.stopCachingImagesForAllAssets() }
    }

    /// One image request; cancelling the task cancels it in PhotoKit too (a row scrolled away) and returns
    /// ``AssetImage/missing``.
    private func request(_ localID: String, size: CGSize, mode: PHImageContentMode, delivery: PHImageRequestOptionsDeliveryMode = .highQualityFormat) async -> AssetImage {
        guard !Task.isCancelled, let asset = Self.assets([localID]).first else { return .missing }
        let pending = PendingRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let once = ResumeOnce(continuation)
                let id = manager.withLock {
                    // High-quality delivery answers once, with the best local image or none.
                    $0.requestImage(for: asset, targetSize: size, contentMode: mode, options: Self.options(delivery)) { image, info in
                        if let cgImage = image?.cgImage {
                            once.resume(.image(cgImage))
                        } else {
                            once.resume((info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true ? .inCloud : .missing)
                        }
                    }
                }
                if pending.started(id, once) { cancel(id, once) }
            }
        } onCancel: {
            if let (id, once) = pending.cancelled() { cancel(id, once) }
        }
    }

    private func cancel(_ id: PHImageRequestID, _ once: ResumeOnce) {
        manager.withLock { $0.cancelImageRequest(id) }
        once.resume(.missing)
    }

    /// A request's id once PhotoKit has it, and whether its task was cancelled, whichever comes first.
    private final class PendingRequest: Sendable {
        private let state = Mutex<(request: (id: PHImageRequestID, once: ResumeOnce)?, cancelled: Bool)>((nil, false))

        /// Records the request; true when the task was already cancelled.
        func started(_ id: PHImageRequestID, _ once: ResumeOnce) -> Bool {
            state.withLock { state in
                state.request = (id, once)
                return state.cancelled
            }
        }

        /// Records the cancel; the request to cancel, once it has started.
        func cancelled() -> (PHImageRequestID, ResumeOnce)? {
            state.withLock { state in
                state.cancelled = true
                return state.request
            }
        }
    }

    /// The readable assets among `ids`, in no particular order.
    private static func assets(_ ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: LibraryFetchRules.options()).enumerateObjects { asset, _, _ in
            if LibraryFetchRules.admits(asset) { assets.append(asset) }
        }
        return assets
    }

    private static func options(_ delivery: PHImageRequestOptionsDeliveryMode = .highQualityFormat) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = delivery
        options.resizeMode = .fast
        options.version = .current
        return options
    }

    /// Resumes a continuation at most once, whatever PhotoKit does.
    private final class ResumeOnce: Sendable {
        private let continuation: Mutex<CheckedContinuation<AssetImage, Never>?>

        init(_ continuation: CheckedContinuation<AssetImage, Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume(_ image: AssetImage) {
            continuation.withLock { $0.take() }?.resume(returning: image)
        }
    }
}
#endif
