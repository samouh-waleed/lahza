import LZCore
import Foundation
import Synchronization
import Testing
@testable import LZBilling

/// The anonymous purchase service, the on-device entitlement and the paywall model, over the
/// fake store.
@Suite struct PurchasesServiceTests {
    private func service(_ client: FakePurchasesClient, key: String? = "test_fake") -> PurchasesService {
        PurchasesService(client: client, sdkKey: { key })
    }

    private func offering(_ packages: [StorePackage]) -> [String: StoreOffering] {
        [Brand.Products.offering: StoreOffering(identifier: Brand.Products.offering, packages: packages)]
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
        await #expect(throws: BillingError.missingStoreForPrices) { try await purchases.unlockOffer() }
        #expect(client.calls.isEmpty)
    }

    @Test func theOfferIsTheUnlockProductLifetimePackageFirst() async throws {
        let offer = try #require(try await service(FakePurchasesClient()).unlockOffer())
        #expect(offer.priceString == "$9.99")
        #expect(offer.productIdentifier == Brand.Products.fullLibrary)
        #expect(offer.package.identifier == StorePackage.lifetimeIdentifier)

        // A custom package id still sells the product; another product is never the unlock.
        let custom = FakePurchasesClient.samplePackage(packageIdentifier: "full")
        let other = FakePurchasesClient.samplePackage(productId: "lahza_other")
        #expect(try await service(FakePurchasesClient(offerings: offering([other, custom]))).unlockOffer()?.package == custom)
        #expect(try await service(FakePurchasesClient(offerings: offering([other]))).unlockOffer() == nil)
        let lifetime = FakePurchasesClient.samplePackage()
        #expect(try await service(FakePurchasesClient(offerings: offering([custom, lifetime]))).unlockOffer()?.package == lifetime)
        // Only the configured offering counts.
        #expect(try await service(FakePurchasesClient(offerings: FakePurchasesClient.sampleOfferings(offeringIdentifier: "other"))).unlockOffer() == nil)
    }

    @Test func cancelAndAskToBuyAreNeutral() async throws {
        let client = FakePurchasesClient()
        let purchases = service(client)
        let offer = try #require(try await purchases.unlockOffer())
        client.update { $0.purchase = { _ in throw PurchasesClientError.purchaseCancelled } }
        #expect(try await purchases.purchase(offer) == .cancelled)
        client.update { $0.purchase = { _ in throw PurchasesClientError.paymentPending } }
        #expect(try await purchases.purchase(offer) == .pending)
    }

    @Test func purchaseRefusesAnyOtherProduct() async throws {
        let client = FakePurchasesClient()
        let purchases = service(client)
        let other = UnlockOffer(package: FakePurchasesClient.samplePackage(productId: "lahza_other"))
        await #expect(throws: BillingError.unlockUnavailable) { try await purchases.purchase(other) }
        #expect(!client.calls.contains { if case .purchase = $0 { true } else { false } })
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
    private func paywall(_ client: FakePurchasesClient = FakePurchasesClient(), key: String? = "test_fake") -> (PaywallModel, EntitlementStore) {
        let purchases = PurchasesService(client: client, sdkKey: { key })
        let entitlement = EntitlementStore(kv: InMemoryKeyValueStore([:]))
        let model = PaywallModel(purchases: purchases, entitlement: entitlement, environment: BillingEnvironment(apiKey: key, configuration: .debug))
        return (model, entitlement)
    }

    @Test func entitlementFollowsTheStoreAndIsCached() {
        let kv = InMemoryKeyValueStore([:])
        let store = EntitlementStore(kv: kv)
        #expect(store.status == .unknown)
        #expect(!store.isUnlocked)
        store.apply(CustomerSnapshot(appUserID: "a", activeEntitlements: [Brand.fullLibraryEntitlement]))
        #expect(store.isUnlocked)
        #expect(EntitlementStore(kv: kv).status == .unlocked)
        // Another entitlement never unlocks; a refund or revocation locks again.
        store.apply(CustomerSnapshot(appUserID: "a", activeEntitlements: ["something_else"]))
        #expect(!store.isUnlocked)
        #expect(EntitlementStore(kv: kv).status == .free)
    }

    @Test func freeSearchCoversTheLastTwelveMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Riyadh"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12)))
        let store = EntitlementStore(kv: InMemoryKeyValueStore([:]))
        // Unknown counts as free.
        #expect(store.searchStart(now: now, calendar: calendar) == calendar.date(from: DateComponents(year: 2025, month: 10, day: 28, hour: 12)))
        store.apply(CustomerSnapshot(appUserID: "a", activeEntitlements: [Brand.fullLibraryEntitlement]))
        #expect(store.searchStart(now: now, calendar: calendar) == nil)
    }

    @Test func storeUpdatesUnlockAndRelock() async throws {
        let client = FakePurchasesClient()
        let purchases = PurchasesService(client: client, sdkKey: { "test_fake" })
        let entitlement = EntitlementStore(kv: InMemoryKeyValueStore([:]))
        await entitlement.start(with: purchases)
        #expect(entitlement.status == .free)
        #expect(client.customerInfoSubscriberCount == 1)

        // An Ask to Buy approval arrives later; a refund takes it back.
        client.emitCustomerInfo(CustomerSnapshot(appUserID: "a", activeEntitlements: [Brand.fullLibraryEntitlement]))
        for _ in 0..<1_000 where !entitlement.isUnlocked { await Task.yield() }
        #expect(entitlement.isUnlocked)
        client.emitCustomerInfo(CustomerSnapshot(appUserID: "a"))
        for _ in 0..<1_000 where entitlement.isUnlocked { await Task.yield() }
        #expect(!entitlement.isUnlocked)
        entitlement.stop()
    }

    /// The DEBUG `-LZUnlocked 1` store: already bought, so launch reads it unlocked and restore finds it.
    @Test func aFakeStoreCanStartUnlocked() async throws {
        let client = FakePurchasesClient(unlocked: true)
        let entitlement = EntitlementStore(kv: InMemoryKeyValueStore([:]))
        await entitlement.start(with: PurchasesService(client: client, sdkKey: { "test_fake" }))
        #expect(entitlement.isUnlocked)
        #expect(try await client.restorePurchases().unlocks())
        entitlement.stop()
        #expect(try await FakePurchasesClient().customerInfo().unlocks() == false)
    }

    @Test func purchaseUnlocksAndRestoreFindsIt() async {
        let (paywall, entitlement) = paywall()
        #expect(paywall.purchaseTitle == BillingCopy.unlockWithoutPrice)
        #expect(!paywall.canPurchase)

        await paywall.load()
        #expect(paywall.phase == .ready)
        #expect(paywall.offer?.priceString == "$9.99")
        #expect(paywall.purchaseTitle == "Unlock for $9.99")
        #expect(paywall.canPurchase)

        await paywall.restore()
        #expect(paywall.notice == .nothingToRestore)
        #expect(!entitlement.isUnlocked)

        await paywall.purchase()
        #expect(paywall.notice == .purchased)
        #expect(paywall.notice?.message == BillingCopy.unlockedNotice)
        #expect(entitlement.isUnlocked)
        #expect(paywall.phase == .ready)

        // The fake store remembers what was bought, like the real one.
        await paywall.restore()
        #expect(paywall.notice == .restored)
        #expect(entitlement.isUnlocked)
    }

    @Test func restoreWorksBeforeThePriceLoads() async {
        // Settings uses the model only to restore; it never loads the price.
        let client = FakePurchasesClient()
        let (paywall, _) = paywall(client)
        #expect(paywall.phase == .idle)
        #expect(!paywall.isBusy)
        await paywall.restore()
        #expect(client.calls.contains(.restore))
        #expect(paywall.notice == .nothingToRestore)
        #expect(paywall.phase == .idle)
    }

    @Test func anUnavailablePriceExplainsWhy() async {
        let (unconnected, _) = paywall(key: nil)
        await unconnected.load()
        #expect(unconnected.phase == .unavailable(BillingCopy.missingStoreForPrices))
        #expect(unconnected.offer == nil)
        #expect(!unconnected.canPurchase)

        // An offering that doesn't sell the unlock reads as the store being unavailable.
        let (empty, _) = paywall(FakePurchasesClient(offerings: [:]))
        await empty.load()
        #expect(empty.phase == .unavailable(BillingCopy.storeUnavailable))
        await empty.purchase()
        #expect(empty.notice == nil)
    }

    @Test func lockedResultsCopyCountsInTheLocale() {
        let us = Locale(identifier: "en_US")
        #expect(BillingCopy.moreFromEarlierYears(2_431, locale: us) == "2,431 more from earlier years")
        #expect(BillingCopy.moreFromEarlierYearsLabel(2_431, locale: us) == "2,431 more results from earlier years")
        #expect(BillingCopy.moreFromEarlierYearsLabel(1, locale: us) == "1 more result from earlier years")
        #expect(BillingCopy.moreFromEarlierYears(2_431, locale: Locale(identifier: "de_DE")) == "2.431 more from earlier years")
    }
}
