import LZCore
import Foundation
import Synchronization

/// A scripted ``PurchasesClient`` for tests and previews. It never touches StoreKit
/// or the network. Every call is recorded in ``calls``; each operation's answer comes from a
/// replaceable handler, so a test can hold an operation open (a gate) or make it fail.
public final class FakePurchasesClient: PurchasesClient {
    /// A recorded SDK call.
    public enum Call: Sendable, Equatable {
        case configure(apiKey: String, appUserID: String?)
        case logIn(String)
        case logOut
        case offerings
        case eligibility([String])
        case purchase(productId: String)
        case restore
        case customerInfo
        case showManageSubscriptions
        case previewOffering([String])
    }

    /// The answer to each operation. Defaults answer from ``offerings`` and succeed.
    public struct Handlers: Sendable {
        public var logIn: @Sendable (String) async throws -> Void
        public var logOut: @Sendable () async throws -> Void
        public var offerings: @Sendable () async throws -> [String: StoreOffering]
        public var eligibility: @Sendable ([String]) async throws -> [String: IntroEligibilityStatus]
        public var purchase: @Sendable (StorePackage) async throws -> CustomerSnapshot
        public var restore: @Sendable () async throws -> CustomerSnapshot
        public var customerInfo: @Sendable () async throws -> CustomerSnapshot
        public var showManageSubscriptions: @Sendable () async throws -> Void
        /// Store-direct prices (default: the ``offerings`` handler's ``Brand/Products/offering``
        /// offering and the ``eligibility`` handler's answer, with no identity).
        public var previewOffering: @Sendable ([String]) async throws -> StorePreview
    }

    private struct State {
        var calls: [Call] = []
        var configured = false
        var appUserID: String?
        var anonymous = true
        var handlers: Handlers
        var continuations: [UUID: AsyncStream<CustomerSnapshot>.Continuation] = [:]
        /// RevenueCat's `originalAppUserId` per app user (default: the app user id itself).
        var originals: [String: String] = [:]
        /// Entitlements granted by purchases so far, so restore and customerInfo report them like
        /// the real store does.
        var granted: Set<String> = []
        var grantedTrials: Set<String> = []
    }

    private let state: Mutex<State>
    /// The same attribution ``RevenueCatPurchasesClient`` applies to its stream.
    public let ownership = CustomerInfoOwnership()

    /// A client whose offerings are `offerings` (default: ``sampleOfferings(annualTrial:)``) and
    /// whose eligibility answer is `eligibility` for every product.
    public init(
        offerings: [String: StoreOffering] = FakePurchasesClient.sampleOfferings(),
        eligibility: IntroEligibilityStatus = .eligible,
        managementURL: URL? = URL(string: "https://apps.apple.com/account/subscriptions")
    ) {
        let handlers = Handlers(
            logIn: { _ in },
            logOut: {},
            offerings: { offerings },
            eligibility: { ids in Dictionary(ids.map { ($0, eligibility) }, uniquingKeysWith: { first, _ in first }) },
            // Like StoreKit: a free introduction on the product starts a trial.
            purchase: { package in
                CustomerSnapshot(
                    appUserID: "",
                    activeEntitlements: [Brand.plusEntitlement],
                    managementURL: managementURL,
                    trialEntitlements: package.product.introOffer?.isFree == true ? [Brand.plusEntitlement] : []
                )
            },
            restore: { CustomerSnapshot(appUserID: "", activeEntitlements: [], managementURL: managementURL) },
            customerInfo: { CustomerSnapshot(appUserID: "", activeEntitlements: [], managementURL: managementURL) },
            showManageSubscriptions: {},
            previewOffering: { ids in
                let offering = offerings[Brand.Products.offering] ?? offerings.values.first ?? StoreOffering(identifier: Brand.Products.offering)
                let answer = Dictionary(ids.map { ($0, eligibility) }, uniquingKeysWith: { first, _ in first })
                return StorePreview(offering: offering, eligibility: answer)
            }
        )
        state = Mutex(State(handlers: handlers))
    }

    // MARK: Test controls

    /// Every call so far, in order.
    public var calls: [Call] { state.withLock { $0.calls } }
    /// The configured user id (nil before `configure` and after `logOut`).
    public var appUserID: String? { state.withLock { $0.appUserID } }
    /// Whether `configure` ran.
    public var isConfigured: Bool { state.withLock { $0.configured } }
    /// How many ``customerInfoUpdates()`` streams are subscribed (a test waits for one before emitting).
    public var customerInfoSubscriberCount: Int { state.withLock { $0.continuations.count } }

    /// Replaces handlers.
    public func update(_ change: (inout Handlers) -> Void) {
        state.withLock { change(&$0.handlers) }
    }

    /// Clears the call log.
    public func resetCalls() {
        state.withLock { $0.calls.removeAll() }
    }

    /// Makes the SDK's current user anonymous without a `logOut` call (as after another component's
    /// logout), to test the "never log out when anonymous" rule.
    public func simulateAnonymousUser() {
        state.withLock {
            $0.anonymous = true
            $0.appUserID = nil
        }
    }

    /// Publishes a CustomerInfo to every ``customerInfoUpdates()`` stream, as given.
    public func emitCustomerInfo(_ snapshot: CustomerSnapshot) {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations { continuation.yield(snapshot) }
    }

    /// Sets RevenueCat's `originalAppUserId` for `appUserID` (for example the `$RCAnonymousID:` alias an
    /// account gets when it is first identified after a sign-out). `logIn` reports it.
    public func setOriginalAppUserID(_ original: String, for appUserID: String) {
        state.withLock { $0.originals[appUserID] = original }
    }

    /// Publishes a CustomerInfo the way ``RevenueCatPurchasesClient`` tags its stream: attributed by
    /// ``ownership`` from its `originalAppUserId` (``CustomerInfoOwnership/owner(originalAppUserID:)``).
    public func emitCustomerInfo(
        activeEntitlements: Set<String>,
        originalAppUserID: String,
        nonRenewingEntitlements: Set<String> = [],
        trialEntitlements: Set<String> = [],
        requestDate: Date? = nil
    ) {
        emitCustomerInfo(CustomerSnapshot(
            appUserID: ownership.owner(originalAppUserID: originalAppUserID),
            activeEntitlements: activeEntitlements,
            originalAppUserID: originalAppUserID,
            nonRenewingEntitlements: nonRenewingEntitlements,
            trialEntitlements: trialEntitlements,
            requestDate: requestDate
        ))
    }

    // MARK: PurchasesClient

    public func configure(apiKey: String, appUserID: String?) async {
        let identity = appUserID ?? Self.anonymousAppUserID
        state.withLock {
            $0.calls.append(.configure(apiKey: apiKey, appUserID: appUserID))
            $0.configured = true
            $0.appUserID = identity
            $0.anonymous = appUserID == nil
        }
        ownership.configured(appUserID: identity)
    }

    /// The id the fake reports when configured without an app user (RevenueCat's anonymous form).
    public static let anonymousAppUserID = "$RCAnonymousID:" + String(repeating: "0", count: 32)

    public func logIn(_ appUserID: String) async throws {
        let handler = record(.logIn(appUserID)) { $0.logIn }
        ownership.beginChange()
        try await handler(appUserID)
        let original = state.withLock { state -> String in
            state.appUserID = appUserID
            state.anonymous = false
            return state.originals[appUserID] ?? appUserID
        }
        ownership.identified(appUserID: appUserID, originalAppUserID: original)
    }

    public func logOut() async throws {
        let (handler, anonymous) = state.withLock { state in
            state.calls.append(.logOut)
            return (state.handlers.logOut, state.anonymous)
        }
        ownership.beginChange()
        // RevenueCat: "LogOut was called but the current user is anonymous" (logOutAnonymousUserError).
        if anonymous { throw PurchasesClientError.store(code: 22, message: "LogOut was called but the current user is anonymous.") }
        try await handler()
        state.withLock {
            $0.appUserID = nil
            $0.anonymous = true
        }
    }

    public func isAnonymous() async -> Bool { state.withLock { $0.anonymous } }

    public func offerings() async throws -> [String: StoreOffering] {
        try await record(.offerings) { $0.offerings }()
    }

    public func checkTrialOrIntroDiscountEligibility(productIdentifiers: [String]) async throws -> [String: IntroEligibilityStatus] {
        try await record(.eligibility(productIdentifiers)) { $0.eligibility }(productIdentifiers)
    }

    public func purchase(_ package: StorePackage) async throws -> CustomerSnapshot {
        var snapshot = try await record(.purchase(productId: package.product.identifier)) { $0.purchase }(package)
        if snapshot.appUserID.isEmpty { snapshot.appUserID = appUserID ?? "" }
        state.withLock {
            $0.granted.formUnion(snapshot.activeEntitlements)
            $0.grantedTrials.formUnion(snapshot.trialEntitlements)
        }
        return snapshot
    }

    public func restorePurchases() async throws -> CustomerSnapshot {
        var snapshot = try await record(.restore) { $0.restore }()
        if snapshot.appUserID.isEmpty { snapshot.appUserID = appUserID ?? "" }
        return withGrants(snapshot)
    }

    public func customerInfo() async throws -> CustomerSnapshot {
        var snapshot = try await record(.customerInfo) { $0.customerInfo }()
        if snapshot.appUserID.isEmpty { snapshot.appUserID = appUserID ?? "" }
        return withGrants(snapshot)
    }

    /// `snapshot` plus everything bought so far.
    private func withGrants(_ snapshot: CustomerSnapshot) -> CustomerSnapshot {
        var copy = snapshot
        state.withLock {
            copy.activeEntitlements.formUnion($0.granted)
            copy.trialEntitlements.formUnion($0.grantedTrials)
        }
        return copy
    }

    public func showManageSubscriptions() async throws {
        try await record(.showManageSubscriptions) { $0.showManageSubscriptions }()
    }

    public func previewOffering(productIdentifiers: [String]) async throws -> StorePreview {
        try await record(.previewOffering(productIdentifiers)) { $0.previewOffering }(productIdentifiers)
    }

    public func customerInfoUpdates() async -> AsyncStream<CustomerSnapshot> {
        // Like RevenueCat: nothing to stream before the SDK is configured.
        guard isConfigured else { return AsyncStream { $0.finish() } }
        let id = UUID()
        let (stream, continuation) = AsyncStream<CustomerSnapshot>.makeStream()
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    private func record<T: Sendable>(_ call: Call, _ pick: (Handlers) -> T) -> T {
        state.withLock { state in
            state.calls.append(call)
            return pick(state.handlers)
        }
    }

    // MARK: Sample catalog

    /// The sample catalog in USD: monthly $5.99, yearly $39.99, and (by default) a free
    /// 1-week introduction on the yearly plan.
    public static func sampleOfferings(annualTrial: Bool = true, offeringIdentifier: String = Brand.Products.offering) -> [String: StoreOffering] {
        [offeringIdentifier: StoreOffering(
            identifier: offeringIdentifier,
            monthly: samplePackage(.monthly, offeringIdentifier: offeringIdentifier),
            annual: samplePackage(.annual, offeringIdentifier: offeringIdentifier, trial: annualTrial)
        )]
    }

    /// One sample package.
    public static func samplePackage(_ period: PlusPeriod, offeringIdentifier: String = Brand.Products.offering, trial: Bool = false, productId: String? = nil) -> StorePackage {
        let annual = period == .annual
        let intro = trial ? IntroOfferTerms(paymentMode: .freeTrial, price: 0, localizedPrice: "$0.00", period: StorePeriod(value: 1, unit: .week), numberOfPeriods: 1) : nil
        return StorePackage(
            identifier: annual ? "$rc_annual" : "$rc_monthly",
            offeringIdentifier: offeringIdentifier,
            product: StoreProductInfo(
                identifier: productId ?? period.productIdentifier,
                localizedPrice: annual ? "$39.99" : "$5.99",
                price: annual ? Decimal(string: "39.99") ?? 0 : Decimal(string: "5.99") ?? 0,
                currencyCode: "USD",
                priceLocale: Locale(identifier: "en_US"),
                subscriptionPeriod: StorePeriod(value: 1, unit: annual ? .year : .month),
                introOffer: intro,
                localizedTitle: annual ? "\(Brand.name) Plus Yearly" : "\(Brand.name) Plus Monthly"
            )
        )
    }
}
