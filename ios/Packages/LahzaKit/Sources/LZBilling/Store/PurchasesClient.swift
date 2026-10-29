import LZCore
import Foundation

/// The store SDK surface Lahza uses, as plain values.
///
/// The live implementation is ``RevenueCatPurchasesClient``; ``StoreKitPurchasesClient`` talks to
/// StoreKit directly (DEBUG, with the local StoreKit configuration file); tests and previews use
/// ``FakePurchasesClient``. Every call is made by ``PurchasesService``, which serializes them. Lahza
/// has no accounts, so the SDK runs with RevenueCat's anonymous app user.
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
    /// `purchase(package:)`. Throws ``PurchasesClientError/purchaseCancelled`` when the person cancels
    /// and ``PurchasesClientError/paymentPending`` for Ask to Buy.
    func purchase(_ package: StorePackage) async throws -> CustomerSnapshot
    /// `restorePurchases()`. Only ever called from a button tap (it can show an Apple sign-in prompt).
    func restorePurchases() async throws -> CustomerSnapshot
    /// `customerInfo()`.
    func customerInfo() async throws -> CustomerSnapshot
    /// `customerInfoStream`: every CustomerInfo RevenueCat publishes (Ask to Buy approvals, refunds,
    /// promoted purchases). Finishes when the SDK is not configured.
    func customerInfoUpdates() async -> AsyncStream<CustomerSnapshot>
}

/// Store failures the client maps from RevenueCat's `ErrorCode`.
public enum PurchasesClientError: Error, Sendable, Equatable, LocalizedError {
    /// `purchaseCancelledError` (or `userCancelled`): a neutral result.
    case purchaseCancelled
    /// `paymentPendingError`: Ask to Buy or another deferred payment.
    case paymentPending
    /// Any other store failure, with RevenueCat's code and message.
    case store(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .purchaseCancelled: "Purchase was cancelled."
        case .paymentPending: "The payment is pending."
        case .store(_, let message): message
        }
    }
}
