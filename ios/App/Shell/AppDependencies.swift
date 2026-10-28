import DDBilling
import DDCore
import Foundation

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
            billingEnvironment: BillingEnvironment(environment)
        )
    }

    /// The app-hosted unit tests' host: nothing boots, nothing touches the network or the real
    /// defaults.
    static func testHost() -> AppDependencies {
        var dependencies = live()
        dependencies.label = "test-host"
        dependencies.kv = InMemoryKeyValueStore([:])
        dependencies.purchases = FakePurchasesClient()
        dependencies.billingEnvironment = BillingEnvironment(apiKey: "test_host", configuration: .debug)
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
}
