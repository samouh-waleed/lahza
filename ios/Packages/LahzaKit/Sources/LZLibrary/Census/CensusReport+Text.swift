import Foundation

/// One S2 pass mark, worded for the census screen and the shared report.
public struct CensusMark: Sendable, Identifiable, Hashable {
    public var id: String
    /// "Usable local thumbnails".
    public var title: String
    /// "91.3% of 300 sampled photos".
    public var value: String
    /// "Pass mark: at least 85%".
    public var rule: String
    public var verdict: CensusVerdict
    /// "Pass", "Weak", "Flag"…
    public var label: String
}

/// A titled group of label–value rows, with notes under it.
public struct CensusSection: Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var rows: [CensusRow]
    public var notes: [String]
}

public struct CensusRow: Sendable, Identifiable, Hashable {
    public var label: String
    public var value: String
    public var id: String { label }
}

/// The report's wording. Numbers use a fixed English format (not the iPhone's region), so reports
/// from different testers line up.
extension CensusReport {
    /// The S2 pass marks, most important first, then the plan's speed check.
    public var marks: [CensusMark] {
        let probe = thumbnails
        let sampled = probe?.sampled ?? 0
        let minimum = Self.count(LibraryCensus.markMinimumSample)
        return [
            CensusMark(
                id: "thumbnails", title: "Usable local thumbnails",
                value: probe.map { probe in
                    guard probe.sampled > 0 else { return "No photos sampled" }
                    return "\(Self.percent(probe.usable, of: probe.sampled)) of \(Self.count(probe.sampled)) sampled photos "
                        + "(±\(Self.margin(probe.usable, of: probe.sampled)))\(Self.tooFew(probe.sampled))"
                } ?? "Not measured",
                rule: "Pass mark: at least \(LibraryCensus.usableThumbnailPercent)%, judged from \(minimum) sampled photos up",
                verdict: verdicts.usableThumbnails,
                label: Self.label(verdicts.usableThumbnails, pass: "Pass", fail: "Fail")
            ),
            CensusMark(
                id: "place", title: "Camera photos with GPS",
                value: location.cameraPhotos > 0
                    ? "\(Self.percent(location.cameraPhotosLocated, of: location.cameraPhotos)) of \(Self.count(location.cameraPhotos))"
                        + Self.tooFew(location.cameraPhotos)
                    : "No camera photos",
                rule: "OK at \(LibraryCensus.placeSignalPercent)% or more, judged from \(minimum) camera photos up; below that, "
                    + "the place visual signature for photos without GPS moves up from Phase 2",
                verdict: verdicts.placeSignal,
                label: Self.label(verdicts.placeSignal, pass: "OK", fail: "Weak")
            ),
            CensusMark(
                id: "pending", title: "Thumbnails pending iCloud",
                value: sampled > 0 ? "\(Self.percent(probe?.pending ?? 0, of: sampled)) of the sample\(Self.tooFew(sampled))" : "Not measured",
                rule: "Over \(LibraryCensus.pendingCloudPercent)% moves the opt-in preview download into the MVP",
                verdict: verdicts.pendingCloud,
                label: Self.label(verdicts.pendingCloud, pass: "No flag", fail: "Flag")
            ),
            CensusMark(
                id: "speed", title: "Metadata pass speed",
                value: speed.metadataSecondsPer30k.map { "\(Self.seconds($0)) per 30,000 photos and videos" } ?? "Not measured",
                rule: "A plan check, not an S2 mark: about \(Self.seconds(LibraryCensus.planSecondsPer30k)) per 30,000, judged on an "
                    + "iPhone's own library of \(Self.count(LibraryCensus.speedMinimumAssets)) photos and videos up, with Lahza kept open",
                verdict: verdicts.metadataSpeed,
                label: Self.label(verdicts.metadataSpeed, pass: "Within plan", fail: "Slower")
            ),
        ]
    }

    /// Every result section, in screen order.
    public var sections: [CensusSection] {
        [librarySection, locationSection, receivedSection, datesSection, yearsSection, duplicatesSection,
         thumbnailsSection, videoSection, momentsSection, speedSection, deviceSection, unavailableSection]
            .filter { !$0.rows.isEmpty || !$0.notes.isEmpty }
    }

    /// The shareable plain-text report: the marks, every section, then the same numbers as JSON.
    public var text: String {
        var lines = [
            "LAHZA LIBRARY CENSUS (Phase 0 spike S2)",
            "Run \(runDay) · \(source) · \(Self.accessName(access)) · report format \(format)",
            "Aggregate numbers only: no photo, filename, place or date of a single photo.",
            "",
            "S2 MARKS",
        ]
        for mark in marks {
            lines.append("[\(mark.label.uppercased())] \(mark.title): \(mark.value). \(mark.rule).")
        }
        for section in sections {
            lines.append("")
            lines.append(section.title.uppercased())
            lines += section.rows.map { "\($0.label): \($0.value)" }
            lines += section.notes.map { "Note: \($0)" }
        }
        if let json {
            lines += ["", "JSON", json]
        }
        return lines.joined(separator: "\n")
    }

    /// The report as pretty-printed JSON with sorted keys (nil if encoding fails).
    public var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Sections

    private var librarySection: CensusSection {
        let photos = library.photos
        var rows = [
            CensusRow(label: "Photos and videos", value: Self.count(library.total)),
            CensusRow(label: "Photos", value: Self.share(photos, of: library.total)),
            CensusRow(label: "Videos", value: Self.share(library.videos, of: library.total)),
        ]
        if library.other > 0 { rows.append(CensusRow(label: "Other media", value: Self.count(library.other))) }
        rows += [
            CensusRow(label: "Screenshots", value: Self.share(library.screenshots, of: photos)),
            CensusRow(label: "Live Photos", value: Self.share(library.livePhotos, of: photos)),
            CensusRow(label: "Portrait", value: Self.share(library.portrait, of: photos)),
            CensusRow(label: "Panoramas", value: Self.share(library.panoramas, of: photos)),
            CensusRow(label: "HDR", value: Self.share(library.hdr, of: photos)),
            CensusRow(label: "Camera photos", value: Self.share(library.cameraPhotos, of: photos)),
            CensusRow(label: "Favorites", value: Self.share(library.favorites, of: library.total)),
            CensusRow(label: "HEIF · JPEG · PNG · other",
                      value: [library.heif, library.jpeg, library.png, library.otherFormats].map(Self.count).joined(separator: " · ")),
        ]
        if library.outsideUserLibrary > 0 {
            rows.append(CensusRow(label: "Outside the user library", value: Self.count(library.outsideUserLibrary)))
        }
        var notes = ["Camera photos are photos that are neither screen captures nor likely received. Shares of screenshots and other subtypes are of photos."]
        notes.append(access == .limited
            ? "Limited access: only the photos and videos shared with Lahza are counted."
            : "Hidden album left out; iCloud Shared Library included (decision 14).")
        return CensusSection(id: "library", title: "Library", rows: rows, notes: notes)
    }

    private var locationSection: CensusSection {
        let located = location.photosLocated
        let rows = [
            CensusRow(label: "Photos with GPS", value: Self.share(located, of: location.photos)),
            CensusRow(label: "Camera photos with GPS", value: Self.share(location.cameraPhotosLocated, of: location.cameraPhotos)),
            CensusRow(label: "Videos with GPS", value: Self.share(location.videosLocated, of: location.videos)),
            CensusRow(label: "Accuracy ≤10 m", value: Self.share(location.within10m, of: located)),
            CensusRow(label: "Accuracy ≤100 m", value: Self.share(location.within100m, of: located)),
            CensusRow(label: "Accuracy >100 m", value: Self.share(location.over100m, of: located)),
            CensusRow(label: "Accuracy unknown", value: Self.share(location.accuracyUnknown, of: located)),
        ]
        return CensusSection(id: "location", title: "Location", rows: rows, notes: [
            "Accuracy shares are of located photos. Positions are read in memory to count and group; none are kept or shown.",
        ])
    }

    private var receivedSection: CensusSection {
        var rows = [
            CensusRow(label: "Likely received photos", value: Self.share(received.likelyPhotos, of: library.photos)),
            CensusRow(label: "Likely received videos", value: Self.share(received.likelyVideos, of: library.videos)),
        ]
        if received.filenamesRead {
            rows += [
                CensusRow(label: "Named like WhatsApp", value: Self.count(received.namedWhatsApp)),
                CensusRow(label: "Named like Telegram", value: Self.count(received.namedTelegram)),
                CensusRow(label: "Named like other messaging apps", value: Self.count(received.namedOtherMessaging)),
                CensusRow(label: "Named like a camera", value: Self.count(received.namedCamera)),
                CensusRow(label: "Named like a screenshot", value: Self.count(received.namedScreenshot)),
                CensusRow(label: "Other names", value: Self.count(received.namedUnknown)),
            ]
        }
        rows += [
            CensusRow(label: "No GPS at a messaging size", value: Self.count(received.unlocatedAtMessagingSize)),
            CensusRow(label: "…and added about when created (or added date unknown)", value: Self.count(received.shapeMatches)),
        ]
        if received.filenamesRead {
            rows += [
                CensusRow(label: "Messaging-named photos the shape rule catches",
                          value: "\(Self.count(received.namedMessagingPhotosMatchingShape)) of \(Self.count(received.namedMessagingPhotos))"),
                CensusRow(label: "Shape matches named like a camera", value: Self.count(received.shapeMatchesNamedCamera)),
            ]
        }
        if !received.unlocatedLongSides.isEmpty {
            rows.append(CensusRow(label: "Common long sides without GPS",
                                  value: received.unlocatedLongSides.map { "\($0.side) px ×\(Self.count($0.count))" }.joined(separator: " · ")))
        }
        let sorted = LibraryCensus.messagingLongSides.sorted().map(String.init)
        let sides = sorted.dropLast().joined(separator: ", ") + " or " + (sorted.last ?? "")
        var notes = [
            "Likely received: named like a messaging app, or the shape rule: a photo with no GPS, not a screen capture, with a long side of \(sides) px, added within \(Int(LibraryCensus.receivedAddedWithin / 60)) min of its creation date (or with no added date).",
        ]
        notes.append(received.filenamesRead
            ? "Filenames are read only to pick a hint; no name is kept or shown. iOS gives images saved by apps camera-style names, so names undercount received photos."
            : "The filename pass didn't run, so received counts use the shape rule only.")
        return CensusSection(id: "received", title: "Received", rows: rows, notes: notes)
    }

    private var datesSection: CensusSection {
        var rows = [
            CensusRow(label: "With a creation date", value: Self.share(dates.dated, of: library.total)),
            CensusRow(label: "No creation date", value: Self.count(dates.missing)),
            CensusRow(label: "Before 2000", value: Self.count(dates.before2000)),
            CensusRow(label: "In the future", value: Self.count(dates.inFuture)),
        ]
        if let earliest = dates.earliestYear, let latest = dates.latestYear {
            rows.append(CensusRow(label: "Years", value: earliest == latest ? "\(earliest)" : "\(earliest)–\(latest)"))
        }
        rows += [
            CensusRow(label: "Added date known", value: Self.share(dates.addedKnown, of: library.total)),
            CensusRow(label: "Added within \(Int(LibraryCensus.receivedAddedWithin / 60)) min of creation", value: Self.count(dates.addedNearCreation)),
            CensusRow(label: "Added a day or more after creation", value: Self.count(dates.addedDayOrMoreLater)),
            CensusRow(label: "Added before creation", value: Self.count(dates.addedBeforeCreation)),
        ]
        return CensusSection(id: "dates", title: "Dates", rows: rows, notes: [
            "“In the future” means more than a day after this run. The added date is PhotoKit’s (iOS 26 and later), from the device that added the photo.",
        ])
    }

    private var yearsSection: CensusSection {
        CensusSection(id: "years", title: "By year",
                      rows: dates.perYear.map { CensusRow(label: String($0.year), value: Self.count($0.count)) }, notes: [])
    }

    private var duplicatesSection: CensusSection {
        let rows = [
            CensusRow(label: "Likely duplicate groups (estimate)", value: Self.count(duplicates.groups)),
            CensusRow(label: "Likely extra copies", value: Self.share(duplicates.extraCopies, of: library.total)),
            CensusRow(label: "Largest group", value: Self.count(duplicates.largestGroup)),
            CensusRow(label: "Groups that are all likely received", value: Self.count(duplicates.receivedGroups)),
            CensusRow(label: "Burst stacks", value: Self.count(duplicates.burstStacks)),
            CensusRow(label: "Burst frames picked out", value: Self.count(duplicates.burstPicks)),
            CensusRow(label: "Frames inside stacks", value: duplicates.extraBurstFrames.map(Self.count) ?? "Not counted"),
        ]
        return CensusSection(id: "duplicates", title: "Duplicates and bursts", rows: rows, notes: [
            "An estimate: a likely duplicate shares its kind, creation second and pixel size with another item. Different photos saved together from a chat can match too, so groups that are all likely received are counted apart.",
            "Bursts are left out and counted on their own. Frames inside stacks are counted, never read.",
        ])
    }

    private var thumbnailsSection: CensusSection {
        guard let probe = thumbnails else {
            return CensusSection(id: "thumbnails", title: "Thumbnails (sample)", rows: [], notes: ["The thumbnail sample didn't run."])
        }
        var rows = [
            CensusRow(label: "Sampled photos", value: "\(Self.count(probe.sampled)) of \(Self.count(probe.requested)) asked, at random"),
            CensusRow(label: "Usable (local, ≥\(ThumbnailProbe.minimumShortSide) px)",
                      value: "\(Self.share(probe.usable, of: probe.sampled)) ±\(Self.margin(probe.usable, of: probe.sampled))"),
            CensusRow(label: "Too small", value: Self.share(probe.tooSmall, of: probe.sampled)),
            CensusRow(label: "iCloud only", value: Self.share(probe.cloudOnly, of: probe.sampled)),
            CensusRow(label: "No image", value: Self.share(probe.failed, of: probe.sampled)),
            CensusRow(label: "Pending (not usable)", value: Self.share(probe.pending, of: probe.sampled)),
        ]
        if probe.degraded > 0 { rows.append(CensusRow(label: "Degraded results", value: Self.count(probe.degraded))) }
        rows.append(CensusRow(label: "Time", value: "\(Self.seconds(probe.totalSeconds)) · median \(Self.milliseconds(probe.medianMilliseconds)) · p95 \(Self.milliseconds(probe.p95Milliseconds))"))
        return CensusSection(id: "thumbnails", title: "Thumbnails (sample)", rows: rows, notes: [
            "Each photo was asked for a \(ThumbnailProbe.requestSide) px thumbnail with network access off, so nothing was downloaded. ± is the 95% margin for the sample.",
        ])
    }

    private var videoSection: CensusSection {
        let rows = [
            CensusRow(label: "Videos", value: Self.count(video.count)),
            CensusRow(label: "Total length", value: Self.hours(video.totalSeconds)),
            CensusRow(label: "Up to 10 min", value: Self.share(video.upTo10Minutes, of: video.count)),
            CensusRow(label: "Median length", value: Self.seconds(video.medianSeconds)),
            CensusRow(label: "Screen recordings", value: Self.count(video.screenRecordings)),
            CensusRow(label: "Slo-mo", value: Self.count(video.sloMo)),
            CensusRow(label: "Time-lapse", value: Self.count(video.timeLapses)),
        ]
        return CensusSection(id: "video", title: "Video", rows: rows, notes: [
            "Decision 13: frames are sampled for local videos up to 10 minutes.",
        ])
    }

    private var momentsSection: CensusSection {
        let rows = [
            CensusRow(label: "Moments", value: Self.count(moments.count)),
            CensusRow(label: "Photos and videos grouped", value: Self.count(moments.items)),
            CensusRow(label: "Median size", value: Self.count(moments.medianSize)),
            CensusRow(label: "Largest", value: Self.count(moments.largest)),
            CensusRow(label: "Single-item moments", value: Self.share(moments.singleItem, of: moments.count)),
            CensusRow(label: "Splits: gap · jump · day break",
                      value: [moments.splitsByGap, moments.splitsByJump, moments.splitsByDayBreak].map(Self.count).joined(separator: " · ")),
        ]
        return CensusSection(id: "moments", title: "Moments (rough)", rows: rows, notes: [
            "A new moment starts after a gap of more than 90 min, a jump of more than 1 km, or at 04:00. Rough: spike S8 checks the rule against hand-labelled moments.",
            "PhotoKit doesn't expose the time zone a photo was taken in, so 04:00 is in this iPhone's current time zone for every photo.",
        ])
    }

    private var speedSection: CensusSection {
        var rows: [CensusRow] = []
        if let seconds = speed.metadataSeconds {
            rows.append(CensusRow(label: "Metadata pass", value: Self.timing(seconds, per30k: speed.metadataSecondsPer30k)))
        }
        if let seconds = speed.filenamesSeconds {
            rows.append(CensusRow(label: "Filename pass", value: Self.timing(seconds, per30k: speed.filenamesSecondsPer30k)))
        }
        if let seconds = speed.thumbnailsSeconds { rows.append(CensusRow(label: "Thumbnail sample", value: Self.seconds(seconds))) }
        if let seconds = speed.totalSeconds { rows.append(CensusRow(label: "Whole census", value: Self.seconds(seconds))) }
        var notes = ["The plan assumes about a minute per 30,000 photos for the metadata pass."]
        if device.isSimulator || source != CensusSourceName.photoKit {
            notes.append("Not a real iPhone library: timings are not comparable.")
        }
        if speed.interrupted {
            notes.append("Lahza left the foreground during the run, so these times include that pause and the speed isn't judged.")
        }
        return CensusSection(id: "speed", title: "Speed", rows: rows, notes: notes)
    }

    private var deviceSection: CensusSection {
        let rows = [
            CensusRow(label: "Model", value: device.isSimulator ? "\(device.model) (Simulator)" : device.model),
            CensusRow(label: "System", value: device.system),
            CensusRow(label: "Memory", value: String(format: "%.1f GB", Double(device.memoryBytes) / 1_073_741_824)),
            CensusRow(label: "Lahza", value: device.appVersion),
            CensusRow(label: "Source", value: source),
            CensusRow(label: "Access", value: Self.accessName(access)),
            CensusRow(label: "Run", value: runDay),
        ]
        return CensusSection(id: "device", title: "Device", rows: rows, notes: [])
    }

    private var unavailableSection: CensusSection {
        CensusSection(id: "unavailable", title: "Not measured", rows: [], notes: unavailable)
    }

    // MARK: Formatting

    private static let numberLocale = Locale(identifier: "en_US")

    static func count(_ value: Int) -> String { value.formatted(.number.locale(numberLocale)) }

    /// "72.4%" ("–" of nothing).
    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "–" }
        return String(format: "%.1f%%", Double(part) / Double(whole) * 100)
    }

    /// "1,234 (9.9%)".
    static func share(_ part: Int, of whole: Int) -> String {
        whole > 0 ? "\(count(part)) (\(percent(part, of: whole)))" : count(part)
    }

    /// The 95 % margin of a sampled share, in points: "3.3%".
    static func margin(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "–" }
        let p = Double(part) / Double(whole)
        return String(format: "%.1f%%", 1.96 * (p * (1 - p) / Double(whole)).squareRoot() * 100)
    }

    /// ": too few to judge" under ``LibraryCensus/markMinimumSample``.
    static func tooFew(_ sample: Int) -> String {
        sample < LibraryCensus.markMinimumSample ? ": too few to judge" : ""
    }

    static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f s", value) : String(format: "%.0f s", value)
    }

    static func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }

    static func hours(_ seconds: Double) -> String {
        seconds < 3_600 ? String(format: "%.0f min", seconds / 60) : String(format: "%.1f h", seconds / 3_600)
    }

    static func timing(_ seconds: Double, per30k: Double?) -> String {
        guard let per30k else { return self.seconds(seconds) }
        return "\(self.seconds(seconds)) (\(self.seconds(per30k)) per 30,000)"
    }

    static func accessName(_ access: PhotoAccess) -> String {
        switch access {
        case .full: "full access"
        case .limited: "limited access"
        default: "no access"
        }
    }

    static func label(_ verdict: CensusVerdict, pass: String, fail: String) -> String {
        switch verdict {
        case .pass: pass
        case .fail, .flag: fail
        case .unavailable: "n/a"
        }
    }
}

