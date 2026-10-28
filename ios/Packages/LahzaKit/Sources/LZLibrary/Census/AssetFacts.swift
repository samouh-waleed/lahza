import Foundation
import LZGeo

/// What Lahza knows about one photo or video: PhotoKit's metadata as plain values.
///
/// The census keeps facts in memory for one run and reports only ``LibraryCensus``'s aggregates.
/// From search v0 the on-device index stores them (a rebuildable cache, purged when photo access
/// is revoked). Per-asset facts are never logged or reported, and the type is deliberately not
/// `Codable`, so nothing serialises them by accident.
public struct AssetFacts: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case photo, video, other
    }

    /// The PhotoKit media subtypes the census counts.
    public struct Subtypes: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let screenshot = Subtypes(rawValue: 1 << 0)
        public static let livePhoto = Subtypes(rawValue: 1 << 1)
        public static let panorama = Subtypes(rawValue: 1 << 2)
        public static let hdr = Subtypes(rawValue: 1 << 3)
        /// Portrait mode (a depth effect).
        public static let depthEffect = Subtypes(rawValue: 1 << 4)
        public static let screenRecording = Subtypes(rawValue: 1 << 5)
        /// High frame rate video.
        public static let sloMo = Subtypes(rawValue: 1 << 6)
        public static let timeLapse = Subtypes(rawValue: 1 << 7)
    }

    /// Where PhotoKit says the asset comes from. The census fetches the user library only (the
    /// iCloud Shared Library is part of it), so anything else means the fetch rules changed.
    public enum Source: String, Sendable, Codable {
        case userLibrary, cloudShared, synced, unknown
    }

    /// How a photo is stored (from PhotoKit's content type).
    public enum ImageFormat: String, Sendable, Codable, CaseIterable {
        case heif, jpeg, png, gif, raw, other
    }

    public var kind: Kind
    public var subtypes: Subtypes
    /// Photos only.
    public var format: ImageFormat?
    public var creationDate: Date?
    public var modificationDate: Date?
    /// When the asset joined the library, as the device that added it recorded (PhotoKit, iOS 26+).
    public var addedDate: Date?
    /// Where it was taken. Never logged or reported.
    public var coordinate: Coordinate?
    /// The location's horizontal accuracy in metres (nil or negative: unknown). Never reported.
    public var horizontalAccuracy: Double?
    public var isFavorite: Bool
    /// Part of a burst (PhotoKit's burst identifier is set).
    public var hasBurstIdentifier: Bool
    /// The burst's representative: the one frame the library shows for the stack.
    public var representsBurst: Bool
    /// Seconds (videos).
    public var duration: TimeInterval
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var source: Source
    /// What the original filename suggests; nil until the filename pass has run. The name itself is
    /// never kept.
    public var filenameHint: FilenameHint?

    public init(kind: Kind, subtypes: Subtypes = [], format: ImageFormat? = nil, creationDate: Date? = nil,
                modificationDate: Date? = nil, addedDate: Date? = nil, coordinate: Coordinate? = nil,
                horizontalAccuracy: Double? = nil, isFavorite: Bool = false, hasBurstIdentifier: Bool = false,
                representsBurst: Bool = false, duration: TimeInterval = 0, pixelWidth: Int = 0, pixelHeight: Int = 0,
                source: Source = .userLibrary, filenameHint: FilenameHint? = nil) {
        self.kind = kind
        self.subtypes = subtypes
        self.format = format
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.addedDate = addedDate
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.isFavorite = isFavorite
        self.hasBurstIdentifier = hasBurstIdentifier
        self.representsBurst = representsBurst
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.source = source
        self.filenameHint = filenameHint
    }

    /// It has a usable GPS position.
    public var isLocated: Bool { coordinate?.isValid ?? false }

    /// The longer side in pixels.
    public var longSide: Int { max(pixelWidth, pixelHeight) }
}
