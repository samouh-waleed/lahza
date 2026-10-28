import Foundation
import LZCore
import LZGeo
import LZIndex
import LZLibrary
import Testing
@testable import Lahza

/// What the index screens show: Ask's cards by photo access and index status, the Moments tab's states, and the
/// words of rows, trips, the summary and Settings › Search index, checked against the hero seed library where it
/// has the facts (search spec §7.1–7.3, §10 PR 2 acceptance 2).
@MainActor @Suite struct IndexScreensTests {
    private static let summary = LibrarySummary(assets: 561, photos: 552, videos: 9, located: 520, moments: 225, trips: 6, countries: 5,
                                                firstYear: 2021, lastYear: 2026)

    // MARK: Ask

    @Test func askShowsTheLibraryCardWithoutAccess() {
        #expect(AskState(access: .denied, status: IndexStatus(phase: .off(.noAccess))) == .noAccess)
        #expect(AskState(access: .notDetermined, status: IndexStatus(phase: .off(.noAccess))) == .noAccess)
        // Access went away before the index heard: still the library card.
        #expect(AskState(access: .denied, status: IndexStatus(phase: .ready, summary: Self.summary)) == .noAccess)
    }

    @Test func askShowsTheIndexingCardDuringTheFirstBuildOnly() {
        let reading = IndexStatus.Phase.reading(done: 250, total: 563)
        #expect(AskState(access: .full, status: IndexStatus(phase: .preparing)) == .indexing(.preparing))
        #expect(AskState(access: .full, status: IndexStatus(phase: reading, isPartial: true)) == .indexing(reading))
        #expect(AskState(access: .full, status: IndexStatus(phase: reading, isPartial: true, summary: Self.summary)) == .indexing(reading),
                "a first build's partial summary waits for the end")
        #expect(AskState(access: .full, status: IndexStatus(phase: .organizing, isPartial: true)) == .indexing(.organizing))
        // A later rescan keeps the summary on screen.
        #expect(AskState(access: .full, status: IndexStatus(phase: reading, summary: Self.summary)) == .ready(Self.summary))
        #expect(AskState(access: .full, status: IndexStatus(phase: .paused, summary: Self.summary)) == .ready(Self.summary))
    }

    @Test func askShowsDeletedAndProblemStates() {
        #expect(AskState(access: .full, status: IndexStatus(phase: .off(.deletedByUser))) == .deleted)
        #expect(AskState(access: .full, status: IndexStatus(phase: .failed("Couldn't open the search index"))) == .unavailable("Couldn't open the search index"))
        #expect(AskState(access: .full, status: IndexStatus(phase: .failed("x"), summary: Self.summary)) == .ready(Self.summary))
        #expect(AskState(access: .full, status: IndexStatus(phase: .off(.protectedDataUnavailable))) == .unavailable("Waiting for this iPhone to be unlocked"))
    }

    @Test func theCardsSayWhatTheIndexHolds() {
        #expect(AskCopy.readProgress(done: 12_400, total: 31_204) == "\(12_400.formatted()) of \(31_204.formatted())")
        #expect(AskCopy.readProgress(done: 600, total: 563) == "563 of 563")
        #expect(AskCopy.indexingTitle(.reading(done: 1, total: 2)) == "Getting to know your library")
        #expect(AskCopy.indexingTitle(.organizing) == "Grouping your photos into moments and trips…")
        #expect(AskCopy.structure(Self.summary) == "225 moments · 6 trips · 5 countries · 2021–2026")
        #expect(AskCopy.structure(LibrarySummary(assets: 3, moments: 1, countries: 1, firstYear: 2026, lastYear: 2026)) == "1 moment · 1 country · 2026")
        #expect(AskCopy.structure(LibrarySummary(assets: 3)) == nil)
        #expect(AskCopy.located(Self.summary) == "93% have a location")
        #expect(AskCopy.located(LibrarySummary(assets: 2, located: 2)) == "All have a location")
        #expect(AskCopy.located(LibrarySummary()) == nil)
        #expect(AskCopy.assetsNoun(561, isLimited: false) == "photos & videos")
        #expect(AskCopy.assetsNoun(40, isLimited: true) == "photos & videos shared")
        #expect(AskCopy.placeNamesFootnote(PlaceNameProgress(named: 12, eligible: 47, state: .running)) == "Naming places with Apple Maps · 12 of 47")
        #expect(AskCopy.placeNamesFootnote(PlaceNameProgress(named: 47, eligible: 47, state: .done)) == nil)
        #expect(AskCopy.placeNamesFootnote(PlaceNameProgress(state: .off)) == nil)
        #expect(AskCopy.placeNamesFootnote(PlaceNameProgress(state: .waitingForNetwork)) == "Apple Maps place names are waiting for internet",
                "on Ask, say what waits")
        #expect(AskCopy.located(LibrarySummary(assets: 10_000, located: 9_996)) == "99% have a location", "never 100% before all")
    }

    // MARK: Moments

    @Test func theMomentsTabFollowsAccessAndTheIndex() {
        func state(_ access: PhotoAccess, _ status: IndexStatus, moments: Bool = false, loaded: Bool = true) -> MomentsScreenState {
            MomentsScreenState(access: access, status: status, hasMoments: moments, hasLoaded: loaded)
        }
        #expect(state(.denied, IndexStatus(phase: .off(.noAccess))) == .noAccess)
        #expect(state(.full, IndexStatus(phase: .reading(done: 50, total: 563), isPartial: true)) == .reading)
        #expect(state(.full, IndexStatus(phase: .reading(done: 300, total: 563), isPartial: true), moments: true) == .list(stillReading: true))
        #expect(state(.full, IndexStatus(phase: .ready), moments: true) == .list(stillReading: false))
        #expect(state(.full, IndexStatus(phase: .ready), loaded: false) == .reading, "built, but the first page isn't loaded yet")
        #expect(state(.full, IndexStatus(phase: .ready)) == .empty)
        #expect(state(.full, IndexStatus(phase: .off(.deletedByUser))) == .deleted)
    }

    @Test func momentWordsReadDayFirst() {
        let day = LocalTime.day(year: 2026, month: 8, day: 22)
        #expect(MomentCopy.dayTitle(day) == "Sat 22 Aug 2026")
        #expect(MomentCopy.shortDay(day) == "Sat 22 Aug")
        #expect(MomentCopy.spokenDay(day) == "Saturday 22 August 2026")
        #expect(MomentCopy.monthHeader(year: 2026, month: 10, moments: 12) == "October 2026 · 12 moments")
        #expect(MomentCopy.monthHeader(year: 2026, month: 1, moments: 1) == "January 2026 · 1 moment")
        #expect(MomentCopy.yearPill(year: 2026, moments: 44) == "2026 · 44")
        #expect(MomentCopy.counts(photos: 10, videos: 1) == "10 photos · 1 video")
        #expect(MomentCopy.counts(photos: 0, videos: 2) == "2 videos")
        #expect(MomentCopy.counts(photos: 1, videos: 0) == "1 photo")
        #expect(MomentCopy.dayRange(LocalTime.day(year: 2023, month: 7, day: 2), LocalTime.day(year: 2023, month: 7, day: 8)) == "2–8 Jul 2023")
        #expect(MomentCopy.dayRange(LocalTime.day(year: 2021, month: 12, day: 30), LocalTime.day(year: 2022, month: 1, day: 3))
                == "30 Dec 2021 – 3 Jan 2022")
        #expect(MomentCopy.dayRange(LocalTime.day(year: 2024, month: 3, day: 30), LocalTime.day(year: 2024, month: 4, day: 2)) == "30 Mar – 2 Apr 2024")
        #expect(MomentCopy.duration(42) == "0:42")
        #expect(MomentCopy.duration(3_725) == "1:02:05")
        #expect(MomentCopy.places(["Athens", "Mykonos", "Oia", "Thira", "Fira", "Ios"]) == "Athens, Mykonos, Oia, Thira +2")
        #expect(TripCard.rows(["a"]) == [["a"]])
        #expect(TripCard.rows(["a", "b"]) == [["a"], ["b"]])
        #expect(TripCard.rows(["a", "b", "c", "d"]) == [["a", "b"], ["c", "d"]])
    }

    @Test func timesAreTheMomentsOwnWithTheZoneWhenItDiffers() throws {
        let riyadh = try #require(TimeZone(identifier: "Asia/Riyadh"))
        // 22 Aug 2026, 17:00–18:40 in Riyadh (14:00 UTC).
        let start: Int64 = 1_787_407_200
        var moment = Self.moment(day: LocalTime.day(year: 2026, month: 8, day: 22), startUTC: start, zone: "Asia/Riyadh")
        moment.startWall = start + 3 * 3_600
        moment.endWall = moment.startWall + 100 * 60
        let span = MomentCopy.timeSpan(moment, locale: Locale(identifier: "en_GB"))
        #expect(span.contains("17:00") && span.contains("18:40"), "\(span)")
        #expect(MomentCopy.zoneNote(moment, deviceZone: riyadh) == nil)
        #expect(MomentCopy.zoneNote(moment, deviceZone: try #require(TimeZone(identifier: "Europe/London"))) == "Riyadh time")
        // Athens in July is on Riyadh's offset: no note.
        let athens = Self.moment(day: LocalTime.day(year: 2023, month: 7, day: 7), startUTC: 1_688_749_200, zone: "Europe/Athens")
        #expect(MomentCopy.zoneNote(athens, deviceZone: riyadh) == nil)
        let london = Self.moment(day: LocalTime.day(year: 2021, month: 12, day: 31), startUTC: 1_640_988_000, zone: "Europe/London")
        #expect(MomentCopy.zoneNote(london, deviceZone: riyadh) == "London time")
        moment.endWall = moment.startWall
        #expect(MomentCopy.timeSpan(moment, locale: Locale(identifier: "en_GB")) == "17:00")
    }

    @Test func placeLinesNameTheCountryAwayFromHome() {
        var moment = Self.moment(day: 0, startUTC: 0, zone: nil)
        moment.label = "Acropolis"
        moment.cityName = "Athens"
        moment.countryCode = "GR"
        #expect(MomentCopy.placeLine(moment, homeCountry: "SA") == "Acropolis · Athens · Greece")
        #expect(MomentCopy.placeLine(moment, homeCountry: "GR") == "Acropolis · Athens")
        moment.label = "Athens"
        #expect(MomentCopy.placeLine(moment, homeCountry: nil) == "Athens")
        moment.label = nil
        moment.cityName = nil
        #expect(MomentCopy.placeLine(moment, homeCountry: nil) == "No location")
    }

    // MARK: Settings and copy

    @Test func settingsAndPrivacyWords() {
        #expect(IndexCopy.value(IndexStatus(phase: .reading(done: 42, total: 100))) == "Reading 42%")
        #expect(IndexCopy.value(IndexStatus(phase: .reading(done: 996, total: 1_000))) == "Reading 99%", "100% only when done")
        #expect(IndexCopy.percent(1, of: 1_000) == "1%")
        #expect(IndexCopy.percent(0, of: 1_000) == "0%")
        #expect(IndexCopy.percent(563, of: 563) == "100%")
        #expect(IndexCopy.value(IndexStatus(phase: .ready)) == "Up to date")
        #expect(IndexCopy.value(IndexStatus(phase: .off(.noAccess))) == "Off")
        #expect(IndexCopy.namedValue(PlaceNameProgress(named: 340, eligible: 612)) == "340 of 612")
        #expect(IndexCopy.placeNames(PlaceNameProgress(state: .waitingForNetwork)) == "Waiting for internet")
        #expect(IndexCopy.placeNames(PlaceNameProgress(state: .backgrounded)) == "Continues when Lahza is open")
        #expect(PrivacyCopy.index.hasPrefix("Lahza keeps a search index on this iPhone"))
        #expect(PrivacyCopy.appleMaps.contains("Settings › Search index"), "the Apple Maps paragraph names the switch")
        #expect(OnboardingCopy.photosBody == "Lahza reads the dates and places of your photos on this iPhone to find moments. Place names are looked up with Apple Maps; your photos never leave your device.")
    }

    // MARK: The hero library

    @Test func theHeroLibraryReadsAsTheSpecSays() async throws {
        var dependencies = AppDependencies.testHost()
        let photos = FakePhotoLibraryClient(access: .full, answer: .full, counts: [.full: 561])
        dependencies.photoLibrary = photos
        dependencies.libraryReader = FakeLibraryReader(.seed(.hero), following: photos)
        dependencies.maps = SeedMaps.client()
        dependencies.mapsPerMinute = 60_000
        dependencies.network = FakeNetworkStatus(reachable: true)
        dependencies.deviceTimeZone = { TimeZone(identifier: "Asia/Riyadh")! }
        AppPreferences(kv: dependencies.kv).markOnboardingCompleted(at: Date())
        let app = AppModel(dependencies: dependencies)
        app.start()
        app.scenePhaseChanged(.active)
        for _ in 0..<250 where app.index.status.phase != .ready || app.index.status.placeNames.state != .done {
            await app.index.placeNamesSettled()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(app.index.status.phase == .ready)
        let summary = try #require(app.index.status.summary)
        #expect(AskState(access: .full, status: app.index.status) == .ready(summary))
        #expect(summary.assets == 561)
        #expect(AskCopy.structure(summary)?.hasSuffix("6 trips · 5 countries · 2021–2026") == true)

        let moments = app.moments
        await moments.load()
        _ = await moments.loadThrough(year: 2021)
        let nakheel = try #require(moments.moments.first { $0.key.day == LocalTime.day(year: 2026, month: 8, day: 22) && $0.photoCount == 8 })
        #expect("\(MomentCopy.dayTitle(nakheel.key.day)) · \(MomentCopy.place(nakheel)) · \(MomentCopy.counts(photos: nakheel.photoCount, videos: nakheel.videoCount))"
                == "Sat 22 Aug 2026 · Al-Nakheel Park · 8 photos")
        #expect(nakheel.thumbnailLocalIDs.count == 3)
        #expect(moments.homeCountryCode == "SA")
        #expect(moments.trips.count == 6)
        let greece = try #require(moments.trips.first { $0.label == "Greece" })
        #expect(MomentCopy.tripTitle(greece) == "Greece · 2–8 Jul 2023")
        #expect(MomentCopy.tripDates(greece) == "2–8 Jul 2023 · 7 days")
        let scenario = SeedScenario.hero
        let greeceItems = scenario.items(.greece)
        #expect(MomentCopy.tripCaption(greece).hasPrefix(MomentCopy.counts(photos: greeceItems.count { !$0.isVideo }, videos: greeceItems.count(where: \.isVideo))))
        #expect(greece.places.prefix(3) == ["Athens", "Mykonos", "Oia"])
        let oia = try #require(moments.moments.first { $0.key.day == LocalTime.day(year: 2023, month: 7, day: 7) && $0.itemCount > 5 })
        #expect(oia.label == "Oia")
        #expect(MomentCopy.placeLine(oia, homeCountry: moments.homeCountryCode).hasSuffix("Greece"))
    }

    private static func moment(day: Int32, startUTC: Int64, zone: String?) -> MomentRow {
        MomentRow(id: 1, key: MomentKey(day: day, startUTC: startUTC), endUTC: startUTC, startWall: startUTC, endWall: startUTC, timeZone: zone,
                  itemCount: 1, photoCount: 1, videoCount: 0, locatedCount: 1, borrowedCount: 0)
    }
}
