#if os(iOS) && canImport(StoreKit)
import LZCore
import Foundation
import StoreKit

/// A ``PurchasesClient`` straight over StoreKit 2, without RevenueCat. It sells the same
/// non-consumable and reports the same entitlement, so ``PurchasesService``, ``EntitlementStore`` and
/// ``PaywallModel`` run unchanged over it. The app uses it only in DEBUG (`-LZStoreKit 1`): with the
/// local StoreKit configuration (`Config/Lahza.storekit`, or an `SKTestSession` in the app-hosted
/// tests) purchases run in the Simulator without App Store Connect or a RevenueCat project. The
/// unlock is active while StoreKit holds a verified, unrevoked transaction for the product.
public final class StoreKitPurchasesClient: PurchasesClient {
    /// The app user StoreKit answers for (there is no RevenueCat identity).
    public static let appUserID = "$StoreKit"

    /// Restore's sync with the App Store.
    public typealias Sync = @Sendable () async throws -> Void

    private let productIdentifier: String
    private let entitlement: String
    private let offeringIdentifier: String
    private let sync: Sync

    /// `sync` is `AppStore.sync()`, which can show an Apple Account sign-in sheet; the app-hosted
    /// tests pass a stub so no test leaves one on the Simulator.
    public init(
        productIdentifier: String = Brand.Products.fullLibrary,
        entitlement: String = Brand.fullLibraryEntitlement,
        offeringIdentifier: String = Brand.Products.offering,
        sync: @escaping Sync = { try await AppStore.sync() }
    ) {
        self.productIdentifier = productIdentifier
        self.entitlement = entitlement
        self.offeringIdentifier = offeringIdentifier
        self.sync = sync
    }

    // StoreKit needs no configuration and has no identity.
    public func configure(apiKey: String, appUserID: String?) async {}
    public func logIn(_ appUserID: String) async throws {}
    public func logOut() async throws {}
    public func isAnonymous() async -> Bool { true }

    /// The configured offering, holding the unlock as its lifetime package when the store sells it.
    public func offerings() async throws -> [String: StoreOffering] {
        let packages = try await products().map { product in
            StorePackage(identifier: StorePackage.lifetimeIdentifier, offeringIdentifier: offeringIdentifier, product: Self.info(product))
        }
        return [offeringIdentifier: StoreOffering(identifier: offeringIdentifier, packages: packages)]
    }

    public func purchase(_ package: StorePackage) async throws -> CustomerSnapshot {
        guard let product = try await products().first(where: { $0.id == package.product.identifier }) else {
            throw PurchasesClientError.store(code: 0, message: BillingCopy.unlockUnavailable)
        }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            throw Self.map(error)
        }
        switch result {
        case .success(let verification):
            if case .verified(let transaction) = verification { await transaction.finish() }
            return await snapshot()
        case .userCancelled:
            throw PurchasesClientError.purchaseCancelled
        case .pending:
            throw PurchasesClientError.paymentPending
        @unknown default:
            throw PurchasesClientError.store(code: 0, message: "The App Store returned an unknown purchase result.")
        }
    }

    /// `AppStore.sync()` (the injected `sync`), then the current entitlement.
    public func restorePurchases() async throws -> CustomerSnapshot {
        do {
            try await sync()
        } catch {
            throw Self.map(error)
        }
        return await snapshot()
    }

    public func customerInfo() async throws -> CustomerSnapshot {
        await snapshot()
    }

    /// The entitlement after every transaction StoreKit delivers outside a purchase (Ask to Buy
    /// approvals, refunds, purchases made on another device).
    public func customerInfoUpdates() async -> AsyncStream<CustomerSnapshot> {
        AsyncStream { continuation in
            let task = Task { [self] in
                for await result in Transaction.updates {
                    if case .verified(let transaction) = result { await transaction.finish() }
                    continuation.yield(await snapshot())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Mapping

    private func products() async throws -> [Product] {
        do {
            return try await Product.products(for: [productIdentifier])
        } catch {
            throw Self.map(error)
        }
    }

    private func snapshot() async -> CustomerSnapshot {
        var unlocked = false
        for await result in Transaction.currentEntitlements(for: productIdentifier) {
            if case .verified(let transaction) = result, transaction.revocationDate == nil { unlocked = true }
        }
        return CustomerSnapshot(appUserID: Self.appUserID, activeEntitlements: unlocked ? [entitlement] : [])
    }

    static func info(_ product: Product) -> StoreProductInfo {
        StoreProductInfo(
            identifier: product.id,
            localizedPrice: product.displayPrice,
            price: product.price,
            currencyCode: product.priceFormatStyle.currencyCode,
            localizedTitle: product.displayName
        )
    }

    static func map(_ error: any Error) -> PurchasesClientError {
        if case StoreKitError.userCancelled? = error as? StoreKitError { return .purchaseCancelled }
        let nsError = error as NSError
        return .store(code: nsError.code, message: error.localizedDescription)
    }
}
#endif
