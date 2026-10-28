#if canImport(RevenueCat)
import LZCore
import Foundation
import RevenueCat
import Synchronization

/// The live ``PurchasesClient`` over RevenueCat `purchases-ios`. It only translates:
/// ``PurchasesService`` owns ordering and the key rules. Compile-checked on macOS and iOS; it runs
/// only in the app.
public final class RevenueCatPurchasesClient: PurchasesClient {
    /// The packages from the latest `offerings()` read, keyed by offering and product id, so a
    /// purchase can hand RevenueCat its own `Package` back (with its offering context).
    private let packages = Mutex<[String: Package]>([:])
    /// Attributes streamed CustomerInfo to the identity it was fetched for (``CustomerInfoOwnership``).
    private let ownership = CustomerInfoOwnership()

    public init() {}

    public func configure(apiKey: String, appUserID: String?) async {
        await MainActor.run {
            guard !Purchases.isConfigured else { return }
            var builder = Configuration.Builder(withAPIKey: apiKey)
            if let appUserID { builder = builder.with(appUserID: appUserID) }
            Purchases.configure(with: builder.build())
            ownership.configured(appUserID: Purchases.shared.appUserID)
        }
    }

    public func logIn(_ appUserID: String) async throws {
        try Self.requireConfigured()
        ownership.beginChange()
        do {
            let result = try await Purchases.shared.logIn(appUserID)
            ownership.identified(appUserID: appUserID, originalAppUserID: result.customerInfo.originalAppUserId)
        } catch {
            throw Self.map(error)
        }
    }

    public func logOut() async throws {
        guard Purchases.isConfigured else { return }
        ownership.beginChange()
        do {
            _ = try await Purchases.shared.logOut()
        } catch {
            throw Self.map(error)
        }
    }

    public func isAnonymous() async -> Bool {
        guard Purchases.isConfigured else { return true }
        return Purchases.shared.isAnonymous
    }

    public func offerings() async throws -> [String: StoreOffering] {
        try Self.requireConfigured()
        let all: [String: Offering]
        do {
            all = try await Purchases.shared.offerings().all
        } catch {
            throw Self.map(error)
        }
        var seen: [String: Package] = [:]
        var result: [String: StoreOffering] = [:]
        for (identifier, offering) in all {
            let monthly = offering.monthly.map { package -> StorePackage in
                seen[Self.cacheKey(offering: identifier, product: package.storeProduct.productIdentifier)] = package
                return Self.package(package)
            }
            let annual = offering.annual.map { package -> StorePackage in
                seen[Self.cacheKey(offering: identifier, product: package.storeProduct.productIdentifier)] = package
                return Self.package(package)
            }
            result[identifier] = StoreOffering(identifier: identifier, monthly: monthly, annual: annual)
        }
        packages.withLock { $0.merge(seen) { _, new in new } }
        return result
    }

    public func checkTrialOrIntroDiscountEligibility(productIdentifiers: [String]) async throws -> [String: IntroEligibilityStatus] {
        try Self.requireConfigured()
        let answer = await Purchases.shared.checkTrialOrIntroDiscountEligibility(productIdentifiers: productIdentifiers)
        return answer.compactMapValues { IntroEligibilityStatus(rawValue: $0.status.rawValue) }
    }

    public func purchase(_ package: StorePackage) async throws -> CustomerSnapshot {
        try Self.requireConfigured()
        guard let native = try await nativePackage(for: package) else {
            throw PurchasesClientError.store(code: ErrorCode.productNotAvailableForPurchaseError.rawValue, message: BillingCopy.selectedPlanUnavailable)
        }
        do {
            let result = try await Purchases.shared.purchase(package: native)
            // The async API throws `purchaseCancelledError` on cancel; `userCancelled` is checked too
            // in case a future SDK returns instead.
            if result.userCancelled { throw PurchasesClientError.purchaseCancelled }
            return Self.snapshot(result.customerInfo, owner: Purchases.shared.appUserID)
        } catch let error as PurchasesClientError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    public func restorePurchases() async throws -> CustomerSnapshot {
        try Self.requireConfigured()
        do {
            let info = try await Purchases.shared.restorePurchases()
            return Self.snapshot(info, owner: Purchases.shared.appUserID)
        } catch {
            throw Self.map(error)
        }
    }

    public func customerInfo() async throws -> CustomerSnapshot {
        try Self.requireConfigured()
        do {
            let info = try await Purchases.shared.customerInfo()
            return Self.snapshot(info, owner: Purchases.shared.appUserID)
        } catch {
            throw Self.map(error)
        }
    }

    /// StoreKit 2 directly: prices and eligibility need no RevenueCat identity (``StoreKitPreview``).
    public func previewOffering(productIdentifiers: [String]) async throws -> StorePreview {
        try await StoreKitPreview.offering(productIdentifiers: productIdentifiers)
    }

    public func showManageSubscriptions() async throws {
        #if os(iOS)
        guard Purchases.isConfigured else { throw PurchasesClientError.manageSubscriptionsUnavailable }
        do {
            try await Purchases.shared.showManageSubscriptions()
        } catch {
            // Any failure to show the sheet (no active window scene, a store problem) falls through to
            // the management URL and then the ``BillingCopy/manageFallback`` text.
            let mapped = Self.map(error)
            throw mapped == .purchaseCancelled ? mapped : PurchasesClientError.manageSubscriptionsUnavailable
        }
        #else
        throw PurchasesClientError.manageSubscriptionsUnavailable
        #endif
    }

    public func customerInfoUpdates() async -> AsyncStream<CustomerSnapshot> {
        guard Purchases.isConfigured else { return AsyncStream { $0.finish() } }
        let source = Purchases.shared.customerInfoStream
        let ownership = ownership
        return AsyncStream { continuation in
            let task = Task {
                // Only CustomerInfo whose original id matches the current identity's counts for it.
                for await info in source {
                    continuation.yield(Self.snapshot(info, owner: ownership.owner(originalAppUserID: info.originalAppUserId)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Mapping

    private func nativePackage(for package: StorePackage) async throws -> Package? {
        let key = Self.cacheKey(offering: package.offeringIdentifier, product: package.product.identifier)
        if let cached = packages.withLock({ $0[key] }) { return cached }
        _ = try await offerings()
        return packages.withLock { $0[key] }
    }

    private static func cacheKey(offering: String, product: String) -> String { offering + "\u{1F}" + product }

    /// `Purchases.shared` traps before configuration; ``PurchasesService`` always identifies first,
    /// so this only guards against misuse.
    private static func requireConfigured() throws {
        guard Purchases.isConfigured else {
            throw PurchasesClientError.store(code: ErrorCode.configurationError.rawValue, message: "The store is not configured yet.")
        }
    }

    static func package(_ package: Package) -> StorePackage {
        StorePackage(identifier: package.identifier, offeringIdentifier: package.offeringIdentifier, product: product(package.storeProduct))
    }

    static func product(_ product: StoreProduct) -> StoreProductInfo {
        StoreProductInfo(
            identifier: product.productIdentifier,
            localizedPrice: product.localizedPriceString,
            price: product.price,
            currencyCode: product.currencyCode,
            priceLocale: product.priceFormatter?.locale,
            subscriptionPeriod: product.subscriptionPeriod.flatMap(period),
            introOffer: product.introductoryDiscount.map { discount in
                IntroOfferTerms(
                    paymentMode: paymentMode(discount.paymentMode),
                    price: discount.price,
                    localizedPrice: discount.localizedPriceString,
                    period: period(discount.subscriptionPeriod),
                    numberOfPeriods: discount.numberOfPeriods
                )
            },
            localizedTitle: product.localizedTitle
        )
    }

    /// Nil for a unit this build does not know; ``FreeTrial/confirmed(intro:eligibility:)`` rejects it.
    static func period(_ period: SubscriptionPeriod) -> StorePeriod? {
        let unit: StorePeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        return StorePeriod(value: period.value, unit: unit)
    }

    static func paymentMode(_ mode: StoreProductDiscount.PaymentMode) -> IntroOfferTerms.PaymentMode {
        switch mode {
        case .freeTrial: .freeTrial
        case .payUpFront: .payUpFront
        case .payAsYouGo: .payAsYouGo
        @unknown default: .payAsYouGo
        }
    }

    /// `owner` is the identity the CustomerInfo belongs to: the SDK's identity for a direct answer
    /// (made inside ``PurchasesService``'s queue), ``CustomerInfoOwnership`` for the stream. Never
    /// `originalAppUserId`, an anonymous alias for an account first identified after a sign-out.
    static func snapshot(_ info: CustomerInfo, owner: String) -> CustomerSnapshot {
        let active = info.entitlements.active
        return CustomerSnapshot(
            appUserID: owner,
            activeEntitlements: Set(active.keys),
            managementURL: info.managementURL,
            originalAppUserID: info.originalAppUserId,
            nonRenewingEntitlements: Set(active.filter { !$0.value.willRenew }.keys),
            trialEntitlements: Set(active.filter { $0.value.periodType == .trial }.keys),
            requestDate: info.requestDate
        )
    }

    /// RevenueCat throws `NSError`s in `ErrorCode.errorDomain`; cancel and Ask to Buy become the
    /// neutral cases, everything else keeps RevenueCat's code and message (the paywall maps provider
    /// and configuration messages to the "Store plans are unavailable" copy).
    static func map(_ error: any Error) -> PurchasesClientError {
        let nsError = error as NSError
        let code = (error as? ErrorCode) ?? (nsError.domain == ErrorCode.errorDomain ? ErrorCode(rawValue: nsError.code) : nil)
        switch code {
        case .purchaseCancelledError?: return .purchaseCancelled
        case .paymentPendingError?: return .paymentPending
        default: return .store(code: code?.rawValue ?? nsError.code, message: nsError.localizedDescription)
        }
    }
}
#endif
