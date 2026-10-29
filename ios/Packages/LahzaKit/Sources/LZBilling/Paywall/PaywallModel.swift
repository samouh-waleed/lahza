import LZCore
import Foundation
import Observation

/// The paywall's state: the store price, purchase and restore of the one-time full-library unlock.
/// The entitlement RevenueCat reports after a purchase or restore is the only thing that unlocks
/// (``EntitlementStore``).
@MainActor @Observable public final class PaywallModel {
    /// What the paywall is doing.
    public enum Phase: Equatable {
        /// The price is not requested yet (Settings uses the model only to restore).
        case idle
        case loading
        case ready
        /// The price could not be read; the message says why, and the person can retry.
        case unavailable(String)
        case purchasing
        case restoring
    }

    /// The outcome of the last action, shown once.
    public enum Notice: Equatable {
        case purchased
        case restored
        case pending
        case cancelled
        case nothingToRestore
        case failed(String)

        public var message: String {
            switch self {
            case .purchased, .restored: BillingCopy.unlockedNotice
            case .pending: BillingCopy.purchasePending
            case .cancelled: BillingCopy.purchaseCancelled
            case .nothingToRestore: BillingCopy.nothingToRestore
            case .failed(let message): message
            }
        }
    }

    public private(set) var phase: Phase = .idle
    /// The unlock as the store sells it, once loaded.
    public private(set) var offer: UnlockOffer?
    public private(set) var notice: Notice?

    @ObservationIgnored private let purchases: PurchasesService
    @ObservationIgnored private let entitlement: EntitlementStore
    @ObservationIgnored private let environment: BillingEnvironment

    public init(purchases: PurchasesService, entitlement: EntitlementStore, environment: BillingEnvironment) {
        self.purchases = purchases
        self.entitlement = entitlement
        self.environment = environment
    }

    // MARK: Derived

    /// A purchase or restore is running (loading the price never blocks Restore).
    public var isBusy: Bool { phase == .purchasing || phase == .restoring }
    public var isUnlocked: Bool { entitlement.isUnlocked }
    /// Debug builds with a test store: "Test purchases only. No money will be charged."
    public var usesTestStore: Bool { environment.usesTestStore }
    public var termsURL: URL { environment.termsURL }
    public var privacyURL: URL { environment.privacyURL }

    /// The primary button's title, with the store's price once known.
    public var purchaseTitle: String {
        offer.map { BillingCopy.unlock(price: $0.priceString) } ?? BillingCopy.unlockWithoutPrice
    }

    /// The purchase button can be pressed.
    public var canPurchase: Bool { offer != nil && phase == .ready }

    // MARK: Actions

    /// Reads the store price.
    public func load() async {
        phase = .loading
        do {
            offer = try await purchases.unlockOffer()
            phase = offer == nil ? .unavailable(BillingCopy.storeUnavailable) : .ready
        } catch {
            phase = .unavailable(StoreMessage.text(for: error))
        }
    }

    /// Buys the unlock.
    public func purchase() async {
        guard let offer, canPurchase else { return }
        phase = .purchasing
        defer { if phase == .purchasing { phase = .ready } }
        do {
            switch try await purchases.purchase(offer) {
            case .completed(let customer):
                entitlement.apply(customer)
                notice = entitlement.isUnlocked ? .purchased : .failed(BillingCopy.purchaseReceivedNotActive)
            case .cancelled:
                notice = .cancelled
            case .pending:
                notice = .pending
            }
        } catch {
            notice = .failed(StoreMessage.text(for: error))
        }
    }

    /// Restores an earlier purchase (only from a tap).
    public func restore() async {
        guard !isBusy else { return }
        let previous = phase
        phase = .restoring
        defer { if phase == .restoring { phase = previous } }
        do {
            let customer = try await purchases.restore()
            entitlement.apply(customer)
            notice = entitlement.isUnlocked ? .restored : .nothingToRestore
        } catch {
            notice = .failed(StoreMessage.text(for: error))
        }
    }

    public func clearNotice() { notice = nil }
}
