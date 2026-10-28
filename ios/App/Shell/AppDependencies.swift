import LZBilling
import LZCore
import Foundation
import LZGeo
import LZIndex
import LZLibrary
import UIKit

/// Everything the composition root needs from the outside world. `live()` is production;
/// `testHost()` is inert for the app-hosted unit tests; DEBUG launch arguments
/// (``DebugLaunch``) adjust the live set for review and screenshots.
struct AppDependencies {
    /// A short name for logs ("live", "test-host", "debug:fake-store").
    var label: String
    var environment: AppEnvironment
    /// The device kv store (`UserDefaults.standard` in production).
    var kv: any KeyValueStore
    var clock: any AppClock
    var purchases: any PurchasesClient
    var billingEnvironment: BillingEnvironment
    var photoLibrary: any PhotoLibraryClient
    /// Shows the system picker for the limited selection and returns when it closes.
    var presentLimitedLibraryPicker: @MainActor () async -> Void
    /// What the search index reads (PhotoKit; a fake library under `-LZPhotos`, `-LZSeed` and in tests).
    var libraryReader: any LibraryReader
    /// Thumbnails and screen-size images, never from the network.
    var images: any AssetImageProvider
    /// Apple Maps (place names, and later place search).
    var maps: any MapsClient
    /// Apple Maps requests a minute, shared by place naming and search.
    var mapsPerMinute = 30
    var network: any NetworkStatus
    var indexLocation: IndexLocation = .applicationSupport
    /// Destroy the on-disk index before opening it (DEBUG `-LZIndex reset`).
    var resetIndexOnLaunch = false
    /// The zone photos without a position fall back to.
    var deviceTimeZone: @Sendable () -> TimeZone = { .current }
    var indexSettings = IndexerSettings()
    #if DEBUG
    /// DEBUG: what Settings › Developer › Library census reads (PhotoKit; the fake library under
    /// `-LZPhotos` and in tests).
    var censusSource: any CensusSource = LiveCensusSource()
    #endif
    /// Start launch from the model's `init` (false for the unit-test host).
    var autoBoot = true
    /// DEBUG: a route opened once launch settles (`-LZRoute`).
    var initialRoute: Route?
    /// DEBUG: forces an appearance (`-LZTheme light|dark`).
    var appearanceOverride: AppearanceMode?

    /// Production.
    static func live() -> AppDependencies {
        let environment = AppEnvironment()
        return AppDependencies(
            label: "live",
            environment: environment,
            kv: UserDefaultsKeyValueStore(defaults: .standard),
            clock: SystemClock(),
            purchases: RevenueCatPurchasesClient(),
            billingEnvironment: BillingEnvironment(environment),
            photoLibrary: LivePhotoLibraryClient(),
            presentLimitedLibraryPicker: { await LimitedLibraryPicker.present() },
            libraryReader: LiveLibraryReader(),
            images: LiveAssetImageProvider(),
            maps: LiveMapsClient(),
            network: LiveNetworkStatus()
        )
    }

    /// The app-hosted unit tests' host: nothing boots, nothing touches the network, the real
    /// defaults or the photo library. The index is in memory over an empty fake library.
    static func testHost() -> AppDependencies {
        var dependencies = live()
        dependencies.label = "test-host"
        dependencies.kv = InMemoryKeyValueStore([:])
        dependencies.purchases = FakePurchasesClient()
        dependencies.billingEnvironment = BillingEnvironment(apiKey: "test_host", configuration: .debug)
        let photos = FakePhotoLibraryClient(access: .notDetermined)
        dependencies.photoLibrary = photos
        dependencies.presentLimitedLibraryPicker = {}
        dependencies.libraryReader = FakeLibraryReader(.empty, following: photos)
        dependencies.images = FakeAssetImageProvider()
        dependencies.maps = FakeMapsClient(.empty)
        dependencies.network = FakeNetworkStatus(reachable: false)
        dependencies.indexLocation = .inMemory
        #if DEBUG
        dependencies.censusSource = FakeCensusSource(library: photos, pace: .zero)
        #endif
        dependencies.autoBoot = false
        return dependencies
    }

    /// Which set this launch uses: the inert test host under XCTest, otherwise production with any
    /// DEBUG launch arguments applied.
    static func resolve() -> AppDependencies {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return testHost() }
        var dependencies = live()
        #if DEBUG
        DebugLaunch.current.apply(to: &dependencies)
        #endif
        return dependencies
    }

    /// The purchase service for this set.
    func makePurchasesService() -> PurchasesService {
        PurchasesService(client: purchases, environment: billingEnvironment, clock: clock)
    }

    /// What the search index needs from this set.
    func makeIndexDependencies(gazetteer: Gazetteer?, budget: MapsBudget) -> IndexDependencies {
        let photoLibrary = photoLibrary
        return IndexDependencies(location: indexLocation, reader: libraryReader, gazetteer: gazetteer, maps: maps, budget: budget, clock: clock,
                                 network: network, kv: kv, deviceTimeZone: deviceTimeZone, changes: { photoLibrary.changes() },
                                 settings: indexSettings, resetOnLaunch: resetIndexOnLaunch,
                                 isProtectedDataAvailable: { UIApplication.shared.isProtectedDataAvailable })
    }
}
