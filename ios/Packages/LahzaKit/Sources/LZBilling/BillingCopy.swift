import LZCore
import Foundation

/// Every user-facing billing string. Placeholder product copy until the paywall is designed.
public enum BillingCopy {
    // MARK: Store service

    /// The configured key has the wrong prefix or characters (never echoes the key).
    public static let sdkKeyMismatch = "This build needs the matching public store SDK key."
    /// The configured key changed while the SDK was already configured with another one.
    public static let storeSettingChanged = "The store setting changed. Fully close and reopen the app to load prices."
    /// The 20 s price deadline passed (the native read keeps going; a retry joins it).
    public static let pricesTimedOut = "Loading store prices took too long. Try again."
    /// No usable SDK key while loading prices.
    public static let missingStoreForPrices = "This build isn’t connected to the App Store yet, so plans can’t load. Free search keeps working."
    /// No usable SDK key while purchasing or restoring.
    public static let missingStoreForAction = "This build isn’t connected to the App Store yet."
    /// The offer's product id no longer matches its period's product.
    public static let selectedPlanUnavailable = "The selected plan is unavailable. Reload store prices."

    // MARK: Paywall

    /// Provider or configuration errors (``StoreMessage``).
    public static let storePlansUnavailable = "Store plans are unavailable right now. Try again. Free search keeps working."
    public static let purchaseCancelled = "Purchase cancelled. Your plan is unchanged."
    public static let plusActiveNotice = "\(plusName) is active."
    /// The store accepted a purchase but the entitlement is not active yet.
    public static let purchaseReceivedNotActive = "Your purchase was received but isn’t active yet. Try Restore purchases in a moment."
    public static let noActiveSubscription = "No active purchase was found for this Apple Account."
    /// No App Store management sheet could be shown.
    public static let manageFallback = "Open Settings › Apple Account › Subscriptions to manage your plan."
    /// Ask to Buy / a deferred payment.
    public static let purchasePending = "Your purchase is waiting for approval. \(plusName) starts as soon as it’s approved."

    public static let plusName = "\(Brand.name) Plus"
    public static let closeLabel = "Close"
    public static let paywallTitle = "Your whole library,\none question away."
    public static let paywallSubtitle = "Free search covers the last \(Brand.Limits.freeSearchMonths) months. \(plusName) searches every year of your photos."
    public static let benefits: [(symbol: String, title: String, detail: String)] = [
        ("calendar", "Every year", "Search your entire library, not just the last \(Brand.Limits.freeSearchMonths) months."),
        ("lock.shield", "Still private", "Your photos never leave your iPhone."),
        ("sparkles", "Every new feature", "New ways to find and relive your moments as they arrive."),
    ]
    public static let subscribe = "Continue"
    public static func startTrial(_ duration: String) -> String { "Start \(duration) free" }
    public static let loadingPrices = "Loading prices…"
    public static let tryAgain = "Try again"
    public static let restorePurchases = "Restore purchases"
    public static let restoring = "Restoring…"
    public static let manageSubscription = "Manage subscription"
    public static let termsOfUse = "Terms of use"
    public static let privacyPolicy = "Privacy policy"
    public static let testStoreNotice = "Test purchases only. No money will be charged."
    public static let plusIsActive = "\(plusName) is active"
    public static let freePlan = "Free: last \(Brand.Limits.freeSearchMonths) months"

    /// `"Renews {date}"` or `"Available until {date}"`.
    public static func renewalLine(willRenew: Bool, date: String) -> String {
        "\(willRenew ? "Renews" : "Available until") \(date)"
    }

    /// Apple's required auto-renewal disclosure under the purchase button.
    public static let renewalDisclosure = "Subscriptions renew automatically unless cancelled at least 24 hours before the end of the period. Manage or cancel anytime in Settings."
}
