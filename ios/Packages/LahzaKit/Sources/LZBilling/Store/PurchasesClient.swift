import LZCore
import Foundation

/// The RevenueCat SDK surface Lahza uses, as plain values.
///
/// The live implementation is ``RevenueCatPurchasesClient``; tests and previews use
/// ``FakePurchasesClient``. Every call is made by ``PurchasesService``, which serializes them. Lahza has
/// no accounts, so the SDK runs with RevenueCat's anonymous app user.
public protocol PurchasesClient: Sendable {
    /// `Purchases.configure(with: .init(withAPIKey:))`, with `appUserID` only when one is given
    /// (nil: RevenueCat's anonymous app user). Called once per process.
    func configure(apiKey: String, appUserID: String?) async
    /// `Purchases.shared.logIn(appUserID)`.
    func logIn(_ appUserID: String) async throws
    /// `Purchases.shared.logOut()`. RevenueCat throws when the current user is anonymous.
    func logOut() async throws
    /// `Purchases.shared.isAnonymous` (true before configuration).
    func isAnonymous() async -> Bool
    /// `Purchases.shared.offerings().all`, keyed by offering id.
    func offerings() async throws -> [String: StoreOffering]
    /// `checkTrialOrIntroDiscountEligibility(productIdentifiers:)`. A product missing from the result
    /// counts as unknown; a thrown error means unknown for every product.
    func checkTrialOrIntroDiscountEligibility(productIdentifiers: [String]) async throws -> [String: IntroEligibilityStatus]
    /// `purchase(package:)`. Throws ``PurchasesClientError/purchaseCancelled`` when the person cancels
    /// and ``PurchasesClientError/paymentPending`` for Ask to Buy.
    func purchase(_ package: StorePackage) async throws -> CustomerSnapshot
    /// `restorePurchases()`. Only ever called from a button tap (it can show an Apple sign-in prompt).
    func restorePurchases() async throws -> CustomerSnapshot
    /// `customerInfo()`.
    func customerInfo() async throws -> CustomerSnapshot
    /// `showManageSubscriptions()` (the App Store sheet). Throws
    /// ``PurchasesClientError/manageSubscriptionsUnavailable`` where the platform has none.
    func showManageSubscriptions() async throws
    /// `customerInfoStream`: every CustomerInfo RevenueCat publishes (renewals, Ask to Buy approvals,
    /// promoted purchases). Finishes when the SDK is not configured.
    func customerInfoUpdates() async -> AsyncStream<CustomerSnapshot>
    /// The Plus products and this Apple Account's introductory-offer eligibility, read straight from
    /// the store. It never configures, identifies or logs in RevenueCat; nothing can be bought from it.
    func previewOffering(productIdentifiers: [String]) async throws -> StorePreview
}

/// Store failures the client maps from RevenueCat's `ErrorCode`.
public enum PurchasesClientError: Error, Sendable, Equatable, LocalizedError {
    /// `purchaseCancelledError` (or `userCancelled`): a neutral result.
    case purchaseCancelled
    /// `paymentPendingError`: Ask to Buy or another deferred payment.
    case paymentPending
    /// No App Store management sheet on this platform or window.
    case manageSubscriptionsUnavailable
    /// Any other store failure, with RevenueCat's code and message.
    case store(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .purchaseCancelled: "Purchase was cancelled."
        case .paymentPending: "The payment is pending."
        case .manageSubscriptionsUnavailable: BillingCopy.manageFallback
        case .store(_, let message): message
        }
    }
}
