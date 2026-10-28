import DDBilling
import DDCore
import Foundation
import LZLibrary

/// DEBUG launch arguments for review and screenshots. Release builds ignore them all.
///
///     xcrun simctl launch <device> com.waleedsamouh.lahza -LZRoute paywall -LZFakeStore 1
///
/// | argument                  | effect                                                          |
/// |---------------------------|-----------------------------------------------------------------|
/// | `-LZFreshInstall 1`       | in-memory storage, so onboarding shows and nothing is remembered |
/// | `-LZSkipOnboarding 1`     | in-memory storage with onboarding already done                   |
/// | `-LZFakeStore 1`          | a fake store with sample prices (no RevenueCat; in-memory storage) |
/// | `-LZPhotos <access>`      | a fake photo library starting at that access (see below)         |
/// | `-LZRoute <name>`         | opens a route once launch settles (see ``Route/debugName``)      |
/// | `-LZTheme light\|dark`    | forces an appearance                                             |
/// | `-LZReduceMotion 1`       | forces Reduce Motion                                             |
/// | `-LZReduceTransparency 1` | forces Reduce Transparency                                       |
///
/// `-LZPhotos` takes `notDetermined`, `limited`, `full`, `denied` or `restricted`. The fake library
/// never touches PhotoKit: its prompt answers full, it holds 12,480 photos and videos (36 when
/// limited), and Choose photos adds 12 more. The library census (Settings › Developer) then reads a
/// synthetic library of the same size.
struct DebugLaunch {
    var freshInstall = false
    var skipOnboarding = false
    var fakeStore = false
    /// `-LZPhotos`: the fake photo library's starting access.
    var photos: PhotoAccess?
    var route: Route?
    var theme: AppearanceMode?
    var reduceMotion = false
    var reduceTransparency = false

    static var current: DebugLaunch {
        #if DEBUG
        let defaults = UserDefaults.standard
        return parse { defaults.string(forKey: $0) }
        #else
        DebugLaunch()
        #endif
    }

    /// The arguments as `value(key)` reads them (launch arguments land in `UserDefaults`).
    static func parse(_ value: (String) -> String?) -> DebugLaunch {
        func flag(_ key: String) -> Bool { ["1", "yes", "true"].contains(value(key)?.lowercased() ?? "") }
        return DebugLaunch(
            freshInstall: flag("LZFreshInstall"),
            skipOnboarding: flag("LZSkipOnboarding"),
            fakeStore: flag("LZFakeStore"),
            photos: value("LZPhotos").flatMap { name in PhotoAccess.allCases.first { $0.rawValue.lowercased() == name.lowercased() } },
            route: value("LZRoute").flatMap(Route.init(debugName:)),
            theme: value("LZTheme").flatMap(AppearanceMode.init(rawValue:)),
            reduceMotion: flag("LZReduceMotion"),
            reduceTransparency: flag("LZReduceTransparency")
        )
    }

    func apply(to dependencies: inout AppDependencies) {
        var labels: [String] = []
        if freshInstall || skipOnboarding {
            let kv = InMemoryKeyValueStore([:])
            if skipOnboarding { AppPreferences(kv: kv).markOnboardingCompleted(at: Date()) }
            dependencies.kv = kv
            labels.append(freshInstall ? "fresh-install" : "skip-onboarding")
        }
        if fakeStore {
            // Fake purchases never touch the real defaults: run on in-memory storage, carrying over
            // only whether onboarding was done.
            if !(freshInstall || skipOnboarding) {
                let kv = InMemoryKeyValueStore([:])
                if AppPreferences(kv: dependencies.kv).onboardingCompleted { AppPreferences(kv: kv).markOnboardingCompleted(at: Date()) }
                dependencies.kv = kv
            }
            dependencies.purchases = FakePurchasesClient()
            // A Test Store key, so the paywall says "Test purchases only".
            dependencies.billingEnvironment = BillingEnvironment(apiKey: "test_fake_store", configuration: .debug)
            labels.append("fake-store")
        }
        if let photos {
            let library = FakePhotoLibraryClient(access: photos, answer: .full)
            dependencies.photoLibrary = library
            // The system picker needs real PhotoKit access, so the fake "picks" a few more photos instead.
            dependencies.presentLimitedLibraryPicker = {
                library.setCount(library.count(for: .limited) + 12, for: .limited)
                library.emitChange()
            }
            #if DEBUG
            dependencies.censusSource = FakeCensusSource(library: library)
            #endif
            labels.append("photos-\(photos.rawValue)")
        }
        if let route { dependencies.initialRoute = route }
        if let theme { dependencies.appearanceOverride = theme }
        if !labels.isEmpty { dependencies.label = "debug:" + labels.joined(separator: "+") }
    }
}
