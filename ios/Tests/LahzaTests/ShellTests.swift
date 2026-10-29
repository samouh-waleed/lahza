import LZBilling
import LZCore
import Foundation
import LZLibrary
import Testing
@testable import Lahza

@MainActor @Suite struct ShellTests {
    private static let allRoutes: [Route] = [.ask, .moments, .settings, .photoAccess, .appearance, .privacy, .fullLibrary, .acknowledgements, .searchIndex,
                                             .savedPlaces, .paywall, .onboarding] + Route.developerRoutes

    private func model(onboarded: Bool = false, photos: FakePhotoLibraryClient? = nil) -> AppModel {
        var dependencies = AppDependencies.testHost()
        if onboarded { AppPreferences(kv: dependencies.kv).markOnboardingCompleted(at: Date()) }
        if let photos {
            dependencies.photoLibrary = photos
            // The census and the index read the same fake library, as under `-LZPhotos`.
            dependencies.censusSource = FakeCensusSource(library: photos, pace: .zero)
            dependencies.libraryReader = FakeLibraryReader(.empty, following: photos)
        }
        dependencies.autoBoot = false
        return AppModel(dependencies: dependencies)
    }

    @Test func rootFollowsLaunchAndOnboarding() {
        let app = model()
        #expect(app.root == .launching)
        app.start()
        #expect(app.root == .onboarding)
        app.completeOnboarding()
        #expect(app.root == .tabs)
        #expect(AppPreferences(kv: app.dependencies.kv).onboardingCompleted)
    }

    @Test func returningLaunchGoesStraightToTheTabs() {
        let app = model(onboarded: true)
        app.start()
        #expect(app.root == .tabs)
    }

    @Test func routesOpenTheWayTheirPresentationSays() {
        let app = model(onboarded: true)
        app.start()
        app.open(.appearance)
        #expect(app.router.selectedTab == .settings)
        #expect(app.router.path(for: .settings) == [.appearance])
        app.open(.paywall)
        #expect(app.router.modals.map(\.route) == [.paywall])
        #expect(app.router.modals.first?.fullScreen == true)
        app.open(.paywall)
        #expect(app.router.modals.count == 1)
        app.open(.ask)
        #expect(app.router.selectedTab == .ask)
        #expect(app.router.modals.isEmpty)
    }

    @Test func reselectingATabPopsToItsRoot() {
        let router = AppRouter()
        router.push(.privacy)
        #expect(router.selectedTab == .settings)
        router.userSelected(.settings)
        #expect(router.path(for: .settings).isEmpty)
    }

    @Test func appearanceIsRememberedOnTheDevice() {
        let app = model()
        #expect(app.appearance == .system)
        #expect(app.preferredColorScheme == nil)
        app.setAppearance(.dark)
        #expect(app.preferredColorScheme == .dark)
        #expect(AppPreferences(kv: app.dependencies.kv).appearance == .dark)
        app.setAppearance(.system)
        #expect(AppPreferences(kv: app.dependencies.kv).appearance == .system)
    }

    @Test func everyDebugRouteNameRoundTrips() {
        for route in Self.allRoutes {
            #expect(Route(debugName: route.debugName) == route)
        }
        #expect(Route(debugName: "photo-access") == .photoAccess)
        #expect(Route(debugName: "nope") == nil)
    }

    @Test func photoAccessIsPushedOnTheSettingsTab() {
        #expect(Route.photoAccess.tab == .settings)
        #expect(Route.photoAccess.presentation == .push)
        let app = model(onboarded: true)
        app.start()
        app.open(.photoAccess)
        #expect(app.router.selectedTab == .settings)
        #expect(app.router.path(for: .settings) == [.photoAccess])
    }

    @Test func noRouteIsLeftWithoutATabOrAModal() {
        for route in Self.allRoutes {
            switch route.presentation {
            case .tabRoot, .push: #expect(route.tab != nil)
            case .sheet, .fullScreen: #expect(route.tab == nil)
            }
        }
    }

    // MARK: Photo access

    @Test func photoAccessIsOnboardingsLastStep() {
        #expect(OnboardingView.Step.allCases.last == .photos)
        #expect(OnboardingView.Step.allCases.count == 3)
    }

    @Test func finishingOnboardingAsksOnceAndAcceptsAnyAnswer() async {
        let photos = FakePhotoLibraryClient(access: .notDetermined, answer: .denied)
        let app = model(photos: photos)
        app.start()
        #expect(app.root == .onboarding)
        await app.finishOnboarding()
        #expect(photos.prompts == 1)
        #expect(app.photoAccess.access == .denied)
        #expect(app.root == .tabs)
    }

    @Test func finishingOnboardingWithAccessDecidedDoesNotAsk() async {
        let photos = FakePhotoLibraryClient(access: .limited)
        let app = model(photos: photos)
        app.start()
        await app.finishOnboarding()
        #expect(!photos.calls.contains(.requestAccess))
        #expect(app.root == .tabs)
    }

    @Test func launchNeverAsksForPhotoAccess() async {
        let photos = FakePhotoLibraryClient(access: .notDetermined)
        let app = model(onboarded: true, photos: photos)
        app.start()
        await app.photoRefresh?.value
        #expect(app.photoAccess.access == .notDetermined)
        #expect(!photos.calls.contains(.requestAccess))
        #expect(!photos.calls.contains(.readableCount))
    }

    @Test func returningToTheForegroundRereadsPhotoAccess() async {
        let photos = FakePhotoLibraryClient(access: .denied)
        let app = model(onboarded: true, photos: photos)
        app.start()
        let launch = app.photoRefresh
        // The scene's first activation does not count again: launch already did.
        app.scenePhaseChanged(.active)
        #expect(app.photoRefresh == launch)
        await app.photoRefresh?.value
        #expect(app.photoAccess.access == .denied)

        // The person turns on limited access in iPhone Settings and comes back.
        app.scenePhaseChanged(.inactive)
        app.scenePhaseChanged(.background)
        photos.setAccess(.limited)
        app.scenePhaseChanged(.inactive)
        app.scenePhaseChanged(.active)
        #expect(app.photoRefresh != launch)
        await app.photoRefresh?.value
        #expect(app.photoAccess.access == .limited)
        #expect(app.photoAccess.readableCount == 36)

        // A blip that never leaves the app (the iOS prompt, Control Center) does not recount.
        let settingsTrip = app.photoRefresh
        app.scenePhaseChanged(.inactive)
        app.scenePhaseChanged(.active)
        #expect(app.photoRefresh == settingsTrip)
    }

    @Test func choosingLimitedPhotosRecounts() async {
        let photos = FakePhotoLibraryClient(access: .limited)
        var dependencies = AppDependencies.testHost()
        dependencies.photoLibrary = photos
        dependencies.presentLimitedLibraryPicker = { photos.setCount(40, for: .limited) }
        let app = AppModel(dependencies: dependencies)
        await app.chooseLimitedPhotos()
        #expect(app.photoAccess.readableCount == 40)
    }

    @Test func photoCountsFollowTheRegion() {
        let us = Locale(identifier: "en_US")
        #expect(PhotoAccessCopy.photosAndVideos(12_480, locale: us) == "12,480 photos and videos")
        #expect(PhotoAccessCopy.photosAndVideos(12_480, locale: Locale(identifier: "de_DE")) == "12.480 photos and videos")
        #expect(PhotoAccessCopy.photosAndVideos(1, locale: us) == "1 photo or video")
        #expect(PhotoAccessCopy.shared(1_036, locale: us) == "You’ve shared 1,036 photos and videos")
        #expect(PhotoAccessCopy.shared(1, locale: us) == "You’ve shared 1 photo or video")
        #expect(PhotoAccessCopy.shared(0, locale: us) == "You haven’t shared any photos yet")
        #expect(PhotoAccessCopy.cardTitle(.full, count: 0) == "Your photo library is empty")
        #expect(PhotoAccess.allCases.map(PhotoAccessCopy.status) == ["Not set", "Restricted", "Off", "Limited", "Full"])
    }

    @Test func debugPhotosArgumentSwapsInTheFakeLibrary() async throws {
        #expect(DebugLaunch.parse { _ in nil }.photos == nil)
        #expect(DebugLaunch.parse { $0 == "LZPhotos" ? "NotDetermined" : nil }.photos == .notDetermined)
        #expect(DebugLaunch.parse { $0 == "LZPhotos" ? "everything" : nil }.photos == nil)

        let launch = DebugLaunch.parse { $0 == "LZPhotos" ? "denied" : nil }
        #expect(launch.photos == .denied)
        var dependencies = AppDependencies.live()
        #expect(dependencies.censusSource is LiveCensusSource)
        launch.apply(to: &dependencies)
        #expect(dependencies.label == "debug:photos-denied")
        #expect(dependencies.photoLibrary is FakePhotoLibraryClient)
        #expect(dependencies.photoLibrary.currentAccess() == .denied)
        // The library census reads the same fake library: denied stops it, limited counts the 36 shared.
        #expect(dependencies.censusSource is FakeCensusSource)
        #expect(dependencies.censusSource.name == CensusSourceName.sample)
        let denied = CensusRunner(source: dependencies.censusSource)
        await denied.run()
        #expect(denied.phase == .failed(.noAccess))

        var limitedDependencies = AppDependencies.live()
        DebugLaunch.parse { $0 == "LZPhotos" ? "limited" : nil }.apply(to: &limitedDependencies)
        let limited = CensusRunner(source: limitedDependencies.censusSource)
        await limited.run()
        let report = try #require(limited.report)
        let library = try #require(limitedDependencies.photoLibrary as? FakePhotoLibraryClient)
        #expect(report.access == .limited)
        #expect(report.library.total == library.count(for: .limited))
        #expect(report.library.total == 36)
    }

    // MARK: Library census (DEBUG)

    @Test func libraryCensusIsADebugRouteOnTheSettingsTab() {
        #expect(Route.developerRoutes == [.libraryCensus, .indexInspector, .lockedResults])
        #expect(Route(debugName: "locked-results") == .lockedResults)
        #expect(Route.libraryCensus.debugName == "library-census")
        #expect(Route(debugName: "library-census") == .libraryCensus)
        #expect(Route.libraryCensus.tab == .settings)
        #expect(Route.libraryCensus.presentation == .push)
        let app = model(onboarded: true)
        app.start()
        app.open(.libraryCensus)
        #expect(app.router.selectedTab == .settings)
        #expect(app.router.path(for: .settings) == [.libraryCensus])
    }

    @Test func theTestHostCensusReadsTheFakeLibrary() async {
        // Without photo access the census stops before reading anything.
        let app = model(onboarded: true)
        #expect(app.dependencies.censusSource is FakeCensusSource)
        #expect(app.censusRunner.sourceName == CensusSourceName.sample)
        await app.censusRunner.run()
        #expect(app.censusRunner.phase == .failed(.noAccess))
    }

    @Test func theCensusRunsOverTheFakeLibraryWithAccess() async throws {
        let app = model(photos: FakePhotoLibraryClient(access: .full))
        await app.censusRunner.run()
        let report = try #require(app.censusRunner.report)
        #expect(report.library.total == 12_480)
        #expect(report.marks.count == 4)
        #expect(LibraryCensusCopy.resultsCaption(report).hasPrefix("Sample library · full access · "))
    }

    @Test func goingToTheBackgroundMarksTheCensusTimings() async throws {
        let photos = FakePhotoLibraryClient(access: .full)
        var dependencies = AppDependencies.testHost()
        dependencies.photoLibrary = photos
        dependencies.censusSource = FakeCensusSource(library: photos, pace: .milliseconds(1))
        let app = AppModel(dependencies: dependencies)
        let run = app.censusRunner.start()
        app.scenePhaseChanged(.background)
        await run.value
        let report = try #require(app.censusRunner.report)
        #expect(report.speed.interrupted)
        #expect(report.verdicts.metadataSpeed == .unavailable)
    }

    @Test func stoppedRunsSayWhenThePreviousResultsRemain() {
        #expect(LibraryCensusCopy.cancelled(previous: false) == "Census cancelled. Nothing was kept.")
        #expect(LibraryCensusCopy.cancelled(previous: true).hasSuffix("The results below are from the previous run."))
        #expect(LibraryCensusCopy.failed(.mismatchedScan, previous: true).hasSuffix("The results below are from the previous run."))
    }
}
