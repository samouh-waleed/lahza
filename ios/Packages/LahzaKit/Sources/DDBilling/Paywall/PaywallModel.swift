import DDCore
import Foundation
import Observation

/// The paywall's state: store prices, the selected plan, purchase, restore and management. The
/// entitlement RevenueCat reports after a purchase or restore is the only thing that unlocks Plus
/// (``EntitlementStore``).
@MainActor @Observable public final class PaywallModel {
    /// What the paywall is doing.
    public enum Phase: Equatable {
        /// Prices not requested yet (Settings uses the model only to restore and manage).
        case idle
        case loading
        case ready
        /// Prices could not be read; the message says why, and the person can retry.
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
            case .purchased: BillingCopy.plusActiveNotice
            case .restored: BillingCopy.plusActiveNotice
            case .pending: BillingCopy.purchasePending
            case .cancelled: BillingCopy.purchaseCancelled
            case .nothingToRestore: BillingCopy.noActiveSubscription
            case .failed(let message): message
            }
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var catalog: PlusCatalog = .empty
    public private(set) var notice: Notice?
    public var selectedPeriod: PlusPeriod = .annual

    @ObservationIgnored private let purchases: PurchasesService
    @ObservationIgnored private let entitlement: EntitlementStore
    @ObservationIgnored private let environment: BillingEnvironment
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored public let formatting: BillingFormatting

    public init(
        purchases: PurchasesService,
        entitlement: EntitlementStore,
        environment: BillingEnvironment,
        clock: any AppClock = SystemClock(),
        formatting: BillingFormatting = BillingFormatting()
    ) {
        self.purchases = purchases
        self.entitlement = entitlement
        self.environment = environment
        self.clock = clock
        self.formatting = formatting
    }

    // MARK: Derived

    /// The selected plan's offer, else the first available one.
    public var selectedOffer: PlusOffer? { catalog.offer(for: selectedPeriod) ?? catalog.offers.first }
    /// The free-trial timeline for the selected offer (nil without a confirmed trial).
    public var trialTimeline: TrialTimeline? { TrialTimeline.make(offer: selectedOffer, now: clock.now, formatting: formatting) }
    /// A purchase or restore is running (loading prices never blocks Restore).
    public var isBusy: Bool { phase == .purchasing || phase == .restoring }
    public var isUnlocked: Bool { entitlement.isUnlocked }
    /// Debug builds with a RevenueCat Test Store key: "Test purchases only. No money will be charged."
    public var usesTestStore: Bool { environment.usesTestStore }
    public var termsURL: URL { environment.termsURL }
    public var privacyURL: URL { environment.privacyURL }

    /// The primary button's title for the selected offer.
    public var purchaseTitle: String {
        if let trial = selectedOffer?.trial { return BillingCopy.startTrial(trial.duration) }
        return BillingCopy.subscribe
    }

    // MARK: Actions

    /// Reads store prices (annual preselected when present).
    public func load() async {
        phase = .loading
        do {
            let loaded = try await purchases.offers()
            catalog = loaded
            if loaded.offer(for: selectedPeriod) == nil, let first = loaded.offers.first { selectedPeriod = first.period }
            phase = loaded.isEmpty ? .unavailable(BillingCopy.storePlansUnavailable) : .ready
        } catch {
            phase = .unavailable(StoreMessage.text(for: error))
        }
    }

    public func select(_ period: PlusPeriod) {
        guard catalog.offer(for: period) != nil else { return }
        selectedPeriod = period
    }

    /// Buys the selected offer.
    public func purchase() async {
        guard let offer = selectedOffer, !isBusy, phase != .loading else { return }
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

    /// Restores purchases (only from a tap).
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

    /// Shows the App Store's manage-subscriptions sheet. False when it could not be shown (the caller
    /// shows ``BillingCopy/manageFallback``).
    public func manageSubscription() async -> Bool {
        do {
            try await purchases.showManageSubscriptions()
            return true
        } catch {
            return false
        }
    }

    public func clearNotice() { notice = nil }
}
