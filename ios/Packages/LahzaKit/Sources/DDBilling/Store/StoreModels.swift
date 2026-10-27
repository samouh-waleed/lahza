import DDCore
import Foundation
import Synchronization

/// A subscription or offer period: `value` × `unit` (StoreKit's `Product.SubscriptionPeriod`,
/// RevenueCat's `SubscriptionPeriod`).
public struct StorePeriod: Sendable, Equatable, Hashable {
    /// The unit, with RevenueCat's names (`DAY`, `WEEK`, `MONTH`, `YEAR`) as raw values.
    public enum Unit: String, Sendable, CaseIterable {
        case day = "DAY"
        case week = "WEEK"
        case month = "MONTH"
        case year = "YEAR"

        /// The singular English word used in trial copy (`day`, `week`, `month`, `year`).
        public var word: String {
            switch self {
            case .day: "day"
            case .week: "week"
            case .month: "month"
            case .year: "year"
            }
        }
    }

    public var value: Int
    public var unit: Unit

    public init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }

    /// The period as calendar components (a week is 7 days).
    public var dateComponents: DateComponents {
        switch unit {
        case .day: DateComponents(day: value)
        case .week: DateComponents(day: value * 7)
        case .month: DateComponents(month: value)
        case .year: DateComponents(year: value)
        }
    }

    /// The period's length in words (`1 year`, `1 month`, `3 months`, `1 week`).
    public var lengthDescription: String { "\(value) \(unit.word)\(value == 1 ? "" : "s")" }

    /// What follows a price's slash (`year` for one year, `3 months` for a quarter).
    public var perDescription: String { value == 1 ? unit.word : lengthDescription }

    /// Whole months in the period (nil for day and week periods).
    public var months: Int? {
        switch unit {
        case .month: value
        case .year: value * 12
        case .day, .week: nil
        }
    }
}

/// An introductory offer's terms as the store reports them (`StoreProductDiscount`).
public struct IntroOfferTerms: Sendable, Equatable {
    /// How the introduction is paid.
    public enum PaymentMode: String, Sendable {
        case freeTrial
        case payAsYouGo
        case payUpFront
    }

    public var paymentMode: PaymentMode
    /// The price per cycle (0 for a free trial).
    public var price: Decimal
    /// The store's localized price per cycle.
    public var localizedPrice: String
    /// One cycle. Nil when the store reported a unit this build does not know (no trial then).
    public var period: StorePeriod?
    /// The number of cycles.
    public var numberOfPeriods: Int

    public init(paymentMode: PaymentMode, price: Decimal, localizedPrice: String, period: StorePeriod?, numberOfPeriods: Int) {
        self.paymentMode = paymentMode
        self.price = price
        self.localizedPrice = localizedPrice
        self.period = period
        self.numberOfPeriods = numberOfPeriods
    }

    /// A zero-price introduction.
    public var isFree: Bool { price == 0 }
}

/// A store product as the paywall needs it (`StoreProduct`).
public struct StoreProductInfo: Sendable, Equatable {
    /// The App Store product id.
    public var identifier: String
    /// The store's localized price, shown verbatim.
    public var localizedPrice: String
    /// The numeric price in the storefront currency.
    public var price: Decimal
    /// ISO 4217 currency code, when the store reports one.
    public var currencyCode: String?
    /// The storefront locale the store formatted the price in.
    public var priceLocale: Locale?
    /// The renewal period.
    public var subscriptionPeriod: StorePeriod?
    /// The introductory offer, whether or not this person is eligible for it.
    public var introOffer: IntroOfferTerms?
    /// The store's display name.
    public var localizedTitle: String

    public init(
        identifier: String,
        localizedPrice: String,
        price: Decimal,
        currencyCode: String? = nil,
        priceLocale: Locale? = nil,
        subscriptionPeriod: StorePeriod? = nil,
        introOffer: IntroOfferTerms? = nil,
        localizedTitle: String = ""
    ) {
        self.identifier = identifier
        self.localizedPrice = localizedPrice
        self.price = price
        self.currencyCode = currencyCode
        self.priceLocale = priceLocale
        self.subscriptionPeriod = subscriptionPeriod
        self.introOffer = introOffer
        self.localizedTitle = localizedTitle
    }
}

/// A RevenueCat package (`$rc_monthly`, `$rc_annual`) with its product.
public struct StorePackage: Sendable, Equatable {
    /// The package id (`$rc_monthly`, `$rc_annual`, …).
    public var identifier: String
    /// The offering the package belongs to.
    public var offeringIdentifier: String
    public var product: StoreProductInfo

    public init(identifier: String, offeringIdentifier: String, product: StoreProductInfo) {
        self.identifier = identifier
        self.offeringIdentifier = offeringIdentifier
        self.product = product
    }
}

/// A RevenueCat offering, reduced to the two packages Lahza sells.
public struct StoreOffering: Sendable, Equatable {
    public var identifier: String
    public var monthly: StorePackage?
    public var annual: StorePackage?

    public init(identifier: String, monthly: StorePackage? = nil, annual: StorePackage? = nil) {
        self.identifier = identifier
        self.monthly = monthly
        self.annual = annual
    }
}

/// The Plus products as StoreKit reports them, without a RevenueCat identity (see
/// ``PurchasesClient/previewOffering(productIdentifiers:)``).
public struct StorePreview: Sendable, Equatable {
    /// The monthly and annual packages found (either may be missing).
    public var offering: StoreOffering
    /// The store's intro-offer answer per product id (missing means unknown).
    public var eligibility: [String: IntroEligibilityStatus]

    public init(offering: StoreOffering, eligibility: [String: IntroEligibilityStatus]) {
        self.offering = offering
        self.eligibility = eligibility
    }
}

/// RevenueCat's `IntroEligibilityStatus` (same raw values).
public enum IntroEligibilityStatus: Int, Sendable, Equatable {
    case unknown = 0
    case ineligible = 1
    case eligible = 2
    case noIntroOfferExists = 3
}

/// The parts of RevenueCat's `CustomerInfo` the app uses.
public struct CustomerSnapshot: Sendable, Equatable {
    /// The RevenueCat app user this CustomerInfo belongs to, as ``CustomerInfoOwnership`` attributed
    /// it; never RevenueCat's `originalAppUserId`, which is an anonymous alias for an account first
    /// identified after a sign-out on the device.
    public var appUserID: String
    /// Active entitlement ids.
    public var activeEntitlements: Set<String>
    /// The App Store management page for this customer.
    public var managementURL: URL?
    /// RevenueCat's `originalAppUserId`. After a sign-out and a first sign-in of a new account on the
    /// same device it is a `$RCAnonymousID:` alias, never the logged-in app user id.
    public var originalAppUserID: String?
    /// Active entitlements whose automatic renewal is off (`EntitlementInfo.willRenew == false`): the
    /// person cancelled, and access continues until the period (or the free trial) ends.
    public var nonRenewingEntitlements: Set<String>
    /// Active entitlements in a free trial (`EntitlementInfo.periodType == .trial`).
    public var trialEntitlements: Set<String>
    /// When RevenueCat fetched this CustomerInfo (`CustomerInfo.requestDate`); nil when unknown.
    public var requestDate: Date?

    public init(
        appUserID: String,
        activeEntitlements: Set<String> = [],
        managementURL: URL? = nil,
        originalAppUserID: String? = nil,
        nonRenewingEntitlements: Set<String> = [],
        trialEntitlements: Set<String> = [],
        requestDate: Date? = nil
    ) {
        self.appUserID = appUserID
        self.activeEntitlements = activeEntitlements
        self.managementURL = managementURL
        self.originalAppUserID = originalAppUserID
        self.nonRenewingEntitlements = nonRenewingEntitlements
        self.trialEntitlements = trialEntitlements
        self.requestDate = requestDate
    }

    /// `plus` when the configured entitlement is active, else `free`.
    public func plan(entitlement: String = Brand.plusEntitlement) -> String {
        activeEntitlements.contains(where: { jsStringEqual($0, entitlement) }) ? "plus" : "free"
    }

    /// The entitlement is active **and** will renew. False once the person cancelled (even while the
    /// trial or period still runs) or it lapsed.
    public func renews(entitlement: String = Brand.plusEntitlement) -> Bool {
        plan(entitlement: entitlement) == "plus" && !nonRenewingEntitlements.contains(where: { jsStringEqual($0, entitlement) })
    }

    /// The entitlement is active in a free trial. If the trial was redeemed elsewhere after the prices
    /// loaded, Apple charges at once and there is no trial.
    public func isInTrial(entitlement: String = Brand.plusEntitlement) -> Bool {
        plan(entitlement: entitlement) == "plus" && trialEntitlements.contains(where: { jsStringEqual($0, entitlement) })
    }

    /// RevenueCat's anonymous id (`/\$RCAnonymousID:([a-z0-9]{32})$/`, `IdentityManager.anonymousRegex`).
    public static func isAnonymousAppUserID(_ id: String) -> Bool {
        let marker = Array("$RCAnonymousID:".utf16)
        let units = Array(id.utf16)
        guard units.count >= marker.count + 32 else { return false }
        let suffix = units[(units.count - 32)...]
        guard Array(units[(units.count - 32 - marker.count)..<(units.count - 32)]) == marker else { return false }
        return suffix.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x7A).contains($0) }
    }
}

/// Who a streamed CustomerInfo belongs to, per identity epoch.
///
/// RevenueCat's `originalAppUserId` is not the signed-in user after a sign-out: `logOut` switches the
/// SDK to a fresh `$RCAnonymousID:…`, and the next `logIn(B)` for an account RevenueCat has never seen
/// aliases that anonymous id into B, so B's `originalAppUserId` stays the anonymous id
/// (purchases-ios `IdentityManager`). Tagging a CustomerInfo with the SDK's identity when it *arrives*
/// is not enough either: account A's CustomerInfo can be delivered after `logIn(B)`.
///
/// So each identify records the original id RevenueCat reported for the new identity (`logIn`'s
/// CustomerInfo; after `configure`, the first CustomerInfo, since nothing else was identified in the
/// process), and a CustomerInfo counts for the current account only when its `originalAppUserId`
/// matches that record. Anything else keeps its own `originalAppUserId` as owner (which never equals
/// another signed-in account), including every CustomerInfo that arrives while an identity change
/// is in flight.
public final class CustomerInfoOwnership: Sendable {
    private struct State {
        var current: String?
        var original: String?
        /// Right after `configure`: the first CustomerInfo's original id is this identity's.
        var learning = false
        var epoch: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Incremented on every identity change (diagnostics and tests).
    public var epoch: UInt64 { state.withLock { $0.epoch } }

    /// The identity CustomerInfo is attributed to now (nil while signed out or switching).
    public var currentAppUserID: String? { state.withLock { $0.current } }

    /// `configure(appUserID:)` ran: the first identity in the process.
    public func configured(appUserID: String) {
        state.withLock {
            $0.current = appUserID
            $0.original = nil
            $0.learning = true
            $0.epoch &+= 1
        }
    }

    /// A `logIn` or `logOut` started: nothing is attributed until it finishes.
    public func beginChange() {
        state.withLock {
            $0.current = nil
            $0.original = nil
            $0.learning = false
            $0.epoch &+= 1
        }
    }

    /// `logIn(appUserID)` returned RevenueCat's CustomerInfo for the new identity.
    public func identified(appUserID: String, originalAppUserID: String) {
        state.withLock {
            $0.current = appUserID
            $0.original = originalAppUserID
            $0.learning = false
            $0.epoch &+= 1
        }
    }

    /// The owner of a CustomerInfo whose `originalAppUserId` is `originalAppUserID`.
    public func owner(originalAppUserID: String) -> String {
        state.withLock { state in
            guard let current = state.current else { return originalAppUserID }
            if let original = state.original {
                return jsStringEqual(original, originalAppUserID) ? current : originalAppUserID
            }
            if state.learning {
                // Right after `configure` nothing else was identified in this process. A non-anonymous
                // original that is another id is still never this account's.
                if !originalAppUserID.isEmpty, !CustomerSnapshot.isAnonymousAppUserID(originalAppUserID), !jsStringEqual(originalAppUserID, current) {
                    return originalAppUserID
                }
                state.original = originalAppUserID
                state.learning = false
                return current
            }
            return originalAppUserID
        }
    }
}

/// How a purchase ended.
public enum PurchaseOutcome: Sendable, Equatable {
    /// The store charged (or started the trial).
    case completed(CustomerSnapshot)
    /// The person closed the store sheet (`purchaseCancelledError`).
    case cancelled
    /// Ask to Buy or another deferred payment (`paymentPendingError`). The paywall shows a notice.
    case pending
}
