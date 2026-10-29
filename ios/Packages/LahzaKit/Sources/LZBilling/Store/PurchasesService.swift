import LZCore
import Foundation
import Synchronization

/// The store side of the full-library unlock: RevenueCat configuration, the price, purchase and
/// restore. Lahza has no accounts, so RevenueCat runs with its anonymous app user and the active
/// entitlement it reports is the gate (``EntitlementStore``).
///
/// Rules:
/// - **One queue.** Store operations run strictly in order (``SerialQueue``).
/// - **Price.** At most one read in flight per key; the caller waits at most 20 s ("Loading the
///   price took too long. Try again."), while the read keeps its place in the queue and a retry
///   joins it.
/// - **Cancel** is a neutral ``PurchaseOutcome/cancelled``.
/// - **Key.** The SDK is configured once; a key change mid-process is refused.
public final class PurchasesService: Sendable {
    /// The caller's price deadline.
    public static let priceDeadline: Duration = .seconds(20)

    private struct Flight {
        var id: UInt64
        var key: String?
        var task: Task<UnlockOffer?, any Error>
    }

    private struct State {
        var configuredKey: String?
        var pendingOffers: Flight?
        var nextFlight: UInt64 = 0
    }

    public let client: any PurchasesClient
    private let sdkKey: @Sendable () throws(BillingError) -> String?
    private let offeringIdentifier: @Sendable () -> String
    private let clock: any AppClock
    private let queue = SerialQueue()
    private let state = Mutex(State())

    /// A service over explicit inputs. `sdkKey` and `offeringIdentifier` are read on every operation.
    public init(
        client: any PurchasesClient,
        sdkKey: @escaping @Sendable () throws(BillingError) -> String?,
        offeringIdentifier: @escaping @Sendable () -> String = { Brand.Products.offering },
        clock: any AppClock = SystemClock()
    ) {
        self.client = client
        self.sdkKey = sdkKey
        self.offeringIdentifier = offeringIdentifier
        self.clock = clock
    }

    /// A service over the build's billing environment.
    public convenience init(client: any PurchasesClient, environment: BillingEnvironment, clock: any AppClock = SystemClock()) {
        self.init(
            client: client,
            sdkKey: { () throws(BillingError) -> String? in try environment.sdkKey() },
            offeringIdentifier: { environment.offeringIdentifier },
            clock: clock
        )
    }

    /// True when this build has a usable store key (billing is connected).
    public var isAvailable: Bool { ((try? sdkKey()) ?? nil) != nil }

    // MARK: Configuration

    /// Configures RevenueCat once, with its anonymous app user. Returns false when the build has no
    /// usable key (billing is simply unavailable; free search keeps working).
    @discardableResult
    public func start() async throws -> Bool {
        try await queue.enqueue { [self] in try await configureIfNeeded() }.value
    }

    // MARK: Prices

    /// The offering's full-library unlock, or nil when the offering does not sell it.
    public func unlockOffer() async throws -> UnlockOffer? {
        let key = try sdkKey()
        let flight = state.withLock { inner -> Task<UnlockOffer?, any Error> in
            if let pending = inner.pendingOffers, pending.key == key { return pending.task }
            inner.nextFlight += 1
            let id = inner.nextFlight
            let task = queue.enqueue { [self] in try await readOffer() }
            inner.pendingOffers = Flight(id: id, key: key, task: task)
            Task { [self] in
                _ = await task.result
                state.withLock { if $0.pendingOffers?.id == id { $0.pendingOffers = nil } }
            }
            return task
        }
        return try await waitForPrices(flight)
    }

    private func readOffer() async throws -> UnlockOffer? {
        guard try await configureIfNeeded() else { throw BillingError.missingStoreForPrices }
        let all = try await client.offerings()
        return UnlockOffer.find(in: all[offeringIdentifier()])
    }

    /// Only the caller stops waiting: the native read keeps its place in the queue until it settles,
    /// and a retry rejoins it. The timer is cancelled as soon as the read settles.
    private func waitForPrices(_ flight: Task<UnlockOffer?, any Error>) async throws -> UnlockOffer? {
        let outcome = OneShot<UnlockOffer?>()
        let clock = self.clock
        let timer = Task {
            do { try await clock.sleep(for: Self.priceDeadline) } catch { return }
            outcome.resolve(.failure(BillingError.pricesTimedOut))
        }
        Task {
            let result = await flight.result
            timer.cancel()
            outcome.resolve(result)
        }
        return try await outcome.wait(onCancel: { timer.cancel() })
    }

    // MARK: Purchase and restore

    /// Buys `offer`, re-checking that its product is still the full-library unlock.
    public func purchase(_ offer: UnlockOffer) async throws -> PurchaseOutcome {
        try await queue.enqueue { [self] () async throws -> PurchaseOutcome in
            guard try await configureIfNeeded() else { throw BillingError.missingStoreForAction }
            guard RevenueCatKey.matchesStoreProduct(offer.productIdentifier, Brand.Products.fullLibrary) else {
                throw BillingError.unlockUnavailable
            }
            do {
                return .completed(try await client.purchase(offer.package))
            } catch PurchasesClientError.purchaseCancelled {
                return .cancelled
            } catch PurchasesClientError.paymentPending {
                return .pending
            }
        }.value
    }

    /// Restores purchases. Call only from a person's tap: the store may show an Apple sign-in prompt.
    public func restore() async throws -> CustomerSnapshot {
        try await queue.enqueue { [self] () async throws -> CustomerSnapshot in
            guard try await configureIfNeeded() else { throw BillingError.missingStoreForAction }
            return try await client.restorePurchases()
        }.value
    }

    /// The current CustomerInfo, or nil when billing is not connected in this build.
    public func customerInfo() async throws -> CustomerSnapshot? {
        try await queue.enqueue { [self] () async throws -> CustomerSnapshot? in
            guard try await configureIfNeeded() else { return nil }
            return try await client.customerInfo()
        }.value
    }

    /// RevenueCat's CustomerInfo updates (Ask to Buy approvals, refunds, promoted purchases).
    /// Finishes at once when the SDK is not configured, so call ``start()`` first.
    public func customerInfoUpdates() async -> AsyncStream<CustomerSnapshot> {
        await client.customerInfoUpdates()
    }

    /// Waits until every store operation enqueued so far has settled. For tests.
    public func drain() async {
        _ = await queue.enqueue {}.result
    }

    // MARK: Internals

    /// Runs only inside the queue.
    private func configureIfNeeded() async throws -> Bool {
        guard let key = try sdkKey() else { return false }
        if let configured = state.withLock({ $0.configuredKey }) {
            guard configured == key else { throw BillingError.storeSettingChanged }
            return true
        }
        await client.configure(apiKey: key, appUserID: nil)
        state.withLock { $0.configuredKey = key }
        return true
    }
}
