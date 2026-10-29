import LZBilling
import LZCore
import Foundation
import StoreKitTest
import Testing
@testable import Lahza

/// The one-time unlock against real StoreKit in the Simulator, with the local products of
/// `Config/Lahza.storekit` (no App Store Connect, no RevenueCat project): price, purchase, Restore
/// purchases on a fresh install, a refund, and Ask to Buy.
@MainActor @Suite(.serialized) struct StoreKitUnlockTests {
    private func session() throws -> SKTestSession {
        let url = try #require(Bundle(for: StoreKitBundleMarker.self).url(forResource: "Lahza", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    /// A paywall over StoreKit directly, on its own storage (a fresh install).
    private func paywall() -> (PaywallModel, EntitlementStore) {
        let environment = BillingEnvironment(apiKey: "test_storekit", configuration: .debug)
        let purchases = PurchasesService(client: StoreKitPurchasesClient(), environment: environment)
        let entitlement = EntitlementStore(kv: InMemoryKeyValueStore([:]), entitlementIdentifier: environment.entitlementIdentifier)
        return (PaywallModel(purchases: purchases, entitlement: entitlement, environment: environment), entitlement)
    }

    @Test(.timeLimit(.minutes(1))) func purchaseRestoreAndRefund() async throws {
        let session = try session()
        let (paywall, entitlement) = paywall()
        await paywall.load()
        #expect(paywall.phase == .ready)
        #expect(paywall.offer?.productIdentifier == Brand.Products.fullLibrary)
        #expect(paywall.purchaseTitle == "Unlock for $9.99")

        await paywall.restore()
        #expect(paywall.notice == .nothingToRestore)
        #expect(!entitlement.isUnlocked)

        await paywall.purchase()
        #expect(paywall.notice == .purchased)
        #expect(entitlement.isUnlocked)
        #expect(session.allTransactions().count == 1)

        // A fresh install finds it again with Restore purchases.
        let (fresh, freshEntitlement) = self.paywall()
        #expect(!freshEntitlement.isUnlocked)
        await fresh.restore()
        #expect(fresh.notice == .restored)
        #expect(freshEntitlement.isUnlocked)

        // A refund locks it again.
        let transaction = try #require(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        await fresh.restore()
        #expect(fresh.notice == .nothingToRestore)
        #expect(!freshEntitlement.isUnlocked)
    }

    @Test(.timeLimit(.minutes(1))) func askToBuyWaitsForApproval() async throws {
        let session = try session()
        session.askToBuyEnabled = true
        let (paywall, entitlement) = paywall()
        await paywall.load()
        await paywall.purchase()
        #expect(paywall.notice == .pending)
        #expect(!entitlement.isUnlocked)
    }
}

private final class StoreKitBundleMarker {}
