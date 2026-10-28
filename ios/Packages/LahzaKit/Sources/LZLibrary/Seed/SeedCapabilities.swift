#if DEBUG
import Foundation

/// What importing the seed files into the Simulator's Photos library keeps (spec R1). Recorded by
/// `PhotoKitProbeTests` on the seeded simulator, which fails when PhotoKit stops matching it; search
/// goldens that depend on a fact that doesn't import run on the fake reader only.
public struct SeedCapabilities: Sendable, Hashable {
    /// JPEG EXIF DateTimeOriginal + OffsetTimeOriginal become the creation date (±1 s).
    public var photoDates: Bool
    /// JPEG EXIF GPS becomes the location (±1 m).
    public var photoLocations: Bool
    /// PNG EXIF DateTimeOriginal + OffsetTimeOriginal become the creation date (±1 s).
    public var screenshotDates: Bool
    /// A PNG with EXIF UserComment "Screenshot" gets PhotoKit's screenshot subtype.
    public var screenshotSubtype: Bool
    /// A front-camera EXIF lens model puts a photo in the Selfies album.
    public var selfiesAlbum: Bool
    /// QuickTime `com.apple.quicktime.creationdate` becomes the creation date (±1 s).
    public var videoDates: Bool
    /// QuickTime `com.apple.quicktime.location.ISO6709` becomes the location (±1 m).
    public var videoLocations: Bool
    /// The added date is the import time, not the capture time (so the received shape rule can't match).
    public var addedDateIsImportTime: Bool
    /// `creationDate <= %@` with a creation-date-descending sort returns exactly the assets at or before the frontier, newest first.
    public var frontierPredicate: Bool
    /// PhotoKit accepts `creationDate == nil` as a predicate.
    public var nilDatePredicate: Bool
    /// The Simulator's own sample photos, for information (the goldens ignore them).
    public var builtInSamples: [Sample]

    public struct Sample: Sendable, Hashable {
        public var isVideo: Bool
        /// Creation date in UTC seconds.
        public var utc: Int64?
        public var isLocated: Bool
        public var pixelWidth: Int
        public var pixelHeight: Int

        public init(isVideo: Bool, utc: Int64?, isLocated: Bool, pixelWidth: Int, pixelHeight: Int) {
            self.isVideo = isVideo
            self.utc = utc
            self.isLocated = isLocated
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    public init(photoDates: Bool, photoLocations: Bool, screenshotDates: Bool, screenshotSubtype: Bool, selfiesAlbum: Bool,
                videoDates: Bool, videoLocations: Bool, addedDateIsImportTime: Bool, frontierPredicate: Bool, nilDatePredicate: Bool,
                builtInSamples: [Sample]) {
        self.photoDates = photoDates
        self.photoLocations = photoLocations
        self.screenshotDates = screenshotDates
        self.screenshotSubtype = screenshotSubtype
        self.selfiesAlbum = selfiesAlbum
        self.videoDates = videoDates
        self.videoLocations = videoLocations
        self.addedDateIsImportTime = addedDateIsImportTime
        self.frontierPredicate = frontierPredicate
        self.nilDatePredicate = nilDatePredicate
        self.builtInSamples = builtInSamples
    }

    /// Recorded with `make probe-photos` on the iPhone 18 Pro simulator (iOS 27.0 runtime, Xcode 27.1), 2026-10-28:
    /// all 557 seed files imported with their dates, positions, screenshot subtype and Selfies membership.
    public static let hero = SeedCapabilities(
        photoDates: true, photoLocations: true, screenshotDates: true, screenshotSubtype: true, selfiesAlbum: true,
        videoDates: true, videoLocations: true, addedDateIsImportTime: true, frontierPredicate: true, nilDatePredicate: true,
        builtInSamples: [
            Sample(isVideo: false, utc: 1_255_122_560, isLocated: false, pixelWidth: 4288, pixelHeight: 2848),
            Sample(isVideo: false, utc: 1_299_975_445, isLocated: true, pixelWidth: 4288, pixelHeight: 2848),
            Sample(isVideo: false, utc: 1_344_451_932, isLocated: true, pixelWidth: 3000, pixelHeight: 2002),
            Sample(isVideo: false, utc: 1_344_461_390, isLocated: true, pixelWidth: 1668, pixelHeight: 2500),
            Sample(isVideo: false, utc: 1_344_462_930, isLocated: true, pixelWidth: 3000, pixelHeight: 2002),
            Sample(isVideo: false, utc: 1_522_437_259, isLocated: true, pixelWidth: 4032, pixelHeight: 3024),
        ]
    )

    /// How many PhotoKit items should have a position after import, by these capabilities.
    public func expectedLocatedCount(in scenario: SeedScenario) -> Int {
        scenario.photoKitItems.filter { $0.isLocated && ($0.isVideo ? videoLocations : photoLocations) }.count
    }
}
#endif
