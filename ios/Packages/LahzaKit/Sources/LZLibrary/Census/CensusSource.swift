import Foundation

/// Where the library census reads from: PhotoKit (``LiveCensusSource``) or a synthetic library
/// (``FakeCensusSource``). Three stages, each with progress and cooperative cancellation (a
/// cancelled task throws `CancellationError`); ``CensusRunner`` drives them and
/// ``LibraryCensus`` turns the result into aggregate numbers.
///
/// Sources read with the access client's rules: the Hidden album stays out, the iCloud Shared
/// Library is in (decision 14), and nothing ever goes to the network. Nothing here prompts for
/// access: without readable access every stage throws ``CensusError/noAccess``.
public protocol CensusSource: Sendable {
    /// A short name for the report ("PhotoKit", "Sample library").
    var name: String { get }

    /// Stage 1, the metadata pass: the facts of every readable photo and video, in a fixed order.
    /// With limited access it counts only what the person shared. Runs off the main actor.
    func scanMetadata(progress: CensusProgressHandler) async throws -> CensusScan

    /// Stage 2, the filename pass: a hint for every asset in `scan`, in the same order. The names
    /// themselves are dropped as soon as they are classified.
    func scanFilenames(of scan: CensusScan, progress: CensusProgressHandler) async throws -> [FilenameHint]

    /// Stage 3: up to `sampleSize` photos from `scan`, picked at random, each asked for a local
    /// thumbnail of about 256 px with network access off.
    func probeThumbnails(of scan: CensusScan, sampleSize: Int, progress: CensusProgressHandler) async throws -> ThumbnailProbe
}

/// The sources' names, as reports show them.
public enum CensusSourceName {
    /// The iPhone's own library.
    public static let photoKit = "PhotoKit"
    /// The synthetic library (tests, previews, `-LZPhotos`).
    public static let sample = "Sample library"
}

/// How far a stage has got.
public struct CensusProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// 0…1 (1 when there is nothing to do).
    public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 1 }
}

/// Called by a stage as it goes, from any thread.
public typealias CensusProgressHandler = @Sendable (CensusProgress) -> Void

/// Why a census stopped.
public enum CensusError: Error, Sendable, Hashable {
    /// Photo access is not limited or full.
    case noAccess
    /// A stage was handed a scan from another source, or the hints don't line up with the facts.
    case mismatchedScan
    /// Anything else, with its description.
    case unexpected(String)
}

/// The metadata pass's result: every asset's facts, in the source's order.
public struct CensusScan: Sendable {
    public var facts: [AssetFacts]
    /// The access the scan ran with (limited counts only what was shared).
    public var access: PhotoAccess
    /// Frames inside burst stacks that the library keeps out of view: counted, never read (nil
    /// when unknown).
    public var extraBurstFrames: Int?
    /// The source's way back to the same assets, in the same order, for the later stages (the live
    /// source keeps its PhotoKit fetch result). Opaque to everyone else.
    public let handle: (any Sendable)?

    public init(facts: [AssetFacts], access: PhotoAccess, extraBurstFrames: Int? = nil, handle: (any Sendable)? = nil) {
        self.facts = facts
        self.access = access
        self.extraBurstFrames = extraBurstFrames
        self.handle = handle
    }

    /// The same scan with each asset's filename hint filled in from the filename pass.
    public func applying(_ hints: [FilenameHint]) throws -> CensusScan {
        guard hints.count == facts.count else { throw CensusError.mismatchedScan }
        var scan = self
        for index in scan.facts.indices { scan.facts[index].filenameHint = hints[index] }
        return scan
    }
}

// MARK: Thumbnails

/// What one local thumbnail request gave back.
public enum ThumbnailOutcome: String, Sendable, Codable, CaseIterable {
    /// A local image whose short side is at least ``ThumbnailProbe/minimumShortSide``.
    case usable
    /// A local image, but smaller than that.
    case tooSmall
    /// No image: the data is only in iCloud (PhotoKit's in-cloud flag).
    case cloudOnly
    /// No image, for another reason.
    case failed

    /// Classifies PhotoKit's answer: the image's pixel size (nil without an image) and whether
    /// PhotoKit flagged the data as only in iCloud.
    public init(width: Int?, height: Int?, isInCloud: Bool) {
        if let width, let height, width > 0, height > 0 {
            self = min(width, height) >= ThumbnailProbe.minimumShortSide ? .usable : .tooSmall
        } else {
            self = isInCloud ? .cloudOnly : .failed
        }
    }
}

/// The thumbnail stage's result over a random sample of photos (aggregates only).
public struct ThumbnailProbe: Sendable, Codable, Hashable {
    /// The indexer's floor (mvp-design §3): a thumbnail smaller than this marks a photo pendingCloud.
    public static let minimumShortSide = 224
    /// The size the census asks for, as the indexer will (pixels, aspect fill).
    public static let requestSide = 256

    /// The sample size asked for.
    public var requested: Int
    /// Photos actually probed (fewer when the library is smaller, or the run stopped early).
    public var sampled: Int
    public var usable: Int
    public var tooSmall: Int
    public var cloudOnly: Int
    public var failed: Int
    /// Results PhotoKit marked as degraded (expected to be 0 with high-quality delivery).
    public var degraded: Int
    public var totalSeconds: Double
    public var medianMilliseconds: Double
    public var p95Milliseconds: Double

    /// Not usable: missing, iCloud only or too small (the design's pendingCloud).
    public var pending: Int { sampled - usable }
}

/// Builds a ``ThumbnailProbe`` one request at a time.
public struct ThumbnailTally: Sendable {
    private var probe: ThumbnailProbe
    private var durations: [Double] = []

    public init(requested: Int) {
        probe = ThumbnailProbe(requested: requested, sampled: 0, usable: 0, tooSmall: 0, cloudOnly: 0, failed: 0, degraded: 0,
                               totalSeconds: 0, medianMilliseconds: 0, p95Milliseconds: 0)
    }

    public mutating func add(_ outcome: ThumbnailOutcome, degraded: Bool = false, duration: Duration) {
        probe.sampled += 1
        switch outcome {
        case .usable: probe.usable += 1
        case .tooSmall: probe.tooSmall += 1
        case .cloudOnly: probe.cloudOnly += 1
        case .failed: probe.failed += 1
        }
        if degraded { probe.degraded += 1 }
        durations.append(duration.milliseconds)
    }

    /// The finished probe; `total` is the stage's wall time.
    public func result(total: Duration) -> ThumbnailProbe {
        var result = probe
        let sorted = durations.sorted()
        result.totalSeconds = total.seconds
        result.medianMilliseconds = Self.percentile(sorted, 0.5)
        result.p95Milliseconds = Self.percentile(sorted, 0.95)
        return result
    }

    /// Nearest-rank percentile of sorted values (0 when empty).
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}

extension Duration {
    /// Whole and fractional seconds.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
