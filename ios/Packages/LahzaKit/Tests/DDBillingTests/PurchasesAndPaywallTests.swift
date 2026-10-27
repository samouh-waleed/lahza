import DDCore
import Foundation
import Synchronization
import Testing
@testable import DDBilling

/// The anonymous purchase service, the on-device entitlement and the paywall model, over the
/// fake store.
@Suite struct PurchasesServiceTests {
    private func service(_ client: FakePurchasesClient, key: String? = "test_fake") -> PurchasesService {
        PurchasesService(client: client, sdkKey: { key })
    }

    @Test func configuresAnonymouslyOnce() async throws {
        let client = FakePurchasesClient()
        let purchases = service(client)
        #expect(try await purchases.start())
        #expect(try await purchases.start())
        #expect(client.calls == [.configure(apiKey: "test_fake", appUserID: nil)])
        #expect(client.appUserID == FakePurchasesClient.anonymousAppUserID)
    }

    @Test func withoutAKeyBillingIsUnavailable() async throws {
        let client = FakePurchasesClient()
        let purchases = service(client, key: nil)
        #expect(!purchases.isAvailable)
        #expect(try await purchases.start() == false)
        #expect(try await purchases.customerInfo() == nil)
        await #expect(throws: BillingError.missingStoreForPrices) { try await purchases.offers() }
        #expect(client.calls.isEmpty)
    }

    @Test func offersCarryConfirmedTrialOnlyWhenEligible() async throws {
        let eligible = try await service(FakePurchasesClient(eligibility: .eligible)).offers()
        #expect(eligible.annual?.trial?.duration == "1 week")
        #expect(eligible.monthly?.trial == nil)

        let ineligible = try await service(FakePurchasesClient(eligibility: .ineligible)).offers()
        #expect(ineligible.annual != nil)
        #expect(ineligible.annual?.trial == nil)
    }

    @Test func cancelIsNeutral() async throws {
        let client = FakePurchasesClient()
        client.update { $0.purchase = { _ in throw PurchasesClientError.purchaseCancelled } }
        let purchases = service(client)
        let offer = try #require(try await purchases.offers().annual)
        #expect(try await purchases.purchase(offer) == .cancelled)
    }

    @Test func keyChangeMidProcessIsRefused() async throws {
        let client = FakePurchasesClient()
        let key = Mutex<String?>("test_one")
        let purchases = PurchasesService(client: client, sdkKey: { key.withLock { $0 } })
        #expect(try await purchases.start())
        key.withLock { $0 = "test_two" }
        await #expect(throws: BillingError.storeSettingChanged) { try await purchases.start() }
    }
}

@MainActor @Suite struct EntitlementAndPaywallTests {
    @Test func entitlementFollowsTheStoreAndIsCached() {
        let kv = InMemoryKeyValueStore([:])
        let store = EntitlementStore(kv: kv)
        #expect(store.status == .unknown)
        store.apply(CustomerSnapshot(appUserID: "a", activeEntitlements: [Brand.plusEntitlement], trialEntitlements: [Brand.plusEntitlement]))
        #expect(store.isUnlocked)
        #expect(store.isInTrial)
        #expect(EntitlementStore(kv: kv).status == .plus)
        store.apply(CustomerSnapshot(appUserID: "a"))
        #expect(!store.isUnlocked)
        #expect(EntitlementStore(kv: kv).status == .free)
    }

    @Test func purchaseUnlocksAndRestoreReportsNothingFound() async {
        let client = FakePurchasesClient()
        let purchases = PurchasesService(client: client, sdkKey: { "test_fake" })
        let entitlement = EntitlementStore(kv: InMemoryKeyValueStore([:]))
        let paywall = PaywallModel(purchases: purchases, entitlement: entitlement, environment: BillingEnvironment(apiKey: "test_fake", configuration: .debug))

        await paywall.load()
        #expect(paywall.phase == .ready)
        #expect(paywall.selectedPeriod == .annual)
        #expect(paywall.purchaseTitle == BillingCopy.startTrial("1 week"))

        await paywall.restore()
        #expect(paywall.notice == .nothingToRestore)
        #expect(!entitlement.isUnlocked)

        await paywall.purchase()
        #expect(paywall.notice == .purchased)
        #expect(entitlement.isUnlocked)
        #expect(entitlement.isInTrial)

        // The fake store remembers what was bought, like the real one.
        await paywall.restore()
        #expect(paywall.notice == .restored)
        #expect(entitlement.isUnlocked)
    }

    @Test func restoreWorksBeforePricesLoad() async {
        // Settings uses the model only to restore and manage; it never loads prices.
        let client = FakePurchasesClient()
        let purchases = PurchasesService(client: client, sdkKey: { "test_fake" })
        let paywall = PaywallModel(purchases: purchases, entitlement: EntitlementStore(kv: InMemoryKeyValueStore([:])), environment: BillingEnvironment(apiKey: "test_fake", configuration: .debug))
        #expect(paywall.phase == .idle)
        #expect(!paywall.isBusy)
        await paywall.restore()
        #expect(client.calls.contains(.restore))
        #expect(paywall.notice == .nothingToRestore)
        #expect(paywall.phase == .idle)
    }

    @Test func unavailablePricesExplainWhy() async {
        let purchases = PurchasesService(client: FakePurchasesClient(), sdkKey: { nil })
        let paywall = PaywallModel(purchases: purchases, entitlement: EntitlementStore(kv: InMemoryKeyValueStore([:])), environment: BillingEnvironment(apiKey: nil))
        await paywall.load()
        #expect(paywall.phase == .unavailable(BillingCopy.missingStoreForPrices))
        #expect(paywall.selectedOffer == nil)
    }
}
