import Foundation
import LZEmbedding

/// The Vision pass's version (content search P1a): bump it when tags are stored differently, and every photo is
/// tagged again.
public enum VisualPass {
    public static let version = 1
}

/// The embedding pass's version (content search P1b), apart from the Vision pass's: bump it when vectors are made
/// differently, and every photo is embedded again. Turning the model on only fills the photos without a vector.
public enum EmbedPass {
    public static let version = 1
}

/// What made a photo's vector (`asset_visual.embed_units`). The CPU's vectors are a little further from the model's
/// reference, so the foreground makes them again.
public enum EmbedUnits: Int, Sendable, Hashable {
    /// The model was asked and gave none (no image now, or it failed): tried again after ``VisualPolicy/cloudRetry``.
    case failed = 0
    /// The Neural Engine or the GPU (in the foreground).
    case all = 1
    case cpu = 2

    public init(_ mode: ComputeMode) {
        self = mode == .foreground ? .all : .cpu
    }
}

/// Which of Vision's filters a photo's tag passed (`asset_label.flags`). Every stored tag passed Apple's high-recall
/// filter, `hasMinimumPrecision(0.1, forRecall: 0.8)`.
public struct VisualLabelFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `hasMinimumRecall(0.01, forPrecision: 0.7)`: a tuning point between the two of Apple's sample.
    public static let likely = VisualLabelFlags(rawValue: 1)
    /// `hasMinimumRecall(0.01, forPrecision: 0.9)`: Apple's high-precision filter.
    public static let precise = VisualLabelFlags(rawValue: 2)
}

/// Where a photo is in the Vision pass (`asset_visual.status`).
public enum VisualStatus: Int, Sendable, Hashable {
    case pending = 0
    case done = 1
    /// No image on the iPhone large enough: checked again later, never counted as "no".
    case pendingCloud = 2
    /// The asset or its image is gone, or Vision failed on it.
    case failed = 3
}

/// One photo tag Vision gave a photo. Confidences compare only within one tag, never across tags.
public struct VisualLabel: Sendable, Hashable {
    public var name: String
    public var confidence: Float
    public var flags: VisualLabelFlags

    public init(name: String, confidence: Float, flags: VisualLabelFlags) {
        self.name = name
        self.confidence = confidence
        self.flags = flags
    }
}

/// What the Vision pass found in one photo.
public struct VisualAnalysis: Sendable, Hashable {
    public var labels: [VisualLabel]
    public var faces: Int
    public var humans: Int
    /// The largest face's share of the frame (0 without a face).
    public var largestFace: Double
    /// Vision's "utility" verdict: receipts, screenshots, documents (junk for most searches).
    public var isUtility: Bool
    /// Vision's overall aesthetics score (−1…1), for picking covers later.
    public var aesthetic: Double

    public init(labels: [VisualLabel], faces: Int = 0, humans: Int = 0, largestFace: Double = 0, isUtility: Bool = false, aesthetic: Double = 0) {
        self.labels = labels
        self.faces = faces
        self.humans = humans
        self.largestFace = largestFace
        self.isUtility = isUtility
        self.aesthetic = aesthetic
    }
}

public enum VisualOutcome: Sendable, Hashable {
    /// What was asked for from one image: the tags (nil when not asked) and the embedding (nil when not asked, or when
    /// the model failed on it).
    case analysed(VisualAnalysis?, vector: [Float]? = nil)
    /// No local image large enough (`pendingCloud`).
    case inCloud
    case failed
}

/// A photo or video to tag.
public struct VisualAsset: Sendable, Hashable {
    /// The asset row id.
    public var id: Int64
    public var localID: String
    /// Unix seconds; nil when undated.
    public var createdUTC: Int64?

    public init(id: Int64, localID: String, createdUTC: Int64?) {
        self.id = id
        self.localID = localID
        self.createdUTC = createdUTC
    }
}

/// Tags and embeds photos (``VisionAnalyzer`` on the iPhone; the seed's stand-in in DEBUG), from one image each.
/// Videos are tagged and embedded from their poster frame.
public protocol VisualAnalyzer: Sendable {
    /// Every tag it can give, in its own order (Vision's `supportedIdentifiers`).
    func supportedLabels() async -> [String]
    /// The photo's tags when `tags`, and its embedding by `embedder` when there is one.
    func analyze(_ asset: VisualAsset, tags: Bool, embedder: (any ImageEmbedder)?) async -> VisualOutcome
}
