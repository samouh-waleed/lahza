#if canImport(StoreKit)
import LZCore
import Foundation
import StoreKit

/// Plus prices and intro-offer eligibility straight from StoreKit 2. The App Store answers for the
/// device's Apple Account, which is exactly whose free trial it is; no RevenueCat identity is
/// involved, and nothing can be bought here (purchases run through ``PurchasesService``).
enum StoreKitPreview {
    static func offering(productIdentifiers: [String]) async throws -> StorePreview {
        let products: [Product]
        do {
            products = try await Product.products(for: productIdentifiers)
        } catch {
            throw PurchasesClientError.store(code: 0, message: error.localizedDescription)
        }
        var offering = StoreOffering(identifier: Brand.Products.offering)
        var eligibility: [String: IntroEligibilityStatus] = [:]
        for product in products {
            let package = StorePackage(
                identifier: RevenueCatKey.matchesStoreProduct(product.id, Brand.Products.plusAnnual) ? "$rc_annual" : "$rc_monthly",
                offeringIdentifier: Brand.Products.offering,
                product: info(product)
            )
            if RevenueCatKey.matchesStoreProduct(product.id, Brand.Products.plusAnnual) {
                offering.annual = package
            } else if RevenueCatKey.matchesStoreProduct(product.id, Brand.Products.plusMonthly) {
                offering.monthly = package
            }
            guard let subscription = product.subscription else { continue }
            if subscription.introductoryOffer == nil {
                eligibility[product.id] = .noIntroOfferExists
            } else {
                eligibility[product.id] = await subscription.isEligibleForIntroOffer ? .eligible : .ineligible
            }
        }
        return StorePreview(offering: offering, eligibility: eligibility)
    }

    static func info(_ product: Product) -> StoreProductInfo {
        StoreProductInfo(
            identifier: product.id,
            localizedPrice: product.displayPrice,
            price: product.price,
            currencyCode: product.priceFormatStyle.currencyCode,
            priceLocale: product.priceFormatStyle.locale,
            subscriptionPeriod: product.subscription.flatMap { period($0.subscriptionPeriod) },
            introOffer: product.subscription?.introductoryOffer.map { offer in
                IntroOfferTerms(
                    paymentMode: paymentMode(offer.paymentMode),
                    price: offer.price,
                    localizedPrice: offer.displayPrice,
                    period: period(offer.period),
                    numberOfPeriods: offer.periodCount
                )
            },
            localizedTitle: product.displayName
        )
    }

    /// Nil for a unit this build does not know (no trial then).
    static func period(_ period: Product.SubscriptionPeriod) -> StorePeriod? {
        let unit: StorePeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        return StorePeriod(value: period.value, unit: unit)
    }

    static func paymentMode(_ mode: Product.SubscriptionOffer.PaymentMode) -> IntroOfferTerms.PaymentMode {
        if mode == .freeTrial { return .freeTrial }
        if mode == .payUpFront { return .payUpFront }
        return .payAsYouGo
    }
}
#endif
