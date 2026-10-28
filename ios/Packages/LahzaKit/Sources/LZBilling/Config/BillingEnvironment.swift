import LZCore
import Foundation

/// Public SDK configuration only. Secret RevenueCat keys never belong in a client.
public enum RevenueCatKey {
    /// A store platform. Lahza is iOS only; `android` and `other` keep the key rules complete.
    public enum Platform: String, Sendable {
        case ios
        case android
        case other
    }

    /// The SDK key for `platform`.
    ///
    /// - Returns: the trimmed key, or nil when the platform has no store or the chosen key is empty.
    ///   Explicit Test Store mode reads only `testKey` and never falls back to the live key.
    /// - Throws: ``BillingError/sdkKeyMismatch`` when the key lacks the platform's prefix (`test_`,
    ///   `appl_` or `goog_`) or has characters outside `[A-Za-z0-9_]`. The message never echoes the key.
    public static func select(
        platform: Platform,
        testStore: Bool = false,
        testKey: String? = nil,
        iosKey: String? = nil,
        androidKey: String? = nil
    ) throws(BillingError) -> String? {
        guard platform != .other else { return nil }
        let raw = testStore ? testKey : platform == .ios ? iosKey : androidKey
        guard let raw else { return nil }
        let key = trimmedKey(raw)
        guard !key.isEmpty else { return nil }
        let prefix = testStore ? "test_" : platform == .ios ? "appl_" : "goog_"
        guard key.hasPrefix(prefix), key.utf16.allSatisfy(isKeyUnit) else { throw .sdkKeyMismatch }
        return key
    }

    /// Whether `identifier` is `expected` exactly, or `expected + ":"` + a base plan (the
    /// Google Play form; App Store product ids cannot contain `:`, so on iOS this is an exact match).
    public static func matchesStoreProduct(_ identifier: String, _ expected: String) -> Bool {
        identifier == expected || identifier.hasPrefix(expected + ":")
    }

    /// `/^[a-zA-Z0-9_]+$/` on one UTF-16 code unit.
    private static func isKeyUnit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F
    }
}

/// A configured key without the surrounding whitespace and newlines a pasted value can carry.
func trimmedKey(_ string: String) -> String {
    string.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The billing view of the build configuration (``AppEnvironment``): SDK key, offering, entitlement,
/// Test Store mode and the legal links.
public struct BillingEnvironment: Sendable, Equatable {
    /// The configured RevenueCat key (``AppEnvironment/revenueCatAPIKey``; a `test_` key is already
    /// dropped in release builds).
    public var apiKey: String?
    /// Explicit Test Store mode (``AppEnvironment/InfoKey/revenueCatTestStore``).
    public var explicitTestStore: Bool
    /// The RevenueCat offering id (default ``Brand/Products/offering``, `default`).
    public var offeringIdentifier: String
    /// The RevenueCat entitlement id (default ``Brand/plusEntitlement``, `lahza_plus`).
    public var entitlementIdentifier: String
    /// The web URL + `/terms`.
    public var termsURL: URL
    /// The web URL + `/privacy`.
    public var privacyURL: URL
    /// The build configuration. The Test Store exists only in debug builds.
    public var configuration: AppEnvironment.Configuration

    public init(
        apiKey: String?,
        explicitTestStore: Bool = false,
        offeringIdentifier: String = Brand.Products.offering,
        entitlementIdentifier: String = Brand.plusEntitlement,
        termsURL: URL = LegalLinks.productionTerms,
        privacyURL: URL = LegalLinks.productionPrivacy,
        configuration: AppEnvironment.Configuration = .current
    ) {
        self.apiKey = apiKey
        self.explicitTestStore = explicitTestStore
        self.configuration = configuration
        self.offeringIdentifier = offeringIdentifier
        self.entitlementIdentifier = entitlementIdentifier
        self.termsURL = termsURL
        self.privacyURL = privacyURL
    }

    /// Reads the build environment. Terms and Privacy are always present: the configured web URL,
    /// else the production site.
    public init(_ environment: AppEnvironment) {
        self.init(
            apiKey: environment.revenueCatAPIKey,
            explicitTestStore: environment.revenueCatTestStore,
            offeringIdentifier: environment.revenueCatOffering,
            entitlementIdentifier: environment.revenueCatEntitlement,
            termsURL: environment.termsURL ?? LegalLinks.productionTerms,
            privacyURL: environment.privacyURL ?? LegalLinks.productionPrivacy,
            configuration: environment.configuration
        )
    }

    /// Test Store mode, **debug builds only**: the explicit switch, or a `test_` key (the single
    /// ``AppEnvironment/InfoKey/revenueCatAPIKey`` slot may hold the Test Store key in debug). A
    /// release build is never in Test Store mode, so it never shows "Test purchases only. No money
    /// will be charged."
    public var usesTestStore: Bool {
        configuration == .debug && (explicitTestStore || apiKey.map { trimmedKey($0).hasPrefix("test_") } == true)
    }

    /// The SDK key to configure with, through ``RevenueCatKey/select(platform:testStore:testKey:iosKey:androidKey:)``
    /// for iOS: in Test Store mode only a `test_` key, otherwise only an `appl_` key. Nil means billing
    /// is not connected in this build: a release build with explicit Test Store mode on (it never
    /// falls back to the live key, and the Test Store cannot run in release, where RevenueCat
    /// terminates the app), or a release build whose key slot held a Test Store key.
    public func sdkKey() throws(BillingError) -> String? {
        if configuration == .release && explicitTestStore { return nil }
        let test = usesTestStore
        return try RevenueCatKey.select(platform: .ios, testStore: test, testKey: test ? apiKey : nil, iosKey: test ? nil : apiKey)
    }
}

/// The legal pages every paywall links to.
public enum LegalLinks {
    /// ``Brand/websiteURL`` + `/terms`.
    public static let productionTerms = link("/terms")
    /// ``Brand/websiteURL`` + `/privacy`.
    public static let productionPrivacy = link("/privacy")

    private static func link(_ path: String) -> URL {
        // `Brand.websiteURL` is a constant, valid https origin; the fallback only satisfies the type
        // checker without a force unwrap.
        URL(string: Brand.websiteURL + path) ?? URL(filePath: path)
    }
}
