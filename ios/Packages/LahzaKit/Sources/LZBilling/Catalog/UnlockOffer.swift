import LZCore
import Foundation

/// The full-library unlock as the store sells it: one non-consumable, bought once (decision 32).
public struct UnlockOffer: Sendable, Equatable {
    public var package: StorePackage

    public init(package: StorePackage) {
        self.package = package
    }

    /// The price, verbatim from the store.
    public var priceString: String { package.product.localizedPrice }

    /// The product id.
    public var productIdentifier: String { package.product.identifier }

    /// The unlock in `offering`: the package whose product is ``Brand/Products/fullLibrary``,
    /// RevenueCat's lifetime package first. Nil when the offering does not sell it.
    public static func find(in offering: StoreOffering?) -> UnlockOffer? {
        let matching = (offering?.packages ?? []).filter {
            RevenueCatKey.matchesStoreProduct($0.product.identifier, Brand.Products.fullLibrary)
        }
        let package = matching.first { $0.identifier == StorePackage.lifetimeIdentifier } ?? matching.first
        return package.map(UnlockOffer.init(package:))
    }
}
