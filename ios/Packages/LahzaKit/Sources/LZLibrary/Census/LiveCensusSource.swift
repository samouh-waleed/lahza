#if os(iOS)
import Foundation
import Photos
import Synchronization
import UIKit
import UniformTypeIdentifiers

/// ``CensusSource`` over PhotoKit, with the access client's fetch rules: the Hidden album stays out,
/// the user library (which holds the iCloud Shared Library) is in, and Shared Albums are not the
/// library. It needs limited or full access and never prompts; with limited access it counts only
/// what the person shared. Every stage runs off the main actor, in batches inside autorelease pools
/// so memory stays flat on a large library, and checks for cancellation between batches.
///
/// Nothing touches the network: thumbnails are requested with network access off. Per-asset data
/// stays in memory for the run: filenames are classified and dropped, positions only counted.
public final class LiveCensusSource: CensusSource {
    public let name = CensusSourceName.photoKit

    private static let metadataBatch = 500
    private static let filenameBatch = 200

    public init() {}

    @concurrent public func scanMetadata(progress: CensusProgressHandler) async throws -> CensusScan {
        let access = PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard access.canRead else { throw CensusError.noAccess }
        // One fetch for every kind, so the later stages revisit the same assets in the same order.
        let assets = PHAsset.fetchAssets(with: Self.fetchOptions())
        // Counted from the same moment as `assets`, before the long walk, so photos that arrive
        // meanwhile (a capture, an iCloud sync) don't pass for frames inside stacks.
        let extraBurstFrames = Self.extraBurstFrames(shownPhotos: assets.countOfAssets(with: .image))
        let total = assets.count
        var facts: [AssetFacts] = []
        facts.reserveCapacity(total)
        progress(CensusProgress(done: 0, total: total))
        var start = 0
        while start < total {
            try Task.checkCancellation()
            let end = min(total, start + Self.metadataBatch)
            autoreleasepool {
                assets.enumerateObjects(at: IndexSet(integersIn: start..<end), options: []) { asset, _, _ in
                    facts.append(AssetFacts(asset))
                }
            }
            start = end
            progress(CensusProgress(done: end, total: total))
        }
        return CensusScan(facts: facts, access: access, extraBurstFrames: extraBurstFrames, handle: assets)
    }

    @concurrent public func scanFilenames(of scan: CensusScan, progress: CensusProgressHandler) async throws -> [FilenameHint] {
        guard let assets = scan.handle as? PHFetchResult<PHAsset>, assets.count == scan.facts.count else { throw CensusError.mismatchedScan }
        let total = assets.count
        var hints: [FilenameHint] = []
        hints.reserveCapacity(total)
        progress(CensusProgress(done: 0, total: total))
        var start = 0
        while start < total {
            try Task.checkCancellation()
            let end = min(total, start + Self.filenameBatch)
            autoreleasepool {
                assets.enumerateObjects(at: IndexSet(integersIn: start..<end), options: []) { asset, _, _ in
                    // The name is classified here and goes no further.
                    hints.append(FilenameHint(filename: Self.originalFilename(of: asset)))
                }
            }
            start = end
            progress(CensusProgress(done: end, total: total))
        }
        return hints
    }

    @concurrent public func probeThumbnails(of scan: CensusScan, sampleSize: Int, progress: CensusProgressHandler) async throws -> ThumbnailProbe {
        guard let assets = scan.handle as? PHFetchResult<PHAsset>, assets.count == scan.facts.count else { throw CensusError.mismatchedScan }
        let photos = scan.facts.indices.filter { scan.facts[$0].kind == .photo }
        let sample = photos.shuffled().prefix(max(0, sampleSize))
        var tally = ThumbnailTally(requested: sampleSize)
        let clock = ContinuousClock()
        let started = clock.now
        progress(CensusProgress(done: 0, total: sample.count))
        for (done, index) in sample.enumerated() {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            let begun = clock.now
            let answer = await Self.requestThumbnail(of: asset)
            let outcome = ThumbnailOutcome(width: answer.width, height: answer.height, isInCloud: answer.isInCloud)
            tally.add(outcome, degraded: answer.isDegraded, duration: clock.now - begun)
            progress(CensusProgress(done: done + 1, total: sample.count))
        }
        return tally.result(total: clock.now - started)
    }

    // MARK: PhotoKit

    /// The access client's rules: no Hidden album, the user library only (it holds the iCloud
    /// Shared Library), burst frames shown as the library shows them.
    private static func fetchOptions(allBurstFrames: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeAllBurstAssets = allBurstFrames
        return options
    }

    /// Frames inside burst stacks that the library keeps out of view: a count, nothing read.
    private static func extraBurstFrames(shownPhotos: Int) -> Int {
        max(0, PHAsset.fetchAssets(with: .image, options: fetchOptions(allBurstFrames: true)).count - shownPhotos)
    }

    /// The original file's name (the photo or video resource, not an edit or a paired video).
    private static func originalFilename(of asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        let originals: [PHAssetResourceType] = [.photo, .video, .audio]
        guard let resource = resources.first(where: { originals.contains($0.type) }) ?? resources.first else { return nil }
        if #available(iOS 27, *) { return resource.filename }
        return resource.originalFilename
    }

    /// PhotoKit's answer to one local thumbnail request.
    private struct ThumbnailAnswer: Sendable {
        var width: Int?
        var height: Int?
        var isInCloud = false
        var isDegraded = false
    }

    /// Asks for a ~256 px thumbnail with network access off, so iCloud is never touched. High-quality
    /// delivery answers exactly once, with the best image the iPhone holds or none.
    private static func requestThumbnail(of asset: PHAsset) async -> ThumbnailAnswer {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.version = .current
            let side = CGFloat(ThumbnailProbe.requestSide)
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill,
                                                  options: options) { image, info in
                var answer = ThumbnailAnswer()
                if let image {
                    answer.width = image.cgImage?.width ?? Int(image.size.width * image.scale)
                    answer.height = image.cgImage?.height ?? Int(image.size.height * image.scale)
                }
                answer.isInCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                answer.isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                once.resume(returning: answer)
            }
        }
    }

    /// Resumes a continuation at most once, whatever PhotoKit does.
    private final class ResumeOnce: Sendable {
        private let continuation: Mutex<CheckedContinuation<ThumbnailAnswer, Never>?>

        init(_ continuation: CheckedContinuation<ThumbnailAnswer, Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume(returning answer: ThumbnailAnswer) {
            continuation.withLock { $0.take() }?.resume(returning: answer)
        }
    }
}

extension AssetFacts {
    /// The facts PhotoKit holds for `asset` (metadata only; no image data is read).
    init(_ asset: PHAsset) {
        let kind: Kind = switch asset.mediaType {
        case .image: .photo
        case .video: .video
        default: .other
        }
        let types = asset.mediaSubtypes
        var subtypes: Subtypes = []
        if types.contains(.photoScreenshot) { subtypes.insert(.screenshot) }
        if types.contains(.photoLive) { subtypes.insert(.livePhoto) }
        if types.contains(.photoPanorama) { subtypes.insert(.panorama) }
        if types.contains(.photoHDR) { subtypes.insert(.hdr) }
        if types.contains(.photoDepthEffect) { subtypes.insert(.depthEffect) }
        if types.contains(.videoScreenRecording) { subtypes.insert(.screenRecording) }
        if types.contains(.videoHighFrameRate) { subtypes.insert(.sloMo) }
        if types.contains(.videoTimelapse) { subtypes.insert(.timeLapse) }
        let source: Source = switch asset.sourceType {
        case .typeUserLibrary: .userLibrary
        case .typeCloudShared: .cloudShared
        case .typeiTunesSynced: .synced
        default: .unknown
        }
        let location = asset.location
        self.init(
            kind: kind,
            subtypes: subtypes,
            format: kind == .photo ? ImageFormat(asset.contentType) : nil,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            addedDate: asset.addedDate,
            coordinate: location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
            horizontalAccuracy: location?.horizontalAccuracy,
            isFavorite: asset.isFavorite,
            hasBurstIdentifier: asset.burstIdentifier != nil,
            representsBurst: asset.representsBurst,
            duration: asset.duration,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            source: source
        )
    }
}

extension AssetFacts.ImageFormat {
    init(_ type: UTType) {
        if type.conforms(to: .heif) || type.conforms(to: .heic) {
            self = .heif
        } else if type.conforms(to: .jpeg) {
            self = .jpeg
        } else if type.conforms(to: .png) {
            self = .png
        } else if type.conforms(to: .gif) {
            self = .gif
        } else if type.conforms(to: .rawImage) {
            self = .raw
        } else {
            self = .other
        }
    }
}
#endif
