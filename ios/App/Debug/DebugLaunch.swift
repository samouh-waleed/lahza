import DDBilling
import DDCore
import Foundation

/// DEBUG launch arguments for review and screenshots. Release builds ignore them all.
///
///     xcrun simctl launch <device> com.waleedsamouh.lahza -LZRoute paywall -LZFakeStore 1
///
/// | argument                  | effect                                                          |
/// |---------------------------|-----------------------------------------------------------------|
/// | `-LZFreshInstall 1`       | in-memory storage, so onboarding shows and nothing is remembered |
/// | `-LZSkipOnboarding 1`     | in-memory storage with onboarding already done                   |
/// | `-LZFakeStore 1`          | a fake store with sample prices (no RevenueCat; in-memory storage) |
/// | `-LZRoute <name>`         | opens a route once launch settles (see ``Route/debugName``)      |
/// | `-LZTheme light\|dark`    | forces an appearance                                             |
/// | `-LZReduceMotion 1`       | forces Reduce Motion                                             |
/// | `-LZReduceTransparency 1` | forces Reduce Transparency                                       |
struct DebugLaunch {
    var freshInstall = false
    var skipOnboarding = false
    var fakeStore = false
    var route: Route?
    var theme: AppearanceMode?
    var reduceMotion = false
    var reduceTransparency = false

    static var current: DebugLaunch {
        #if DEBUG
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool { ["1", "yes", "true"].contains(defaults.string(forKey: key)?.lowercased() ?? "") }
        return DebugLaunch(
            freshInstall: flag("LZFreshInstall"),
            skipOnboarding: flag("LZSkipOnboarding"),
            fakeStore: flag("LZFakeStore"),
            route: defaults.string(forKey: "LZRoute").flatMap(Route.init(debugName:)),
            theme: defaults.string(forKey: "LZTheme").flatMap(AppearanceMode.init(rawValue:)),
            reduceMotion: flag("LZReduceMotion"),
            reduceTransparency: flag("LZReduceTransparency")
        )
        #else
        DebugLaunch()
        #endif
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
        if let route { dependencies.initialRoute = route }
        if let theme { dependencies.appearanceOverride = theme }
        if !labels.isEmpty { dependencies.label = "debug:" + labels.joined(separator: "+") }
    }
}
