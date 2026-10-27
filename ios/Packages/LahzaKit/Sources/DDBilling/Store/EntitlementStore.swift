import DDCore
import Foundation
import Observation

/// Whether this device has Lahza Plus, from RevenueCat's active entitlement. The last answer is
/// mirrored into kv so an offline launch keeps the right state; the store's answer always wins.
/// Free search covers the most recent ``Brand/Limits/freeSearchMonths`` months; Plus unlocks the
/// whole library (decision 17).
@MainActor @Observable public final class EntitlementStore {
    public enum Status: String, Sendable, Equatable {
        /// Billing has not answered yet on this install (and no cached answer exists).
        case unknown
        case free
        case plus
    }

    public private(set) var status: Status
    /// The entitlement is active in a free trial.
    public private(set) var isInTrial = false
    /// The entitlement is active and will renew (false once cancelled, even while it still runs).
    public private(set) var willRenew = false
    /// The App Store management page, when RevenueCat reports one.
    public private(set) var managementURL: URL?

    /// Plus is active: search covers the whole library.
    public var isUnlocked: Bool { status == .plus }

    @ObservationIgnored private let kv: any KeyValueStore
    @ObservationIgnored private let entitlement: String
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private let log = Log("billing")

    public init(kv: any KeyValueStore, entitlementIdentifier: String = Brand.plusEntitlement) {
        self.kv = kv
        entitlement = entitlementIdentifier
        status = kv.string(forKey: Self.cacheKey).flatMap(Status.init(rawValue:)) ?? .unknown
    }

    static let cacheKey = KVKey.device(KVSuffix.entitlementCache)

    /// Applies a CustomerInfo answer and caches the result.
    public func apply(_ snapshot: CustomerSnapshot) {
        let plus = snapshot.plan(entitlement: entitlement) == "plus"
        status = plus ? .plus : .free
        isInTrial = snapshot.isInTrial(entitlement: entitlement)
        willRenew = snapshot.renews(entitlement: entitlement)
        managementURL = snapshot.managementURL
        kv.setString(status.rawValue, forKey: Self.cacheKey)
    }

    /// Starts the store, reads the current entitlement and follows RevenueCat's updates. Without a
    /// store key the cached state stays (free search keeps working).
    public func start(with purchases: PurchasesService) async {
        do {
            guard try await purchases.start() else { return }
            if let info = try await purchases.customerInfo() { apply(info) }
        } catch {
            log.error("Entitlement refresh failed: \(error.localizedDescription)", privacy: .public)
        }
        updates?.cancel()
        let stream = await purchases.customerInfoUpdates()
        updates = Task { [weak self] in
            for await info in stream {
                self?.apply(info)
            }
        }
    }

    /// Stops following RevenueCat's updates.
    public func stop() {
        updates?.cancel()
        updates = nil
    }
}
