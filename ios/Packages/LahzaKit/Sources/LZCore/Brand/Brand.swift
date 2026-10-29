import Foundation

/// Brand identity and fixed product constants. The only place app code may read identity from.
public enum Brand {
    public static let name = "Lahza"
    /// "Lahza" (لحظة) means "moment" in Arabic.
    public static let arabicName = "لحظة"
    public static let tagline = "Your life, remembered."
    public static let description = "Find the moments in your photo library by describing what you remember. Private, on your iPhone."
    /// Bundle id. Placeholder until the App Store Connect record exists.
    public static let applicationID = "com.waleedsamouh.lahza"
    /// Namespace for kv keys.
    public static let storagePrefix = "lahza"
    /// Website origin for the privacy policy, terms and support pages.
    /// Placeholder: replace with the real domain before TestFlight (template-migration D12).
    public static let websiteURL = "https://example.com/lahza"
    /// Support contact, once one exists.
    public static let supportEmail: String? = nil

    /// RevenueCat entitlement identifier that unlocks the full library.
    public static let fullLibraryEntitlement = "full_library"

    /// Store products and offering. Placeholders until the products exist in App Store Connect
    /// and RevenueCat (template-migration D9).
    public enum Products {
        /// The full-library unlock: one non-consumable, bought once (decision 32). RevenueCat sells it
        /// as the offering's lifetime package.
        public static let fullLibrary = "lahza_full_library"
        /// RevenueCat offering identifier.
        public static let offering = "default"
    }

    /// Plan limits.
    public enum Limits {
        /// Free search covers this many most recent months of the library (decision 17).
        public static let freeSearchMonths = 12
    }
}
