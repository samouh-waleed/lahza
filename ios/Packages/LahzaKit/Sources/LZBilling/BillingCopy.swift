import LZCore
import Foundation

/// Every user-facing billing string. Lahza sells one thing: a one-time unlock of the whole library
/// (decision 32). Never subscription or trial wording.
public enum BillingCopy {
    private static let freeMonths = Brand.Limits.freeSearchMonths

    // MARK: Store service

    /// The configured key has the wrong prefix or characters (never echoes the key).
    public static let sdkKeyMismatch = "This build needs the matching public store SDK key."
    /// The configured key changed while the SDK was already configured with another one.
    public static let storeSettingChanged = "The store setting changed. Fully close and reopen the app to load the price."
    /// The 20 s price deadline passed (the native read keeps going; a retry joins it).
    public static let pricesTimedOut = "Loading the price took too long. Try again."
    /// No usable SDK key while loading the price.
    public static let missingStoreForPrices = "This build isn’t connected to the App Store yet, so the price can’t load. Search over the last \(freeMonths) months keeps working."
    /// No usable SDK key while purchasing or restoring.
    public static let missingStoreForAction = "This build isn’t connected to the App Store yet."
    /// The offer's product is no longer the full-library unlock.
    public static let unlockUnavailable = "The unlock is unavailable right now. Reload the price."

    // MARK: Paywall

    /// Provider or configuration errors, and an offering without the unlock (``StoreMessage``).
    public static let storeUnavailable = "The App Store is unavailable right now. Try again. Search over the last \(freeMonths) months keeps working."
    public static let purchaseCancelled = "Purchase cancelled. Nothing was charged."
    public static let unlockedNotice = "Your whole library is unlocked."
    /// The store accepted a purchase but the entitlement is not active yet.
    public static let purchaseReceivedNotActive = "Your purchase was received but isn’t active yet. Try Restore purchases in a moment."
    public static let nothingToRestore = "No earlier purchase was found for this Apple Account."
    /// Ask to Buy / a deferred payment.
    public static let purchasePending = "Your purchase is waiting for approval. Your whole library unlocks as soon as it’s approved."

    /// The product's name in Settings.
    public static let productName = "Full library"
    public static let closeLabel = "Close"
    public static let eyebrow = "One-time purchase"
    public static let paywallTitle = "Unlock your\nwhole library."
    public static let paywallSubtitle = "\(Brand.name) searches the last \(freeMonths) months for free. One purchase opens every year before that."
    public static let freeTitle = "Free"
    public static let freeFeatures: [(symbol: String, text: String)] = [
        ("magnifyingglass", "Search the last \(freeMonths) months"),
        ("calendar", "Moments and trips from every year"),
        ("lock.shield", "Your photos never leave your iPhone"),
    ]
    public static let unlockTitle = "Full library"
    public static let unlockFeatures: [(symbol: String, text: String)] = [
        ("clock.arrow.circlepath", "Search every year of your photos"),
        ("checkmark.seal", "Pay once. No subscription"),
        ("arrow.clockwise", "Restore it with your Apple Account"),
    ]
    /// Under the price in the unlock card.
    public static let priceCaption = "one time"
    /// Under the purchase button.
    public static let purchaseFootnote = "Charged once to your Apple Account. Nothing renews."
    /// The purchase button, with the store's price verbatim: `"Unlock for $9.99"`.
    public static func unlock(price: String) -> String { "Unlock for \(price)" }
    /// The purchase button before the price is known (disabled).
    public static let unlockWithoutPrice = "Unlock"
    public static let loadingPrice = "Loading price…"
    public static let tryAgain = "Try again"
    public static let restorePurchases = "Restore purchases"
    public static let restoring = "Restoring…"
    public static let termsOfUse = "Terms of use"
    public static let privacyPolicy = "Privacy policy"
    public static let testStoreNotice = "Test purchases only. No money will be charged."

    // MARK: Settings

    public static let unlockedStatus = "Full library unlocked"
    public static let unlockedDetail = "Search covers every year of your photos."
    public static let freeStatus = "Free: last \(freeMonths) months"
    public static let freeDetail = "Search covers the last \(freeMonths) months. Moments and trips show every year."
    public static let seeUnlock = "Unlock your whole library"
    /// The Settings row's value.
    public static func settingsValue(isUnlocked: Bool) -> String { isUnlocked ? "Unlocked" : "Free" }

    // MARK: Locked results

    /// The row after a free search's results: `"2,431 more from earlier years"`.
    public static func moreFromEarlierYears(_ count: Int, locale: Locale = .autoupdatingCurrent) -> String {
        "\(count.formatted(.number.locale(locale))) more from earlier years"
    }

    /// VoiceOver's label for that row: `"2,431 more results from earlier years"`.
    public static func moreFromEarlierYearsLabel(_ count: Int, locale: Locale = .autoupdatingCurrent) -> String {
        "\(count.formatted(.number.locale(locale))) more \(count == 1 ? "result" : "results") from earlier years"
    }

    public static let lockedResultsDetail = "Unlock your whole library to see them."
    public static let lockedResultsAction = "Unlock"
    public static let lockedResultsHint = "Opens the one-time unlock."
}
