import LZCore
import Foundation
import Observation

/// Whether this device has unlocked the full library, from RevenueCat's active entitlement. The last
/// answer is mirrored into kv so an offline launch keeps the right state; the store's answer always
/// wins. Free search covers the most recent ``Brand/Limits/freeSearchMonths`` months; the one-time
/// unlock opens every year (decisions 17 and 32). The Moments timeline is free either way.
@MainActor @Observable public final class EntitlementStore {
    public enum Status: String, Sendable, Equatable {
        /// Billing has not answered yet on this install (and no cached answer exists). Counts as free.
        case unknown
        case free
        case unlocked
    }

    public private(set) var status: Status

    /// The full library is unlocked: search covers every year.
    public var isUnlocked: Bool { status == .unlocked }

    @ObservationIgnored private let kv: any KeyValueStore
    @ObservationIgnored private let entitlement: String
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private let log = Log("billing")

    public init(kv: any KeyValueStore, entitlementIdentifier: String = Brand.fullLibraryEntitlement) {
        self.kv = kv
        entitlement = entitlementIdentifier
        status = kv.string(forKey: Self.cacheKey).flatMap(Status.init(rawValue:)) ?? .unknown
    }

    static let cacheKey = KVKey.device(KVSuffix.entitlementCache)

    /// The earliest capture date search covers: the start of the day ``Brand/Limits/freeSearchMonths``
    /// months before `now` (whole days, so a day's searches and example counts cover the same
    /// photos), or nil once the full library is unlocked (every year).
    public func searchStart(now: Date, calendar: Calendar = .current) -> Date? {
        guard !isUnlocked else { return nil }
        return calendar.date(byAdding: .month, value: -Brand.Limits.freeSearchMonths, to: now).map(calendar.startOfDay)
    }

    /// Applies a CustomerInfo answer and caches the result.
    public func apply(_ snapshot: CustomerSnapshot) {
        status = snapshot.unlocks(entitlement: entitlement) ? .unlocked : .free
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
