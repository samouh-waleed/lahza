import LZBilling
import LZCore
import Foundation
import Testing
@testable import Lahza

/// The app's side of the one-time unlock: the locked-results row's rule, the Settings route and the
/// DEBUG test stores.
@MainActor @Suite struct UnlockWiringTests {
    @Test func lockedResultsRowShowsOnlyForAFreeSearchWithOlderMatches() {
        #expect(LockedResultsRow.isShown(lockedCount: 2_431, isUnlocked: false))
        #expect(LockedResultsRow.isShown(lockedCount: 1, isUnlocked: false))
        #expect(!LockedResultsRow.isShown(lockedCount: 0, isUnlocked: false))
        #expect(!LockedResultsRow.isShown(lockedCount: 2_431, isUnlocked: true))
    }

    @Test func fullLibraryIsASettingsScreen() {
        #expect(Route(debugName: "full-library") == .fullLibrary)
        #expect(Route(debugName: "subscription") == nil)
        #expect(Route.fullLibrary.tab == .settings)
        #expect(Route.fullLibrary.presentation == .push)
    }

    @Test func testStoresRunOnTheirOwnStorage() {
        var fake = AppDependencies.testHost()
        DebugLaunch.parse { $0 == "LZFakeStore" ? "1" : nil }.apply(to: &fake)
        #expect(fake.purchases is FakePurchasesClient)
        #expect(fake.billingEnvironment.usesTestStore)
        #expect(fake.label == "debug:fake-store")

        var storeKit = AppDependencies.testHost()
        DebugLaunch.parse { $0 == "LZStoreKit" ? "1" : nil }.apply(to: &storeKit)
        #expect(storeKit.purchases is StoreKitPurchasesClient)
        #expect(storeKit.billingEnvironment.usesTestStore)
        #expect(storeKit.label == "debug:storekit")
    }
}
