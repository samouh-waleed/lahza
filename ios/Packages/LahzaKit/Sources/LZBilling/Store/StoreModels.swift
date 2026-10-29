import LZCore
import Foundation
import Synchronization

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
    /// The store's display name.
    public var localizedTitle: String

    public init(identifier: String, localizedPrice: String, price: Decimal, currencyCode: String? = nil, localizedTitle: String = "") {
        self.identifier = identifier
        self.localizedPrice = localizedPrice
        self.price = price
        self.currencyCode = currencyCode
        self.localizedTitle = localizedTitle
    }
}

/// A RevenueCat package (`$rc_lifetime`, or a custom id) with its product.
public struct StorePackage: Sendable, Equatable {
    /// RevenueCat's id for a lifetime package.
    public static let lifetimeIdentifier = "$rc_lifetime"

    /// The package id (`$rc_lifetime`, …).
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

/// A RevenueCat offering: its packages, in the order RevenueCat lists them.
public struct StoreOffering: Sendable, Equatable {
    public var identifier: String
    public var packages: [StorePackage]

    public init(identifier: String, packages: [StorePackage] = []) {
        self.identifier = identifier
        self.packages = packages
    }
}

/// The parts of RevenueCat's `CustomerInfo` the app uses.
public struct CustomerSnapshot: Sendable, Equatable {
    /// The RevenueCat app user this CustomerInfo belongs to, as ``CustomerInfoOwnership`` attributed
    /// it; never RevenueCat's `originalAppUserId`, which is an anonymous alias for an account first
    /// identified after a sign-out on the device.
    public var appUserID: String
    /// Active entitlement ids. A non-consumable's entitlement stays active unless the purchase is
    /// refunded or revoked.
    public var activeEntitlements: Set<String>
    /// RevenueCat's `originalAppUserId`. After a sign-out and a first sign-in of a new account on the
    /// same device it is a `$RCAnonymousID:` alias, never the logged-in app user id.
    public var originalAppUserID: String?
    /// When RevenueCat fetched this CustomerInfo (`CustomerInfo.requestDate`); nil when unknown.
    public var requestDate: Date?

    public init(appUserID: String, activeEntitlements: Set<String> = [], originalAppUserID: String? = nil, requestDate: Date? = nil) {
        self.appUserID = appUserID
        self.activeEntitlements = activeEntitlements
        self.originalAppUserID = originalAppUserID
        self.requestDate = requestDate
    }

    /// The configured entitlement is active: the full library is unlocked.
    public func unlocks(entitlement: String = Brand.fullLibraryEntitlement) -> Bool {
        activeEntitlements.contains(entitlement)
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
                return original == originalAppUserID ? current : originalAppUserID
            }
            if state.learning {
                // Right after `configure` nothing else was identified in this process. A non-anonymous
                // original that is another id is still never this account's.
                if !originalAppUserID.isEmpty, !CustomerSnapshot.isAnonymousAppUserID(originalAppUserID), originalAppUserID != current {
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
    /// The store charged.
    case completed(CustomerSnapshot)
    /// The person closed the store sheet (`purchaseCancelledError`).
    case cancelled
    /// Ask to Buy or another deferred payment (`paymentPendingError`). The paywall shows a notice.
    case pending
}
