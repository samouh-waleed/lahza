import Foundation
import Testing
@testable import LZLibrary

/// The census rules on synthetic facts: filename hints, located shares, the received heuristic,
/// duplicates, dates, moments, the S2 marks and what the shared report may contain.
@Suite struct LibraryCensusTests {
    // MARK: Filename hints

    private static let names: [String?] = [
        "IMG-20231005-WA0003.jpg", "VID-20231005-WA0012.mp4", "PTT-20240101-WA0001.opus", "WhatsApp Image 2023-10-05 at 14.32.11.jpeg",
        "photo_2023-10-05_14-32-11.jpg", "video_2023-10-05 14.32.11.mp4", "telegram-cloud-photo-size-2-5427.jpg",
        "signal-2023-10-05-143211.jpg", "received_1234567890123456.jpeg", "FB_IMG_1696500000000.jpg", "mmexport1696500000000.jpg",
        "IMG_1234.HEIC", "IMG_E1234.JPG", "IMG_1234.MOV", "PXL_20231005_143211123.jpg", "DSC_0042.JPG",
        "IMG_1234.PNG", "Screenshot 2023-10-05 at 14.32.11.png", "RPReplay_Final1696500000.MP4",
        "holiday.jpg", "IMG-2023-WA.jpg", "IMG_1234.gif", "", nil,
    ]
    private static let hints: [FilenameHint] = [
        .whatsapp, .whatsapp, .whatsapp, .whatsapp,
        .telegram, .telegram, .telegram,
        .otherMessaging, .otherMessaging, .otherMessaging, .otherMessaging,
        .camera, .camera, .camera, .camera, .camera,
        .screenshot, .screenshot, .screenshot,
        .unknown, .unknown, .unknown, .unknown, .unknown,
    ]

    @Test(arguments: zip(names, hints))
    func classifiesFilenames(_ name: String?, _ hint: FilenameHint) {
        #expect(FilenameHint(filename: name) == hint)
    }

    @Test func onlyMessagingHintsCountAsReceived() {
        #expect(FilenameHint.allCases.filter(\.isMessaging) == [.whatsapp, .telegram, .otherMessaging])
    }

    // MARK: Library and video

    @Test func libraryCountsKindsSubtypesFormatsAndFavorites() {
        let facts = [
            photo(subtypes: .screenshot, width: 1179, height: 2556, hint: .screenshot),
            photo(subtypes: [.livePhoto, .hdr]),
            with(photo(subtypes: .panorama, width: 12_000, height: 3_000)) { $0.format = .jpeg },
            with(photo(subtypes: .depthEffect)) { $0.isFavorite = true },
            with(photo()) { $0.format = .png },
            with(photo()) { $0.format = .gif },
            with(photo()) { $0.format = nil },
            with(photo()) { $0.source = .cloudShared },
            with(video()) { $0.isFavorite = true },
            AssetFacts(kind: .other),
        ]
        let library = report(facts).library
        #expect(library.total == 10)
        #expect(library.photos == 8)
        #expect(library.videos == 1)
        #expect(library.other == 1)
        let subtypes: [Int] = [library.screenshots, library.livePhotos, library.panoramas, library.hdr, library.portrait]
        #expect(subtypes == [1, 1, 1, 1, 1])
        let formats: [Int] = [library.heif, library.jpeg, library.png, library.otherFormats]
        #expect(formats == [4, 1, 1, 2])
        #expect(library.favorites == 2)
        // Every photo but the screenshot is a camera-style photo.
        #expect(library.cameraPhotos == 7)
        #expect(library.outsideUserLibrary == 1)
    }

    @Test func videosUpTo10MinutesIncludeExactly10() {
        let facts = [
            with(video()) { $0.duration = 599; $0.subtypes = .sloMo },
            with(video()) { $0.duration = 600; $0.subtypes = .timeLapse },
            with(video()) { $0.duration = 601; $0.subtypes = .screenRecording },
            photo(),
        ]
        let video = report(facts).video
        #expect(video.count == 3)
        #expect(video.totalSeconds == 1_800)
        #expect(video.upTo10Minutes == 2)
        #expect(video.medianSeconds == 600)
        let subtypes: [Int] = [video.screenRecordings, video.sloMo, video.timeLapses]
        #expect(subtypes == [1, 1, 1])
    }

    // MARK: Location

    @Test func locatedSharesAndAccuracyBuckets() {
        let facts = [
            photo(at: home, accuracy: 5), photo(at: home, accuracy: 50), photo(at: home, accuracy: 500), photo(at: home, accuracy: nil),
            photo(),
            // (0, 0) is what some apps write without a position: not located.
            photo(at: Coordinate(latitude: 0, longitude: 0)),
            photo(subtypes: .screenshot, width: 1179, height: 2556, hint: .screenshot),
            photo(width: 1600, height: 1200, hint: .whatsapp),
            photo(width: 1280, height: 960),
            video(at: home), video(),
        ]
        let location = report(facts).location
        #expect(location.photos == 9)
        #expect(location.photosLocated == 4)
        // Screenshots and likely-received photos are not camera photos.
        #expect(location.cameraPhotos == 6)
        #expect(location.cameraPhotosLocated == 4)
        let buckets: [Int] = [location.within10m, location.within100m, location.over100m, location.accuracyUnknown]
        #expect(buckets == [1, 1, 1, 1])
        #expect(location.videos == 2)
        #expect(location.videosLocated == 1)
    }

    @Test func distanceIsInMetres() {
        let north = Coordinate(latitude: home.latitude + 0.0108, longitude: home.longitude)
        #expect(abs(home.distance(to: north) - 1_201) < 5)
        #expect(Coordinate(latitude: 91, longitude: 0).isValid == false)
    }

    // MARK: Received

    @Test func theShapeRuleNeedsNoGPSAMessagingSizeAndAFreshAddedDate() {
        let base = photo(width: 1600, height: 1200)
        #expect(LibraryCensus.matchesReceivedShape(base))
        #expect(LibraryCensus.matchesReceivedShape(with(base) { $0.pixelWidth = 1200; $0.pixelHeight = 1600 }))
        #expect(LibraryCensus.matchesReceivedShape(with(base) { $0.addedDate = nil }), "an unknown added date doesn't rule it out")
        #expect(!LibraryCensus.matchesReceivedShape(with(base) { $0.coordinate = home }))
        #expect(!LibraryCensus.matchesReceivedShape(with(base) { $0.subtypes = .screenshot }))
        #expect(!LibraryCensus.matchesReceivedShape(with(base) { $0.filenameHint = .screenshot }))
        #expect(!LibraryCensus.matchesReceivedShape(with(base) { $0.pixelWidth = 4032; $0.pixelHeight = 3024 }))
        #expect(!LibraryCensus.matchesReceivedShape(with(base) { $0.addedDate = $0.creationDate?.addingTimeInterval(3 * 86_400) }))
        #expect(!LibraryCensus.matchesReceivedShape(with(base) { $0.kind = .video }))
        // A messaging name is enough, GPS or not.
        let named = photo(at: home, hint: .whatsapp)
        #expect(!LibraryCensus.matchesReceivedShape(named))
        #expect(LibraryCensus.isLikelyReceived(named))
        #expect(!LibraryCensus.isCameraPhoto(named))
    }

    @Test func receivedCountsCompareNamesWithTheShapeRule() {
        let facts = [
            photo(width: 1600, height: 1200, hint: .whatsapp),             // named and shaped
            photo(at: home, width: 1600, height: 1200, hint: .telegram),   // named, has GPS
            photo(width: 1280, height: 960),                               // shaped, camera-style name
            photo(width: 2560, height: 1440, added: 5 * 86_400),           // messaging size, added much later
            photo(width: 1600, height: 900, hint: .unknown),               // shaped, unknown name
            photo(),                                                       // camera photo without GPS
            video(hint: .whatsapp), video(),
        ]
        let received = report(facts).received
        #expect(received.filenamesRead)
        #expect(received.likelyPhotos == 4)
        #expect(received.likelyVideos == 1)
        #expect(received.namedWhatsApp == 2)
        #expect(received.namedTelegram == 1)
        #expect(received.namedCamera == 4)
        #expect(received.namedUnknown == 1)
        #expect(received.unlocatedAtMessagingSize == 4)
        #expect(received.shapeMatches == 3)
        #expect(received.namedMessagingPhotos == 2)
        #expect(received.namedMessagingPhotosMatchingShape == 1)
        #expect(received.shapeMatchesNamedCamera == 1)
        #expect(received.unlocatedLongSides.first == CensusReport.SideCount(side: 1600, count: 2))
    }

    @Test func withoutTheFilenamePassReceivedUsesTheShapeRuleOnly() {
        let facts = [photo(width: 1600, height: 1200, hint: nil), photo(hint: nil)]
        let report = report(facts)
        #expect(!report.received.filenamesRead)
        #expect(report.received.likelyPhotos == 1)
        #expect(report.text.contains("The filename pass didn't run"))
    }

    // MARK: Duplicates and bursts

    @Test func duplicatesShareKindSecondAndSizeAndLeaveBurstsOut() {
        let second = "2023-10-05T14:32:11Z"
        let facts = [
            photo(second), photo(second, offset: 0.4), photo(second, offset: 0.9),        // one group of three
            photo(second, width: 3024, height: 4032),                                   // another size
            video(second, width: 4032, height: 3024),                                   // another kind
            photo(second, offset: 1),                                                   // the next second
            photo("2023-10-06T08:00:00Z", burst: true, representative: true),
            photo("2023-10-06T08:00:00Z", burst: true),                                 // a pick from that burst
            photo(nil), photo(nil),                                                     // undated twins
        ]
        let duplicates = report(facts, extraBurstFrames: 17).duplicates
        #expect(duplicates.groups == 1)
        #expect(duplicates.extraCopies == 2)
        #expect(duplicates.largestGroup == 3)
        #expect(duplicates.burstAssets == 2)
        #expect(duplicates.burstStacks == 1)
        #expect(duplicates.burstPicks == 1)
        #expect(duplicates.extraBurstFrames == 17)
        #expect(duplicates.receivedGroups == 0)
    }

    @Test func duplicatesAreAnEstimateThatCountsChatSavesApart() {
        // Two different chat images saved in the same second at the same size look like copies.
        let second = "2023-10-05T14:32:11Z"
        let facts = [
            photo(second, width: 1600, height: 1200), photo(second, offset: 0.5, width: 1600, height: 1200),
            photo(second), photo(second, offset: 0.2),
        ]
        let report = report(facts)
        #expect(report.duplicates.groups == 2)
        #expect(report.duplicates.receivedGroups == 1)
        #expect(report.text.contains("Likely duplicate groups (estimate): 2"))
        #expect(report.text.contains("Groups that are all likely received: 1"))
    }

    // MARK: Dates

    @Test func dateAnomaliesAndYears() {
        let facts = [
            photo(nil), photo(nil),
            photo("1998-06-01T12:00:00Z", added: 20 * 365 * 86_400),
            photo("2019-03-14T15:09:26Z"), photo("2019-07-01T10:00:00Z", added: -3_600),
            photo("2023-10-05T14:32:11Z"),
            photo("2026-10-29T09:00:01Z"),                       // more than a day after the run
            photo("2026-10-27T10:00:00Z"),                       // an hour after the run: a clock slip
        ]
        let dates = report(facts).dates
        #expect(dates.dated == 6)
        #expect(dates.missing == 2)
        #expect(dates.before2000 == 1)
        #expect(dates.inFuture == 1)
        #expect(dates.earliestYear == 1998)
        #expect(dates.latestYear == 2026)
        #expect(dates.perYear.map(\.year) == [1998, 2019, 2023, 2026])
        #expect(dates.perYear.map(\.count) == [1, 2, 1, 2])
        #expect(dates.addedKnown == 6)
        #expect(dates.addedNearCreation == 4)
        #expect(dates.addedDayOrMoreLater == 1)
        #expect(dates.addedBeforeCreation == 1)
    }

    // MARK: Moments

    @Test func momentsSplitOnGapsJumpsAndTheDayBreak() {
        let north = Coordinate(latitude: home.latitude + 0.0108, longitude: home.longitude)     // 1.2 km from home
        let nearby = Coordinate(latitude: north.latitude + 0.0045, longitude: north.longitude)  // 0.5 km from north
        let facts = [
            photo("2023-10-05T10:00:00Z", at: home), photo("2023-10-05T10:30:00Z", at: home),
            photo("2023-10-05T11:59:00Z"),                                      // 89 min: same moment
            photo("2023-10-05T13:31:00Z", at: home),                            // 92 min: gap
            photo("2023-10-05T13:40:00Z", at: north),                           // 1.2 km: jump
            photo("2023-10-05T13:50:00Z"),                                      // no GPS: never splits
            photo("2023-10-05T14:00:00Z", at: nearby),                          // 0.5 km: same moment
            photo("2023-10-06T03:00:00Z"), photo("2023-10-06T03:50:00Z"),       // a gap, then 50 min
            photo("2023-10-06T04:10:00Z"),                                      // 20 min, but past 04:00: day break
            video("2023-10-07T23:30:00Z"), photo("2023-10-08T00:30:00Z"),       // midnight doesn't split
        ]
        let moments = report(facts.shuffled()).moments
        #expect(moments.items == 12)
        #expect(moments.count == 6)
        #expect(moments.splitsByGap == 3)
        #expect(moments.splitsByJump == 1)
        #expect(moments.splitsByDayBreak == 1)
        #expect(moments.singleItem == 2)
        #expect(moments.largest == 3)
        #expect(moments.medianSize == 2)
    }

    @Test func theDayBreakIsAt04LocalTime() {
        // Riyadh is UTC+3: 00:50Z is 03:50 there and 01:10Z is 04:10, so the day breaks between them,
        // while 00:30Z and 00:50Z (03:30 and 03:50) stay together.
        let riyadh = calendar("Asia/Riyadh")
        let night = [photo("2023-10-05T00:30:00Z"), photo("2023-10-05T00:50:00Z"), photo("2023-10-05T01:10:00Z")]
        let moments = LibraryCensus.moments(night, calendar: riyadh)
        #expect(moments.count == 2)
        #expect(moments.splitsByDayBreak == 1)
        #expect(moments.largest == 2)
    }

    @Test func theDayBreakStaysAt04OnDaylightSavingDays() {
        let berlin = calendar("Europe/Berlin")
        // Clocks go forward at 02:00 on 29 March 2026: 03:30 and 04:30 local are an hour apart, across 04:00.
        let spring = [photo("2026-03-29T01:30:00Z"), photo("2026-03-29T02:30:00Z")]
        #expect(LibraryCensus.moments(spring, calendar: berlin).splitsByDayBreak == 1)
        // Clocks go back at 03:00 on 25 October 2026: 02:50 and 03:30 local are both before 04:00.
        let autumn = [photo("2026-10-25T01:50:00Z"), photo("2026-10-25T02:30:00Z")]
        #expect(LibraryCensus.moments(autumn, calendar: berlin).count == 1)
    }

    // MARK: S2 marks

    @Test(arguments: [(255, CensusVerdict.pass), (254, .fail)])
    func usableThumbnailsPassAt85Percent(_ usable: Int, _ verdict: CensusVerdict) {
        #expect(LibraryCensus.verdicts(reportWith(thumbnails: probe(usable: usable, cloudOnly: 300 - usable))).usableThumbnails == verdict)
    }

    @Test(arguments: [(30, CensusVerdict.pass), (31, .flag)])
    func pendingCloudFlagsOver10Percent(_ pending: Int, _ verdict: CensusVerdict) {
        #expect(LibraryCensus.verdicts(reportWith(thumbnails: probe(usable: 300 - pending, cloudOnly: pending))).pendingCloud == verdict)
    }

    @Test(arguments: [(70, CensusVerdict.pass), (69, .flag)])
    func placeSignalIsOKFrom70Percent(_ located: Int, _ verdict: CensusVerdict) {
        // A miss moves the place visual signature up: a plan change, flagged rather than failed.
        var report = reportWith()
        report.location.cameraPhotos = 100
        report.location.cameraPhotosLocated = located
        report.verdicts = LibraryCensus.verdicts(report)
        #expect(report.verdicts.placeSignal == verdict)
        #expect(report.marks.first { $0.id == "place" }?.label == (verdict == .pass ? "OK" : "Weak"))
    }

    @Test func marksNeedEnoughPhotos() {
        // 99 sampled photos or camera photos can't pass or fail a plan, whatever they show.
        var report = reportWith(thumbnails: probe(usable: 50, cloudOnly: 49))
        report.location.cameraPhotos = 99
        report.location.cameraPhotosLocated = 10
        let verdicts = LibraryCensus.verdicts(report)
        #expect(verdicts.usableThumbnails == .unavailable)
        #expect(verdicts.pendingCloud == .unavailable)
        #expect(verdicts.placeSignal == .unavailable)
        #expect(report.marks.first { $0.id == "thumbnails" }?.value.hasSuffix("too few to judge") == true)
        #expect(report.marks.first { $0.id == "place" }?.value.hasSuffix("too few to judge") == true)
    }

    @Test(arguments: [(60.0, CensusVerdict.pass), (61.0, .flag)])
    func metadataSpeedAgainstThePlan(_ perThirtyThousand: Double, _ verdict: CensusVerdict) {
        var report = reportWith(source: CensusSourceName.photoKit)
        report.library.total = 1_000
        report.speed.metadataSecondsPer30k = perThirtyThousand
        #expect(LibraryCensus.verdicts(report).metadataSpeed == verdict)
    }

    @Test func speedIsNotJudgedOnATinyLibrary() {
        // Six photos scaled to 30,000 says nothing: the fetch's fixed cost dominates.
        var report = reportWith(source: CensusSourceName.photoKit)
        report.library.total = 999
        report.speed.metadataSecondsPer30k = 313
        #expect(LibraryCensus.verdicts(report).metadataSpeed == .unavailable)
    }

    @Test func speedIsJudgedOnlyOnARealIPhoneRunThatStayedOpen() {
        var real = reportWith(source: CensusSourceName.photoKit)
        real.library.total = 30_000
        real.speed.metadataSecondsPer30k = 40
        #expect(LibraryCensus.verdicts(real).metadataSpeed == .pass)

        var sample = real
        sample.source = CensusSourceName.sample
        var simulator = real
        simulator.device.isSimulator = true
        var interrupted = real
        interrupted.speed.interrupted = true
        for report in [sample, simulator, interrupted] {
            #expect(LibraryCensus.verdicts(report).metadataSpeed == .unavailable)
        }
        #expect(interrupted.text.contains("Lahza left the foreground during the run"))
    }

    @Test func marksAreUnavailableWithoutData() {
        let verdicts = LibraryCensus.verdicts(reportWith())
        #expect(verdicts == CensusReport.Verdicts())
        #expect(reportWith().marks.allSatisfy { $0.label == "n/a" })
    }

    @Test func speedScalesTo30000() {
        let speed = LibraryCensus.speed(CensusTimings(metadata: .seconds(15), filenames: .seconds(30)), assets: 15_000)
        #expect(speed.metadataSecondsPer30k == 30)
        #expect(speed.filenamesSecondsPer30k == 60)
    }

    // MARK: Thumbnails

    @Test func thumbnailOutcomes() {
        #expect(ThumbnailOutcome(width: 224, height: 300, isInCloud: false) == .usable)
        #expect(ThumbnailOutcome(width: 300, height: 223, isInCloud: false) == .tooSmall)
        // An image wins over the in-cloud flag; no image is iCloud only or a failure.
        #expect(ThumbnailOutcome(width: 256, height: 341, isInCloud: true) == .usable)
        #expect(ThumbnailOutcome(width: nil, height: nil, isInCloud: true) == .cloudOnly)
        #expect(ThumbnailOutcome(width: 0, height: 0, isInCloud: false) == .failed)
    }

    @Test func thumbnailTallyCountsAndTimes() {
        var tally = ThumbnailTally(requested: 300)
        for milliseconds in 1...20 { tally.add(.usable, duration: .milliseconds(milliseconds)) }
        tally.add(.cloudOnly, duration: .milliseconds(1))
        tally.add(.tooSmall, degraded: true, duration: .milliseconds(2))
        let probe = tally.result(total: .seconds(2))
        #expect(probe.requested == 300)
        #expect(probe.sampled == 22)
        #expect(probe.usable == 20)
        #expect(probe.pending == 2)
        #expect(probe.degraded == 1)
        #expect(probe.totalSeconds == 2)
        // Nearest rank over 1, 1, 2, 2, 3 … 20.
        #expect(probe.medianMilliseconds == 9)
        #expect(probe.p95Milliseconds == 19)
    }

    // MARK: The report

    @Test func theReportHoldsNoFilenameCoordinateOrExactDate() throws {
        // Distinctive values that must never reach the report.
        let place = Coordinate(latitude: 51.501364, longitude: -0.141890)
        let facts = [
            photo("2019-03-14T15:09:26Z", at: place, hint: .camera),
            photo("2021-08-02T07:45:13Z", at: place, hint: .whatsapp),
            photo("2022-12-31T23:59:58Z", width: 1600, height: 1200),
            video("2020-02-29T12:34:56Z", at: place),
        ]
        let report = report(facts, thumbnails: probe(usable: 270, cloudOnly: 30))
        let text = report.text
        for leak in ["51.5013", "-0.1418", "0.14189", "2019-03-14", "2021-08-02", "2022-12-31", "2020-02-29", "15:09", "07:45", "23:59", "12:34"] {
            #expect(!text.contains(leak), "the report contains \(leak)")
        }
        // The only full date is the run's own.
        let days = text.matches(of: /\d{4}-\d{2}-\d{2}/).map { String($0.output) }
        #expect(Set(days) == ["2026-10-27"])
        #expect(text.contains("S2 MARKS"))
        #expect(text.contains("[PASS] Usable local thumbnails: 90.0% of 300 sampled photos (±3.4%)."))
        // PhotoKit has no capture time zone: the report says so instead of guessing.
        #expect(text.contains("Capture time zone: PhotoKit doesn't expose it"))
        for title in ["LIBRARY", "LOCATION", "RECEIVED", "DATES", "BY YEAR", "DUPLICATES AND BURSTS", "THUMBNAILS (SAMPLE)", "VIDEO",
                      "MOMENTS (ROUGH)", "SPEED", "DEVICE", "NOT MEASURED", "JSON"] {
            #expect(text.contains("\n\(title)\n"), "missing section \(title)")
        }
    }

    @Test func theReportRoundTripsThroughJSON() throws {
        let original = report([photo(at: home), photo(width: 1600, height: 1200), video()], thumbnails: probe(usable: 9, cloudOnly: 1))
        let json = try #require(original.json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CensusReport.self, from: Data(json.utf8))
        #expect(decoded == original)
        #expect(decoded.format == CensusReport.currentFormat)
    }

    @Test func theRunDayFollowsTheIPhonesCalendar() {
        // 00:07 UTC on the 28th is still the evening of the 27th in California.
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let late = date("2026-10-28T00:07:00Z")
        #expect(LibraryCensus.day(late, calendar: pacific) == "2026-10-27")
        #expect(LibraryCensus.day(late, calendar: utc) == "2026-10-28")
    }

    @Test func hintsThatDontLineUpWithTheFactsAreRefused() throws {
        let scan = CensusScan(facts: [photo(hint: nil), photo(hint: nil)], access: .full)
        #expect(throws: CensusError.mismatchedScan) { try scan.applying([.camera]) }
        #expect(throws: CensusError.mismatchedScan) { try scan.applying([.camera, .camera, .whatsapp]) }
        #expect(try scan.applying([.camera, .whatsapp]).facts.map(\.filenameHint) == [.camera, .whatsapp])
    }

    @Test func limitedAccessIsSaidInTheReport() {
        let scan = CensusScan(facts: [photo()], access: .limited)
        let report = LibraryCensus.summarize(scan, thumbnails: nil, timings: CensusTimings(), context: context)
        #expect(report.access == .limited)
        #expect(report.text.contains("Limited access: only the photos and videos shared with Lahza are counted."))
        #expect(report.text.contains("The thumbnail sample didn't run."))
    }

    // MARK: Helpers

    private let home = Coordinate(latitude: 24.7136, longitude: 46.6753)

    private var utc: Calendar { calendar("UTC") }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }

    private var context: CensusContext {
        CensusContext(sourceName: "Test", device: DeviceInfo(model: "iPhone17,1", system: "iOS 27.1", memoryBytes: 8_589_934_592, appVersion: "0.1.0 (1)", isSimulator: false),
                      generatedAt: date("2026-10-27T09:00:00Z"), calendar: utc)
    }

    private func date(_ iso: String) -> Date {
        (try? Date(iso, strategy: .iso8601)) ?? .distantPast
    }

    /// A camera-style photo, unlocated unless `at` is given, added two seconds after it was taken
    /// (`added` changes that gap).
    private func photo(_ iso: String? = "2023-10-05T14:32:11Z", offset: TimeInterval = 0, at place: Coordinate? = nil, accuracy: Double? = 5,
                       subtypes: AssetFacts.Subtypes = [], width: Int = 4032, height: Int = 3024, added: TimeInterval = 2,
                       hint: FilenameHint? = .camera, burst: Bool = false, representative: Bool = false) -> AssetFacts {
        let created = iso.map { date($0).addingTimeInterval(offset) }
        return AssetFacts(kind: .photo, subtypes: subtypes, format: .heif, creationDate: created, addedDate: created?.addingTimeInterval(added),
                          coordinate: place, horizontalAccuracy: place == nil ? nil : accuracy, hasBurstIdentifier: burst,
                          representsBurst: representative, pixelWidth: width, pixelHeight: height, filenameHint: hint)
    }

    private func video(_ iso: String = "2023-10-05T14:32:11Z", at place: Coordinate? = nil, width: Int = 1920, height: Int = 1080,
                       hint: FilenameHint = .camera) -> AssetFacts {
        AssetFacts(kind: .video, creationDate: date(iso), addedDate: date(iso).addingTimeInterval(30), coordinate: place,
                   horizontalAccuracy: place == nil ? nil : 8, duration: 30, pixelWidth: width, pixelHeight: height, filenameHint: hint)
    }

    private func with(_ facts: AssetFacts, _ change: (inout AssetFacts) -> Void) -> AssetFacts {
        var facts = facts
        change(&facts)
        return facts
    }

    private func report(_ facts: [AssetFacts], thumbnails: ThumbnailProbe? = nil, extraBurstFrames: Int? = nil) -> CensusReport {
        LibraryCensus.summarize(CensusScan(facts: facts, access: .full, extraBurstFrames: extraBurstFrames), thumbnails: thumbnails,
                                timings: CensusTimings(metadata: .seconds(1)), context: context)
    }

    private func reportWith(thumbnails: ThumbnailProbe? = nil, source: String = "Test") -> CensusReport {
        var report = CensusReport(generatedAt: date("2026-10-27T09:00:00Z"), runDay: "2026-10-27", source: source, access: .full, device: context.device)
        report.thumbnails = thumbnails
        return report
    }

    private func probe(usable: Int, cloudOnly: Int) -> ThumbnailProbe {
        var tally = ThumbnailTally(requested: usable + cloudOnly)
        for _ in 0..<usable { tally.add(.usable, duration: .milliseconds(10)) }
        for _ in 0..<cloudOnly { tally.add(.cloudOnly, duration: .milliseconds(2)) }
        return tally.result(total: .seconds(3))
    }
}
