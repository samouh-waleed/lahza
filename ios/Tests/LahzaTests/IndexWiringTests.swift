import Foundation
import LZCore
import LZGeo
import LZIndex
import LZLibrary
import Testing
@testable import Lahza

/// The search index in the app: its routes, the DEBUG launch arguments, and the index following photo access,
/// Delete index and the scene phase over the fake seed library and an in-memory index.
@MainActor @Suite struct IndexWiringTests {
    private func app(access: PhotoAccess, network: FakeNetworkStatus = FakeNetworkStatus(reachable: true)) -> (AppModel, FakePhotoLibraryClient) {
        var dependencies = AppDependencies.testHost()
        let photos = FakePhotoLibraryClient(access: access, answer: .full, counts: [.full: 561, .limited: 40])
        dependencies.photoLibrary = photos
        dependencies.libraryReader = FakeLibraryReader(.seed(.hero), following: photos)
        dependencies.maps = SeedMaps.client()
        dependencies.mapsPerMinute = 60_000
        dependencies.network = network
        dependencies.deviceTimeZone = { TimeZone(identifier: "Asia/Riyadh")! }
        AppPreferences(kv: dependencies.kv).markOnboardingCompleted(at: Date())
        return (AppModel(dependencies: dependencies), photos)
    }

    /// Waits up to 5 s for `condition`, letting the index settle between checks.
    private func eventually(_ app: AppModel, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            await app.index.settled()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Routes

    @Test func indexRoutesOpenOnTheirTabs() {
        let (app, _) = app(access: .denied)
        app.start()
        #expect(Route(debugName: "search-index") == .searchIndex)
        #expect(Route(debugName: "saved-places") == .savedPlaces)
        #expect(Route.savedPlaces.tab == .settings && Route.savedPlaces.presentation == .push)
        #expect(Route(debugName: "index-inspector") == .indexInspector)
        #expect(Route(debugName: "moment") == nil, "moments need a key: not deep-linkable")
        app.open(.searchIndex)
        #expect(app.router.selectedTab == .settings)
        #expect(app.router.path(for: .settings) == [.searchIndex])

        let moment = Route.moment(MomentRef(key: MomentKey(day: 20_000, startUTC: 1_728_000_000), origin: .moments))
        #expect(moment.debugName == "moment")
        app.open(moment)
        #expect(app.router.selectedTab == .moments)
        #expect(app.router.path(for: .moments) == [moment])
        let trip = Route.trip(TripRef(startDay: 19_540, origin: .ask))
        app.open(trip)
        #expect(app.router.selectedTab == .ask)
        #expect(app.router.path(for: .ask) == [trip])
    }

    // MARK: Launch arguments

    @Test func theSeedArgumentServesTheHeroLibraryWithoutPhotoKit() {
        let launch = DebugLaunch.parse { ["LZSeed": "hero", "LZIndexPace": "200", "LZNow": "2026-10-28T12:00:00+03:00", "LZFakeMaps": "1"][$0] }
        #expect(launch.seed == "hero")
        #expect(launch.indexPace == 200)
        #expect(launch.now == Date(timeIntervalSince1970: 1_793_178_000))
        #expect(launch.fakeMaps == .on)
        var dependencies = AppDependencies.live()
        launch.apply(to: &dependencies)
        #expect(dependencies.label == "debug:seed-hero+maps-on+pace-200+now")
        #expect(dependencies.libraryReader is FakeLibraryReader)
        #expect(dependencies.libraryReader.access() == .full, "the seed implies full access")
        #expect(dependencies.photoLibrary.currentAccess() == .full)
        #expect(dependencies.maps is FakeMapsClient)
        #expect(dependencies.images is FakeAssetImageProvider)
        #expect(dependencies.indexLocation == .inMemory)
        #expect(dependencies.mapsPerMinute == 600)
        #expect(dependencies.indexSettings.pacePerBatch == .milliseconds(200))
        #expect(dependencies.clock is OffsetClock)
        #expect(abs(dependencies.clock.now.timeIntervalSince1970 - 1_793_178_000) < 5)

        var limited = AppDependencies.live()
        DebugLaunch.parse { ["LZSeed": "hero", "LZPhotos": "limited"][$0] }.apply(to: &limited)
        #expect(limited.libraryReader.access() == .limited)
        #expect(limited.label == "debug:seed-hero-limited")
    }

    @Test func indexAndMapsArgumentsParse() {
        #expect(DebugLaunch.parse { $0 == "LZIndex" ? "memory" : nil }.index == .memory)
        #expect(DebugLaunch.parse { $0 == "LZIndex" ? "Reset" : nil }.index == .reset)
        #expect(DebugLaunch.parse { $0 == "LZFakeMaps" ? "offline" : nil }.fakeMaps == .offline)
        #expect(DebugLaunch.parse { $0 == "LZFakeMaps" ? "throttle" : nil }.fakeMaps == .throttle)
        #expect(DebugLaunch.parse { $0 == "LZNow" ? "yesterday" : nil }.now == nil)
        var offline = AppDependencies.live()
        DebugLaunch.parse { ["LZFakeMaps": "offline", "LZIndex": "reset"][$0] }.apply(to: &offline)
        #expect(!offline.network.isReachable)
        #expect(offline.resetIndexOnLaunch)
        #expect(offline.libraryReader is LiveLibraryReader, "fake Apple Maps over real PhotoKit")
        var photos = AppDependencies.live()
        DebugLaunch.parse { $0 == "LZPhotos" ? "full" : nil }.apply(to: &photos)
        #expect(photos.libraryReader is FakeLibraryReader)
        #expect(photos.indexLocation == .inMemory, "a fake library never writes over the real index")
    }

    // MARK: The index follows the app

    @Test func grantingAccessBuildsTheIndexAndRevokingPurgesIt() async {
        let (app, photos) = app(access: .notDetermined)
        app.start()
        #expect(await eventually(app) { app.index.status.phase == .off(.noAccess) })
        await app.photoAccess.request()
        #expect(await eventually(app) { app.index.status.phase == .ready })
        #expect(app.index.status.summary?.assets == 561)
        #expect(app.index.status.summary?.trips == 6)
        #expect(app.index.reader != nil)

        photos.setAccess(.denied)
        await app.refreshPhotoAccess().value
        #expect(await eventually(app) { app.index.status.phase == .off(.noAccess) })
        #expect(app.index.reader == nil)
    }

    @Test func limitedAccessIndexesTheSharedPhotosOnly() async {
        let (app, _) = app(access: .limited)
        app.start()
        #expect(await eventually(app) { app.index.status.phase == .ready })
        #expect(app.index.status.summary?.assets == 40)
        #expect(app.index.status.isLimited)
    }

    @Test func deleteIndexStaysOffUntilBuiltAgain() async {
        let (app, _) = app(access: .full)
        app.start()
        #expect(await eventually(app) { app.index.status.phase == .ready })
        await app.index.deleteIndex()
        #expect(app.index.status.phase == .off(.deletedByUser))
        #expect(IndexCopy.value(app.index.status) == "Off")
        app.index.buildAgain()
        #expect(await eventually(app) { app.index.status.phase == .ready })
    }

    @Test func goingToTheBackgroundPausesTheIndexAndPlaceNames() async {
        let network = FakeNetworkStatus(reachable: false)
        let (app, _) = app(access: .full, network: network)
        app.start()
        app.scenePhaseChanged(.active)
        #expect(await eventually(app) { app.index.status.phase == .ready && app.index.status.placeNames.state == .waitingForNetwork })
        #expect(IndexCopy.placeNames(app.index.status.placeNames) == "Waiting for internet")

        app.scenePhaseChanged(.inactive)
        app.scenePhaseChanged(.background)
        #expect(await eventually(app) { app.index.status.phase == .paused })
        #expect(app.index.status.placeNames.state == .backgrounded)
        #expect(IndexCopy.placeNames(app.index.status.placeNames) == "Continues when Lahza is open")

        network.setReachable(true)
        app.scenePhaseChanged(.inactive)
        app.scenePhaseChanged(.active)
        #expect(await eventually(app) { app.index.status.placeNames.state == .done })
        #expect(app.index.status.phase == .ready)
        #expect(app.index.status.placeNames.named > 0)
    }

    @Test func aMemoryWarningReleasesCaches() async {
        let (app, _) = app(access: .denied)
        let images = app.images as? FakeAssetImageProvider
        images?.startCaching(["seed/0001"], side: 64)
        app.didReceiveMemoryWarning()
        #expect(images?.cachedIDs.isEmpty == true)
    }
}
