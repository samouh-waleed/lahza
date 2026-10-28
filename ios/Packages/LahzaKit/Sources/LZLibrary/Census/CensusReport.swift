import Foundation

/// What a library census found: aggregate numbers only. It holds no filename, coordinate or date of
/// a single photo, so it is safe to share. ``LibraryCensus`` builds it; `CensusReport+Text` words it
/// for the screen and the shared report.
public struct CensusReport: Sendable, Codable, Hashable {
    /// Bumped when fields change meaning, so reports from different builds can be compared.
    public static let currentFormat = 1

    public var format = CensusReport.currentFormat
    /// When the census ran.
    public var generatedAt: Date
    /// The run's day on the iPhone's calendar ("2026-10-27"): the census's own date, never a photo's.
    public var runDay: String
    /// The source's name ("PhotoKit", "Sample library").
    public var source: String
    public var access: PhotoAccess
    public var device: DeviceInfo
    public var library = Library()
    public var location = Location()
    public var received = Received()
    public var dates = Dates()
    public var duplicates = Duplicates()
    /// Nil when the thumbnail stage didn't run.
    public var thumbnails: ThumbnailProbe?
    public var video = Video()
    public var moments = Moments()
    public var speed = Speed()
    public var verdicts = Verdicts()
    /// Metrics PhotoKit doesn't expose publicly (or that the census leaves out by design), so they
    /// are reported as unavailable instead of guessed.
    public var unavailable: [String] = []

    public struct Library: Sendable, Codable, Hashable {
        public var total = 0
        public var photos = 0
        public var videos = 0
        public var other = 0
        public var screenshots = 0
        public var livePhotos = 0
        public var panoramas = 0
        public var hdr = 0
        public var portrait = 0
        public var favorites = 0
        /// Photos that are not screen captures (by subtype or name) and not likely received.
        public var cameraPhotos = 0
        public var heif = 0
        public var jpeg = 0
        public var png = 0
        /// GIF, RAW and anything else.
        public var otherFormats = 0
        /// Assets whose source isn't the user library (expected 0: the fetch asks for it only).
        public var outsideUserLibrary = 0
    }

    public struct Location: Sendable, Codable, Hashable {
        public var photos = 0
        public var photosLocated = 0
        public var cameraPhotos = 0
        public var cameraPhotosLocated = 0
        public var videos = 0
        public var videosLocated = 0
        /// Located photos by horizontal accuracy.
        public var within10m = 0
        public var within100m = 0
        public var over100m = 0
        public var accuracyUnknown = 0
    }

    public struct Received: Sendable, Codable, Hashable {
        /// The filename pass ran; without it, received counts use the shape rule only.
        public var filenamesRead = false
        /// Named like a messaging app, or matching the shape rule.
        public var likelyPhotos = 0
        /// Named like a messaging app (the shape rule is for photos only).
        public var likelyVideos = 0
        /// Filename hints over all photos and videos.
        public var namedWhatsApp = 0
        public var namedTelegram = 0
        public var namedOtherMessaging = 0
        public var namedCamera = 0
        public var namedScreenshot = 0
        public var namedUnknown = 0
        /// Photos with no GPS, not a screen capture, at a messaging app's size.
        public var unlocatedAtMessagingSize = 0
        /// …of which the added date is within ``LibraryCensus/receivedAddedWithin`` of the creation
        /// date (or either date is unknown): the shape rule.
        public var shapeMatches = 0
        /// Photos named like a messaging app…
        public var namedMessagingPhotos = 0
        /// …that the shape rule also catches (how well it works without names).
        public var namedMessagingPhotosMatchingShape = 0
        /// Shape-rule matches whose name looks like a camera's (iOS renames saved images, or a false match).
        public var shapeMatchesNamedCamera = 0
        /// The most common long sides among photos without GPS that aren't screen captures.
        public var unlocatedLongSides: [SideCount] = []
    }

    public struct SideCount: Sendable, Codable, Hashable {
        public var side: Int
        public var count: Int
    }

    public struct Dates: Sendable, Codable, Hashable {
        public var dated = 0
        public var missing = 0
        public var before2000 = 0
        /// More than ``LibraryCensus/futureSlack`` after the census ran.
        public var inFuture = 0
        public var earliestYear: Int?
        public var latestYear: Int?
        public var perYear: [YearCount] = []
        /// PhotoKit's added date is known.
        public var addedKnown = 0
        /// Added within ``LibraryCensus/receivedAddedWithin`` of creation.
        public var addedNearCreation = 0
        /// Added more than a day after creation (imports, transfers).
        public var addedDayOrMoreLater = 0
        /// Added more than ``LibraryCensus/receivedAddedWithin`` before creation (an edited date or a wrong clock).
        public var addedBeforeCreation = 0
    }

    public struct YearCount: Sendable, Codable, Hashable {
        public var year: Int
        public var count: Int
    }

    /// An estimate: the same second and size can also be different photos saved together from a chat.
    public struct Duplicates: Sendable, Codable, Hashable {
        /// Groups of two or more with the same kind, creation second and pixel size (bursts left out).
        public var groups = 0
        /// Copies beyond the first in each group.
        public var extraCopies = 0
        public var largestGroup = 0
        /// Groups whose items are all likely received (often chat saves rather than true copies).
        public var receivedGroups = 0
        /// Burst frames the library shows (representatives and picks).
        public var burstAssets = 0
        public var burstStacks = 0
        /// Burst frames shown on their own (picked from a stack), not as the representative.
        public var burstPicks = 0
        /// Frames inside stacks that the library keeps out of view; nil when not counted.
        public var extraBurstFrames: Int?
    }

    public struct Video: Sendable, Codable, Hashable {
        public var count = 0
        public var totalSeconds = 0.0
        /// Decision 13: frames are sampled for local videos up to 10 minutes.
        public var upTo10Minutes = 0
        public var medianSeconds = 0.0
        public var screenRecordings = 0
        public var sloMo = 0
        public var timeLapses = 0
    }

    public struct Moments: Sendable, Codable, Hashable {
        public var count = 0
        /// Dated photos and videos that were grouped.
        public var items = 0
        public var singleItem = 0
        public var medianSize = 0
        public var largest = 0
        /// What started each new moment.
        public var splitsByGap = 0
        public var splitsByJump = 0
        public var splitsByDayBreak = 0
    }

    public struct Speed: Sendable, Codable, Hashable {
        public var metadataSeconds: Double?
        public var filenamesSeconds: Double?
        public var thumbnailsSeconds: Double?
        public var totalSeconds: Double?
        /// The metadata pass scaled to 30,000 photos and videos (the plan's unit).
        public var metadataSecondsPer30k: Double?
        public var filenamesSecondsPer30k: Double?
        /// Lahza left the foreground during the run (the times include the pause).
        public var interrupted = false
    }

    /// The S2 pass marks (mvp-design §7), judged from ``LibraryCensus/markMinimumSample`` photos up,
    /// and the plan's speed check.
    public struct Verdicts: Sendable, Codable, Hashable {
        /// Usable local thumbnails ≥ 85 % of the sample.
        public var usableThumbnails = CensusVerdict.unavailable
        /// Camera photos located ≥ 70 %; otherwise flagged: the place signal is weak and the place
        /// visual signature for photos without GPS moves up.
        public var placeSignal = CensusVerdict.unavailable
        /// Flagged when more than 10 % of the sample is pending iCloud: the opt-in preview download moves into the MVP.
        public var pendingCloud = CensusVerdict.unavailable
        /// Not an S2 mark: the metadata pass within the plan's ~1 min per 30k photos, judged only on a
        /// real iPhone library of 1,000 assets up, with Lahza in the foreground the whole run.
        public var metadataSpeed = CensusVerdict.unavailable
    }
}

/// One pass mark's outcome.
public enum CensusVerdict: String, Sendable, Codable, Hashable {
    case pass
    case fail
    /// A threshold was crossed that changes the plan (not a failure).
    case flag
    /// Not enough data (too few photos, a skipped stage, timings that aren't comparable).
    case unavailable
}

extension PhotoAccess: Codable {}
