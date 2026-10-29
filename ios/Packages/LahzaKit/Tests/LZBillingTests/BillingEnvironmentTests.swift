import Foundation
import LZCore
import Testing
@testable import LZBilling

@Suite struct BillingEnvironmentTests {
    @Test func keySelectionTrimsAndChecksThePrefix() throws {
        #expect(try RevenueCatKey.select(platform: .ios, iosKey: "  appl_Abc123\n") == "appl_Abc123")
        #expect(try RevenueCatKey.select(platform: .ios, testStore: true, testKey: "\ttest_x\r\n") == "test_x")
        #expect(try RevenueCatKey.select(platform: .ios, iosKey: " \n ") == nil)
        #expect(try RevenueCatKey.select(platform: .ios) == nil)
        #expect(try RevenueCatKey.select(platform: .other, iosKey: "appl_x") == nil)
        // Test Store mode never falls back to the live key.
        #expect(try RevenueCatKey.select(platform: .ios, testStore: true, iosKey: "appl_x") == nil)
        #expect(throws: BillingError.sdkKeyMismatch) { try RevenueCatKey.select(platform: .ios, iosKey: "test_x") }
        #expect(throws: BillingError.sdkKeyMismatch) { try RevenueCatKey.select(platform: .ios, iosKey: "appl_a b") }
        #expect(throws: BillingError.sdkKeyMismatch) { try RevenueCatKey.select(platform: .ios, iosKey: "appl_\u{E9}") }
    }

    @Test func storeProductsMatchExactlyOrWithABasePlan() {
        #expect(RevenueCatKey.matchesStoreProduct("lahza_full_library", "lahza_full_library"))
        #expect(RevenueCatKey.matchesStoreProduct("lahza_full_library:base", "lahza_full_library"))
        #expect(!RevenueCatKey.matchesStoreProduct("lahza_full_library2", "lahza_full_library"))
        #expect(!RevenueCatKey.matchesStoreProduct("lahza_full", "lahza_full_library"))
    }

    @Test func testStoreModeNeedsADebugBuild() throws {
        #expect(BillingEnvironment(apiKey: " test_x\n", configuration: .debug).usesTestStore)
        #expect(try BillingEnvironment(apiKey: " test_x\n", configuration: .debug).sdkKey() == "test_x")
        #expect(!BillingEnvironment(apiKey: "appl_x", configuration: .debug).usesTestStore)
        #expect(!BillingEnvironment(apiKey: "test_x", configuration: .release).usesTestStore)
        #expect(try BillingEnvironment(apiKey: nil, explicitTestStore: true, configuration: .release).sdkKey() == nil)
    }

    @Test func customerInfoCountsOnlyForTheIdentityItBelongsTo() {
        let anonymous = "$RCAnonymousID:" + String(repeating: "a1", count: 16)
        let ownership = CustomerInfoOwnership()
        // After configure, the first CustomerInfo teaches this identity's original id.
        ownership.configured(appUserID: anonymous)
        #expect(ownership.owner(originalAppUserID: "someone-else") == "someone-else")
        #expect(ownership.owner(originalAppUserID: anonymous) == anonymous)
        // After logIn, only RevenueCat's original id for the new identity counts for it.
        ownership.identified(appUserID: "b", originalAppUserID: anonymous)
        #expect(ownership.owner(originalAppUserID: anonymous) == "b")
        #expect(ownership.owner(originalAppUserID: "a") == "a")
        // While an identity change is in flight nothing is attributed.
        ownership.beginChange()
        #expect(ownership.owner(originalAppUserID: anonymous) == anonymous)
        #expect(ownership.currentAppUserID == nil)
    }
}
