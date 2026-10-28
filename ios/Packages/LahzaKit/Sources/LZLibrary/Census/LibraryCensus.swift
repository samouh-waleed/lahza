import Foundation

/// Where a census's facts came from and when it ran.
public struct CensusContext: Sendable {
    /// The source's name ("PhotoKit", "Sample library").
    public var sourceName: String
    public var device: DeviceInfo
    public var generatedAt: Date
    /// The calendar and time zone for years and the 04:00 day break (the iPhone's own).
    public var calendar: Calendar

    public init(sourceName: String, device: DeviceInfo, generatedAt: Date, calendar: Calendar) {
        self.sourceName = sourceName
        self.device = device
        self.generatedAt = generatedAt
        self.calendar = calendar
    }
}

/// How long each stage took, on a monotonic clock.
public struct CensusTimings: Sendable, Hashable {
    public var metadata: Duration?
    public var filenames: Duration?
    public var thumbnails: Duration?
    public var total: Duration?
    /// Lahza left the foreground during the run, so the times include that pause.
    public var interrupted: Bool

    public init(metadata: Duration? = nil, filenames: Duration? = nil, thumbnails: Duration? = nil, total: Duration? = nil,
                interrupted: Bool = false) {
        self.metadata = metadata
        self.filenames = filenames
        self.thumbnails = thumbnails
        self.total = total
        self.interrupted = interrupted
    }
}

/// Phase 0 spike S2 (mvp-design §3 and §7): turns a census scan into a ``CensusReport`` of
/// aggregate numbers. Pure and platform-neutral, so every rule is tested on the Mac.
///
/// The rules are the design's placeholders, named here so the report can quote them.
public enum LibraryCensus {
    // MARK: Rules

    /// The long sides (pixels) messaging apps commonly resize photos to: WhatsApp 1600 (standard
    /// quality); Telegram 1280 and 2560 (high quality); Signal and Messenger 2048. A guess to
    /// calibrate: the report shows how the shape rule agrees with filename hints and lists the most
    /// common long sides among photos without GPS.
    public static let messagingLongSides: Set<Int> = [1280, 1600, 2048, 2560]
    /// "Creation ≈ added" (P0's likelyReceived): a received photo is saved as it arrives, so the
    /// library adds it within minutes of its creation date. PhotoKit's added date exists from iOS 26.
    public static let receivedAddedWithin: TimeInterval = 10 * 60
    /// P0b: a new moment after a gap of more than 90 minutes…
    public static let momentGap: TimeInterval = 90 * 60
    /// …or a jump of more than 1 km between located items…
    public static let momentJump: Double = 1_000
    /// …and never across 04:00, when the day breaks.
    public static let dayBreakHour = 4
    /// S2 pass mark: usable local thumbnails, percent of the sample.
    public static let usableThumbnailPercent = 85
    /// S2: camera photos located, percent. Below it the place signal is weak, and the place visual
    /// signature for photos without GPS moves up from Phase 2 (mvp-design §7).
    public static let placeSignalPercent = 70
    /// S2: more than this percent of the sample pending iCloud moves the opt-in preview download into the MVP.
    public static let pendingCloudPercent = 10
    /// The S2 marks are judged only from this many sampled photos (thumbnails) or camera photos
    /// (place) up: a few dozen photos, say under limited access, can't pass or fail a plan.
    public static let markMinimumSample = 100
    /// The plan's metadata pass: about a minute per 30,000 photos and videos.
    public static let planSecondsPer30k: Double = 60
    /// Below this many assets the fetch's fixed cost swamps the per-asset time, so speed isn't judged.
    public static let speedMinimumAssets = 1_000
    /// Decision 13: frames are sampled for videos up to 10 minutes.
    public static let videoSampleLimit: TimeInterval = 10 * 60
    /// Dates this far past the census run count as "in the future" (time-zone slips stay out).
    public static let futureSlack: TimeInterval = 24 * 60 * 60

    /// What PhotoKit doesn't expose publicly, or the census leaves out by design.
    public static let unavailable = [
        "iCloud Shared Library vs personal library: PhotoKit doesn't say which library a photo is in, so both are counted together.",
        "Local copies of videos: not checked; the thumbnail sample covers photos only.",
        "Hidden album: left out by design (decision 14) and never read.",
        "Capture time zone: PhotoKit doesn't expose it, so the 04:00 day break uses this iPhone's current time zone for every photo, trips abroad included.",
    ]

    // MARK: Summary

    public static func summarize(_ scan: CensusScan, thumbnails: ThumbnailProbe?, timings: CensusTimings, context: CensusContext) -> CensusReport {
        let facts = scan.facts
        var report = CensusReport(generatedAt: context.generatedAt, runDay: day(context.generatedAt, calendar: context.calendar),
                                  source: context.sourceName, access: scan.access, device: context.device)
        report.library = library(facts)
        report.location = location(facts)
        report.received = received(facts)
        report.dates = dates(facts, now: context.generatedAt, calendar: context.calendar)
        report.duplicates = duplicates(facts, extraBurstFrames: scan.extraBurstFrames)
        report.thumbnails = thumbnails
        report.video = video(facts)
        report.moments = moments(facts, calendar: context.calendar)
        report.speed = speed(timings, assets: facts.count)
        report.verdicts = verdicts(report)
        report.unavailable = unavailable
        return report
    }

    /// "2026-10-27" on `calendar`.
    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Classification

    /// A screenshot by PhotoKit's subtype, or a photo named like one.
    static func isScreenCapture(_ facts: AssetFacts) -> Bool {
        facts.subtypes.contains(.screenshot) || facts.filenameHint == .screenshot
    }

    /// Whether the added date is within ``receivedAddedWithin`` of the creation date (nil when
    /// either is unknown).
    static func addedNearCreation(_ facts: AssetFacts) -> Bool? {
        guard let created = facts.creationDate, let added = facts.addedDate else { return nil }
        return abs(added.timeIntervalSince(created)) <= receivedAddedWithin
    }

    /// The shape rule, P0's likelyReceived without filenames: a photo with no GPS that is not a
    /// screen capture, at a messaging app's size, added about when it was created (an unknown date
    /// doesn't rule it out).
    static func matchesReceivedShape(_ facts: AssetFacts) -> Bool {
        facts.kind == .photo && !facts.isLocated && !isScreenCapture(facts)
            && messagingLongSides.contains(facts.longSide) && addedNearCreation(facts) != false
    }

    /// Named like a messaging app, or (photos) matching the shape rule.
    static func isLikelyReceived(_ facts: AssetFacts) -> Bool {
        facts.filenameHint?.isMessaging == true || matchesReceivedShape(facts)
    }

    /// A photo that is neither a screen capture nor likely received: the place signal's target.
    static func isCameraPhoto(_ facts: AssetFacts) -> Bool {
        facts.kind == .photo && !isScreenCapture(facts) && !isLikelyReceived(facts)
    }

    // MARK: Sections

    static func library(_ facts: [AssetFacts]) -> CensusReport.Library {
        var library = CensusReport.Library()
        library.total = facts.count
        for item in facts {
            if item.isFavorite { library.favorites += 1 }
            if item.source != .userLibrary { library.outsideUserLibrary += 1 }
            switch item.kind {
            case .video: library.videos += 1
            case .other: library.other += 1
            case .photo:
                library.photos += 1
                if item.subtypes.contains(.screenshot) { library.screenshots += 1 }
                if item.subtypes.contains(.livePhoto) { library.livePhotos += 1 }
                if item.subtypes.contains(.panorama) { library.panoramas += 1 }
                if item.subtypes.contains(.hdr) { library.hdr += 1 }
                if item.subtypes.contains(.depthEffect) { library.portrait += 1 }
                switch item.format {
                case .heif?: library.heif += 1
                case .jpeg?: library.jpeg += 1
                case .png?: library.png += 1
                default: library.otherFormats += 1
                }
                if isCameraPhoto(item) { library.cameraPhotos += 1 }
            }
        }
        return library
    }

    static func location(_ facts: [AssetFacts]) -> CensusReport.Location {
        var location = CensusReport.Location()
        for item in facts {
            switch item.kind {
            case .photo:
                location.photos += 1
                if isCameraPhoto(item) {
                    location.cameraPhotos += 1
                    if item.isLocated { location.cameraPhotosLocated += 1 }
                }
                guard item.isLocated else { continue }
                location.photosLocated += 1
                switch item.horizontalAccuracy {
                case let accuracy? where accuracy >= 0 && accuracy <= 10: location.within10m += 1
                case let accuracy? where accuracy > 10 && accuracy <= 100: location.within100m += 1
                case let accuracy? where accuracy > 100: location.over100m += 1
                default: location.accuracyUnknown += 1
                }
            case .video:
                location.videos += 1
                if item.isLocated { location.videosLocated += 1 }
            case .other:
                break
            }
        }
        return location
    }

    static func received(_ facts: [AssetFacts]) -> CensusReport.Received {
        var received = CensusReport.Received()
        received.filenamesRead = !facts.isEmpty && facts.allSatisfy { $0.filenameHint != nil }
        var sides: [Int: Int] = [:]
        for item in facts {
            switch item.filenameHint {
            case .whatsapp?: received.namedWhatsApp += 1
            case .telegram?: received.namedTelegram += 1
            case .otherMessaging?: received.namedOtherMessaging += 1
            case .camera?: received.namedCamera += 1
            case .screenshot?: received.namedScreenshot += 1
            case .unknown?: received.namedUnknown += 1
            case nil: break
            }
            switch item.kind {
            case .photo:
                let named = item.filenameHint?.isMessaging == true
                let shape = matchesReceivedShape(item)
                if named || shape { received.likelyPhotos += 1 }
                if named {
                    received.namedMessagingPhotos += 1
                    if shape { received.namedMessagingPhotosMatchingShape += 1 }
                }
                if shape {
                    received.shapeMatches += 1
                    if item.filenameHint == .camera { received.shapeMatchesNamedCamera += 1 }
                }
                guard !item.isLocated, !isScreenCapture(item), item.longSide > 0 else { continue }
                sides[item.longSide, default: 0] += 1
                if messagingLongSides.contains(item.longSide) { received.unlocatedAtMessagingSize += 1 }
            case .video:
                if item.filenameHint?.isMessaging == true { received.likelyVideos += 1 }
            case .other:
                break
            }
        }
        received.unlocatedLongSides = sides
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8)
            .map { CensusReport.SideCount(side: $0.key, count: $0.value) }
        return received
    }

    static func dates(_ facts: [AssetFacts], now: Date, calendar: Calendar) -> CensusReport.Dates {
        var dates = CensusReport.Dates()
        let year2000 = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 946_684_800)
        let future = now.addingTimeInterval(futureSlack)
        var years: [Int: Int] = [:]
        for item in facts {
            if item.addedDate != nil { dates.addedKnown += 1 }
            guard let created = item.creationDate else {
                dates.missing += 1
                continue
            }
            dates.dated += 1
            if created < year2000 { dates.before2000 += 1 }
            if created > future { dates.inFuture += 1 }
            years[calendar.component(.year, from: created), default: 0] += 1
            guard let added = item.addedDate else { continue }
            let delta = added.timeIntervalSince(created)
            if abs(delta) <= receivedAddedWithin {
                dates.addedNearCreation += 1
            } else if delta >= 24 * 60 * 60 {
                dates.addedDayOrMoreLater += 1
            } else if delta < -receivedAddedWithin {
                dates.addedBeforeCreation += 1
            }
        }
        dates.earliestYear = years.keys.min()
        dates.latestYear = years.keys.max()
        dates.perYear = years.sorted { $0.key < $1.key }.map { CensusReport.YearCount(year: $0.key, count: $0.value) }
        return dates
    }

    static func duplicates(_ facts: [AssetFacts], extraBurstFrames: Int?) -> CensusReport.Duplicates {
        struct Key: Hashable {
            var kind: AssetFacts.Kind
            var second: Int64
            var width: Int
            var height: Int
        }
        var duplicates = CensusReport.Duplicates()
        duplicates.extraBurstFrames = extraBurstFrames
        // Each group's size, and whether every item in it is likely received.
        var groups: [Key: (count: Int, received: Bool)] = [:]
        for item in facts {
            if item.hasBurstIdentifier {
                // Bursts are counted on their own: their frames share a second and a size by nature.
                duplicates.burstAssets += 1
                if item.representsBurst { duplicates.burstStacks += 1 } else { duplicates.burstPicks += 1 }
                continue
            }
            guard let created = item.creationDate, item.pixelWidth > 0, item.pixelHeight > 0 else { continue }
            let key = Key(kind: item.kind, second: Int64(created.timeIntervalSince1970.rounded(.down)),
                          width: item.pixelWidth, height: item.pixelHeight)
            var group = groups[key] ?? (count: 0, received: true)
            group.count += 1
            group.received = group.received && isLikelyReceived(item)
            groups[key] = group
        }
        let found = groups.values.filter { $0.count > 1 }
        duplicates.groups = found.count
        duplicates.extraCopies = found.reduce(0) { $0 + $1.count - 1 }
        duplicates.largestGroup = found.map(\.count).max() ?? 0
        duplicates.receivedGroups = found.filter { $0.received }.count
        return duplicates
    }

    static func video(_ facts: [AssetFacts]) -> CensusReport.Video {
        var video = CensusReport.Video()
        var lengths: [Double] = []
        for item in facts where item.kind == .video {
            video.count += 1
            video.totalSeconds += item.duration
            lengths.append(item.duration)
            if item.duration <= videoSampleLimit { video.upTo10Minutes += 1 }
            if item.subtypes.contains(.screenRecording) { video.screenRecordings += 1 }
            if item.subtypes.contains(.sloMo) { video.sloMo += 1 }
            if item.subtypes.contains(.timeLapse) { video.timeLapses += 1 }
        }
        video.medianSeconds = ThumbnailTally.percentile(lengths.sorted(), 0.5)
        return video
    }

    /// P0b's rough moments over every dated photo and video, in time order: a new moment starts
    /// after a gap of more than 90 minutes, when the day breaks at 04:00 local time, or after a
    /// jump of more than 1 km from the moment's last located item (items without GPS never split).
    ///
    /// "Local" is `calendar`'s time zone: PhotoKit has no public capture time zone.
    static func moments(_ facts: [AssetFacts], calendar: Calendar) -> CensusReport.Moments {
        let items = facts
            .compactMap { item -> (date: Date, place: Coordinate?)? in
                guard item.kind != .other, let date = item.creationDate else { return nil }
                return (date, item.isLocated ? item.coordinate : nil)
            }
            .sorted { $0.date < $1.date }
        var moments = CensusReport.Moments()
        guard !items.isEmpty else { return moments }
        moments.items = items.count

        // The moment day from the wall clock, so the break stays at 04:00 on daylight-saving days
        // (subtracting 4 hours of absolute time would move it to 03:00 or 05:00).
        func day(_ date: Date) -> Int {
            let ordinal = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
            return calendar.component(.hour, from: date) < dayBreakHour ? ordinal - 1 : ordinal
        }

        var sizes: [Int] = []
        var size = 0
        var lastDate = items[0].date
        var lastDay = day(lastDate)
        var lastPlace: Coordinate?
        for item in items {
            let itemDay = day(item.date)
            if size > 0 {
                var split = true
                if item.date.timeIntervalSince(lastDate) > momentGap {
                    moments.splitsByGap += 1
                } else if itemDay != lastDay {
                    moments.splitsByDayBreak += 1
                } else if let place = item.place, let lastPlace, place.distance(to: lastPlace) > momentJump {
                    moments.splitsByJump += 1
                } else {
                    split = false
                }
                if split {
                    sizes.append(size)
                    size = 0
                    lastPlace = nil
                }
            }
            size += 1
            lastDate = item.date
            lastDay = itemDay
            if let place = item.place { lastPlace = place }
        }
        sizes.append(size)

        moments.count = sizes.count
        moments.singleItem = sizes.filter { $0 == 1 }.count
        moments.largest = sizes.max() ?? 0
        let sorted = sizes.sorted()
        moments.medianSize = sorted[sorted.count / 2]
        return moments
    }

    static func speed(_ timings: CensusTimings, assets: Int) -> CensusReport.Speed {
        var speed = CensusReport.Speed()
        speed.metadataSeconds = timings.metadata?.seconds
        speed.filenamesSeconds = timings.filenames?.seconds
        speed.thumbnailsSeconds = timings.thumbnails?.seconds
        speed.totalSeconds = timings.total?.seconds
        speed.interrupted = timings.interrupted
        if assets > 0 {
            let scale = 30_000 / Double(assets)
            speed.metadataSecondsPer30k = speed.metadataSeconds.map { $0 * scale }
            speed.filenamesSecondsPer30k = speed.filenamesSeconds.map { $0 * scale }
        }
        return speed
    }

    static func verdicts(_ report: CensusReport) -> CensusReport.Verdicts {
        var verdicts = CensusReport.Verdicts()
        if let probe = report.thumbnails, probe.sampled >= markMinimumSample {
            verdicts.usableThumbnails = atLeast(probe.usable, of: probe.sampled, percent: usableThumbnailPercent) ? .pass : .fail
            verdicts.pendingCloud = over(probe.pending, of: probe.sampled, percent: pendingCloudPercent) ? .flag : .pass
        }
        let location = report.location
        if location.cameraPhotos >= markMinimumSample {
            // A miss changes the plan (the place visual signature moves up), so it's a flag, not a failure.
            verdicts.placeSignal = atLeast(location.cameraPhotosLocated, of: location.cameraPhotos, percent: placeSignalPercent) ? .pass : .flag
        }
        if let perThirtyThousand = report.speed.metadataSecondsPer30k, report.library.total >= speedMinimumAssets,
           hasComparableTimings(report) {
            verdicts.metadataSpeed = perThirtyThousand <= planSecondsPer30k ? .pass : .flag
        }
        return verdicts
    }

    /// Timings from a real iPhone's own library, with Lahza in the foreground the whole run.
    static func hasComparableTimings(_ report: CensusReport) -> Bool {
        !report.device.isSimulator && report.source == CensusSourceName.photoKit && !report.speed.interrupted
    }

    /// `part` is at least `percent` % of `whole` (exact integer arithmetic, so 85 of 100 passes 85 %).
    static func atLeast(_ part: Int, of whole: Int, percent: Int) -> Bool { part * 100 >= percent * whole }

    /// `part` is more than `percent` % of `whole`.
    static func over(_ part: Int, of whole: Int, percent: Int) -> Bool { part * 100 > percent * whole }
}
