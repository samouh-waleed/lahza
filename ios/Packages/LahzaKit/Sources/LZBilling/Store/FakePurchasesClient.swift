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
        case purchase(productId: String)
        case restore
        case customerInfo
    }

    /// The answer to each operation. Defaults answer from ``offerings`` and succeed.
    public struct Handlers: Sendable {
        public var logIn: @Sendable (String) async throws -> Void
        public var logOut: @Sendable () async throws -> Void
        public var offerings: @Sendable () async throws -> [String: StoreOffering]
        public var purchase: @Sendable (StorePackage) async throws -> CustomerSnapshot
        public var restore: @Sendable () async throws -> CustomerSnapshot
        public var customerInfo: @Sendable () async throws -> CustomerSnapshot
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
    }

    private let state: Mutex<State>
    /// The same attribution ``RevenueCatPurchasesClient`` applies to its stream.
    public let ownership = CustomerInfoOwnership()

    /// A client whose offerings are `offerings` (default: ``sampleOfferings(offeringIdentifier:)``).
    /// A purchase grants `entitlement`; `unlocked` starts with it already bought (restore and
    /// customerInfo report it).
    public init(
        offerings: [String: StoreOffering] = FakePurchasesClient.sampleOfferings(),
        entitlement: String = Brand.fullLibraryEntitlement,
        unlocked: Bool = false
    ) {
        let handlers = Handlers(
            logIn: { _ in },
            logOut: {},
            offerings: { offerings },
            purchase: { _ in CustomerSnapshot(appUserID: "", activeEntitlements: [entitlement]) },
            restore: { CustomerSnapshot(appUserID: "") },
            customerInfo: { CustomerSnapshot(appUserID: "") }
        )
        state = Mutex(State(handlers: handlers, granted: unlocked ? [entitlement] : []))
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
    public func emitCustomerInfo(activeEntitlements: Set<String>, originalAppUserID: String, requestDate: Date? = nil) {
        emitCustomerInfo(CustomerSnapshot(
            appUserID: ownership.owner(originalAppUserID: originalAppUserID),
            activeEntitlements: activeEntitlements,
            originalAppUserID: originalAppUserID,
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

    public func purchase(_ package: StorePackage) async throws -> CustomerSnapshot {
        var snapshot = try await record(.purchase(productId: package.product.identifier)) { $0.purchase }(package)
        if snapshot.appUserID.isEmpty { snapshot.appUserID = appUserID ?? "" }
        state.withLock { $0.granted.formUnion(snapshot.activeEntitlements) }
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
        state.withLock { copy.activeEntitlements.formUnion($0.granted) }
        return copy
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

    /// The sample catalog in USD: the full-library unlock at $9.99, as RevenueCat's lifetime package.
    public static func sampleOfferings(offeringIdentifier: String = Brand.Products.offering) -> [String: StoreOffering] {
        [offeringIdentifier: StoreOffering(identifier: offeringIdentifier, packages: [samplePackage(offeringIdentifier: offeringIdentifier)])]
    }

    /// The sample unlock package.
    public static func samplePackage(
        offeringIdentifier: String = Brand.Products.offering,
        packageIdentifier: String = StorePackage.lifetimeIdentifier,
        productId: String = Brand.Products.fullLibrary
    ) -> StorePackage {
        StorePackage(
            identifier: packageIdentifier,
            offeringIdentifier: offeringIdentifier,
            product: StoreProductInfo(
                identifier: productId,
                localizedPrice: "$9.99",
                price: Decimal(string: "9.99") ?? 0,
                currencyCode: "USD",
                localizedTitle: "\(Brand.name) Full Library"
            )
        )
    }
}
