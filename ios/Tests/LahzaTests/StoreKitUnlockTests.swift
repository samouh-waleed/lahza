import LZBilling
import LZCore
import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Lahza

/// The one-time unlock against real StoreKit in the Simulator, with the local products of
/// `Config/Lahza.storekit` (no App Store Connect, no RevenueCat project): price, purchase, Restore
/// purchases on a fresh install, a refund, and Ask to Buy. Restore's `AppStore.sync()` is stubbed
/// (``FakeAppStore``): the real one can leave an Apple Account sign-in sheet on the Simulator.
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
    private func paywall(appStore: FakeAppStore = FakeAppStore()) -> (PaywallModel, EntitlementStore) {
        let environment = BillingEnvironment(apiKey: "test_storekit", configuration: .debug)
        let purchases = PurchasesService(client: appStore.client(), environment: environment)
        let entitlement = EntitlementStore(kv: InMemoryKeyValueStore([:]), entitlementIdentifier: environment.entitlementIdentifier)
        return (PaywallModel(purchases: purchases, entitlement: entitlement, environment: environment), entitlement)
    }

    /// Waits until StoreKit has applied a refund: it reaches `Transaction.currentEntitlements` a
    /// moment after `refundTransaction`, and the stubbed sync no longer covers that moment.
    private func waitForRefund(_ appStore: FakeAppStore) async throws {
        let client = appStore.client()
        for _ in 0..<100 {
            if try await !client.customerInfo().unlocks() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("StoreKit did not apply the refund within 5 seconds")
    }

    @Test(.timeLimit(.minutes(1))) func purchaseRestoreAndRefund() async throws {
        let session = try session()
        let appStore = FakeAppStore()
        let (paywall, entitlement) = paywall(appStore: appStore)
        await paywall.load()
        #expect(paywall.phase == .ready)
        #expect(paywall.offer?.productIdentifier == Brand.Products.fullLibrary)
        #expect(paywall.purchaseTitle == "Unlock for $9.99")

        await paywall.restore()
        #expect(appStore.syncs == 1)
        #expect(paywall.notice == .nothingToRestore)
        #expect(!entitlement.isUnlocked)

        await paywall.purchase()
        #expect(paywall.notice == .purchased)
        #expect(entitlement.isUnlocked)
        #expect(session.allTransactions().count == 1)

        // A fresh install finds it again with Restore purchases.
        let (fresh, freshEntitlement) = self.paywall(appStore: appStore)
        #expect(!freshEntitlement.isUnlocked)
        await fresh.restore()
        #expect(appStore.syncs == 2)
        #expect(fresh.notice == .restored)
        #expect(freshEntitlement.isUnlocked)

        // A refund locks it again.
        let transaction = try #require(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        try await waitForRefund(appStore)
        await fresh.restore()
        #expect(appStore.syncs == 3)
        #expect(fresh.notice == .nothingToRestore)
        #expect(!freshEntitlement.isUnlocked)
    }

    /// A failed sync fails the restore, mapped like a failed purchase.
    @Test(.timeLimit(.minutes(1))) func restoreReportsAFailedSync() async throws {
        // Cancelling the Apple Account sign-in.
        let cancelled = FakeAppStore(syncError: StoreKitError.userCancelled)
        await #expect(throws: PurchasesClientError.purchaseCancelled) {
            try await cancelled.client().restorePurchases()
        }
        #expect(cancelled.syncs == 1)

        // Any other failure keeps its code and message, and the paywall shows it.
        let offline = URLError(.notConnectedToInternet)
        let failing = FakeAppStore(syncError: offline)
        await #expect(throws: PurchasesClientError.store(code: offline.errorCode, message: offline.localizedDescription)) {
            try await failing.client().restorePurchases()
        }
        let (paywall, entitlement) = paywall(appStore: failing)
        await paywall.restore()
        #expect(failing.syncs == 2)
        #expect(paywall.notice == .failed(offline.localizedDescription))
        #expect(!entitlement.isUnlocked)
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

/// Stands in for `AppStore.sync()` in the StoreKit client: counts the syncs and throws
/// `syncError` when one is set.
private nonisolated final class FakeAppStore: Sendable {
    private let syncError: (any Error)?
    private let count = LockedValue(0)

    init(syncError: (any Error)? = nil) {
        self.syncError = syncError
    }

    var syncs: Int { count.value }

    func client() -> StoreKitPurchasesClient {
        StoreKitPurchasesClient(sync: { [self] in try sync() })
    }

    private func sync() throws {
        count.mutate { $0 += 1 }
        if let syncError { throw syncError }
    }
}

private final class StoreKitBundleMarker {}
