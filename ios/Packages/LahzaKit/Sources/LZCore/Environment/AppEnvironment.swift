import Foundation

/// Build-time configuration read from Info.plist, filled from xcconfig build settings.
///
/// Keys: `LZWebURL`, `LZRevenueCatAPIKey`, `LZRevenueCatEntitlement`, `LZRevenueCatOffering` and
/// `LZRevenueCatTestStore`. Empty or unsubstituted (`$(…)`) values count as unset, and a missing key
/// uses the ``Brand`` default. Flags accept `YES`/`true`/`1` and `NO`/`false`/`0` (any case).
public struct AppEnvironment: Sendable, Equatable {
    /// Debug or release behaviour.
    public enum Configuration: String, Sendable, Equatable {
        case debug
        case release

        /// The configuration this code was compiled with.
        public static var current: Configuration {
            #if DEBUG
            .debug
            #else
            .release
            #endif
        }
    }

    /// Info.plist key names.
    public enum InfoKey {
        public static let webURL = "LZWebURL"
        public static let revenueCatAPIKey = "LZRevenueCatAPIKey"
        public static let revenueCatEntitlement = "LZRevenueCatEntitlement"
        public static let revenueCatOffering = "LZRevenueCatOffering"
        public static let revenueCatTestStore = "LZRevenueCatTestStore"

        /// Every key ``AppEnvironment`` reads.
        public static let all = [webURL, revenueCatAPIKey, revenueCatEntitlement, revenueCatOffering, revenueCatTestStore]
    }

    public let configuration: Configuration
    /// The website origin without one trailing slash, else ``Brand/websiteURL``.
    public let webURLString: String
    /// Public RevenueCat SDK key (trimmed), or nil. In release a `test_` key is dropped here,
    /// because the RevenueCat SDK calls `fatalError` for Test Store keys outside DEBUG.
    public let revenueCatAPIKey: String?
    /// Entitlement id (default ``Brand/fullLibraryEntitlement``).
    public let revenueCatEntitlement: String
    /// Offering id (default ``Brand/Products/offering``).
    public let revenueCatOffering: String
    /// Explicit Test Store mode. With it on, billing uses only a `test_` key; in release the
    /// `test_` key is dropped, so billing is simply unavailable.
    public let revenueCatTestStore: Bool

    /// Builds the environment from Info.plist-style values.
    public init(info: [String: String], configuration: Configuration = .current) {
        func value(_ key: String) -> String? {
            guard let raw = info[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, !raw.hasPrefix("$(") else { return nil }
            return raw
        }
        func flag(_ key: String) -> Bool? {
            switch value(key)?.lowercased() {
            case "yes", "true", "1": true
            case "no", "false", "0": false
            default: nil
            }
        }
        let web = value(InfoKey.webURL).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        self.configuration = configuration
        webURLString = (web?.isEmpty == false ? web : nil) ?? Brand.websiteURL
        let key = value(InfoKey.revenueCatAPIKey)
        revenueCatAPIKey = (configuration == .release && key?.hasPrefix("test_") == true) ? nil : key
        revenueCatEntitlement = value(InfoKey.revenueCatEntitlement) ?? Brand.fullLibraryEntitlement
        revenueCatOffering = value(InfoKey.revenueCatOffering) ?? Brand.Products.offering
        revenueCatTestStore = flag(InfoKey.revenueCatTestStore) ?? false
    }

    /// Reads a bundle's Info.plist (string and boolean values; other types are ignored).
    public init(bundle: Bundle = .main, configuration: Configuration = .current) {
        let info = bundle.infoDictionary ?? [:]
        var strings: [String: String] = [:]
        for key in InfoKey.all {
            if let text = info[key] as? String {
                strings[key] = text
            } else if let flag = info[key] as? Bool {
                strings[key] = flag ? "YES" : "NO"
            }
        }
        self.init(info: strings, configuration: configuration)
    }

    /// The website origin as a URL.
    public var webURL: URL? { URL(string: webURLString) }
    /// `<website>/privacy`.
    public var privacyURL: URL? { URL(string: webURLString + "/privacy") }
    /// `<website>/terms`.
    public var termsURL: URL? { URL(string: webURLString + "/terms") }
    /// True when the configured RevenueCat key is a Test Store key (debug only).
    public var usesRevenueCatTestStore: Bool { revenueCatAPIKey?.hasPrefix("test_") == true }
}
