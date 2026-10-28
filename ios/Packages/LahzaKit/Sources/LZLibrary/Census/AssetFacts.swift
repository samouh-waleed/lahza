import Foundation

/// What the library census knows about one photo or video: PhotoKit's metadata as plain values.
///
/// Facts live in memory for one census run and are then dropped. The type is deliberately not
/// `Codable`: per-asset facts are never stored, logged or reported, and only ``LibraryCensus``'s
/// aggregates leave it. The coordinate is kept only to count located photos and split moments.
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
    /// Where it was taken. In memory only, never reported.
    public var coordinate: Coordinate?
    /// The location's horizontal accuracy in metres (nil or negative: unknown). In memory only.
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

/// A position in degrees. Platform-neutral, so the census logic runs on the Mac.
public struct Coordinate: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// In range and not exactly (0, 0), which some apps write when they have no position.
    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && !(latitude == 0 && longitude == 0)
    }

    /// The great-circle distance in metres (haversine; plenty for a 1 km rule).
    public func distance(to other: Coordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }
}
