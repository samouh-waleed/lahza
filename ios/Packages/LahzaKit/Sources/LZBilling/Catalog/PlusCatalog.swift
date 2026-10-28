import LZCore
import Foundation

/// The two Plus billing periods.
public enum PlusPeriod: String, Sendable, CaseIterable, Equatable, Hashable {
    case monthly
    case annual

    /// The product this period must map to (``Brand/Products/plusMonthly`` / ``Brand/Products/plusAnnual``).
    public var productIdentifier: String {
        switch self {
        case .monthly: Brand.Products.plusMonthly
        case .annual: Brand.Products.plusAnnual
        }
    }

    /// The picker's `unit` (`month` / `year`).
    public var unitWord: String {
        switch self {
        case .monthly: "month"
        case .annual: "year"
        }
    }

    /// Card title (`Monthly` / `Yearly`).
    public var title: String {
        switch self {
        case .monthly: "Monthly"
        case .annual: "Yearly"
        }
    }
}

/// A free introduction this person is confirmed eligible for.
public struct FreeTrial: Sendable, Equatable {
    /// `units` × `unit`, for example 7 days or 1 week.
    public var units: Int
    public var unit: StorePeriod.Unit

    public init(units: Int, unit: StorePeriod.Unit) {
        self.units = units
        self.unit = unit
    }

    /// The length in words: `"7 days"`, `"1 week"`, `"2 months"`.
    public var duration: String { "\(units) \(unit.word)\(units == 1 ? "" : "s")" }

    /// The trial length as calendar components.
    public var length: DateComponents { StorePeriod(value: units, unit: unit).dateComponents }

    /// A trial exists only when the introduction is free **and** the
    /// eligibility check answered exactly `eligible`, with a known unit and a positive, safe unit
    /// count (`periodNumberOfUnits × cycles`). Unknown, failed or missing eligibility means no trial.
    public static func confirmed(intro: IntroOfferTerms?, eligibility: IntroEligibilityStatus?) -> FreeTrial? {
        guard let intro, intro.isFree, eligibility == .eligible, let period = intro.period else { return nil }
        let (units, overflow) = period.value.multipliedReportingOverflow(by: intro.numberOfPeriods)
        guard !overflow, units > 0, units <= 9_007_199_254_740_991 else { return nil }
        return FreeTrial(units: units, unit: period.unit)
    }
}

/// One purchasable Plus option.
public struct PlusOffer: Sendable, Equatable {
    public var period: PlusPeriod
    public var package: StorePackage
    /// Present only when the store confirmed eligibility for a zero-price introduction.
    public var trial: FreeTrial?

    public init(period: PlusPeriod, package: StorePackage, trial: FreeTrial? = nil) {
        self.period = period
        self.package = package
        self.trial = trial
    }

    /// The billed price, verbatim from the store. Always the most prominent price.
    public var priceString: String { package.product.localizedPrice }

    /// The product id.
    public var productIdentifier: String { package.product.identifier }

    /// The introductory offer as the store reports it (whether or not this person is eligible).
    public var introOffer: IntroOfferTerms? { package.product.introOffer }

    /// The renewal period the store reports for the product, else the period's own (1 month,
    /// 1 year). Every disclosure (timeline, 3.1.2 text) states the length from this.
    public var billingPeriod: StorePeriod {
        package.product.subscriptionPeriod ?? StorePeriod(value: 1, unit: period == .annual ? .year : .month)
    }

    /// The billed price per store period: `$39.99 / year`, or `$14.99 / 3 months`.
    public var billedPriceText: String { "\(priceString) / \(billingPeriod.perDescription)" }

    /// The per-month equivalent of a multi-month plan (annual: price ÷ 12, rounded down to the
    /// currency's minor unit), formatted in the storefront's currency. Nil for monthly plans or when the
    /// store gave no period, currency or locale. Always shown subordinate to ``priceString``.
    public var perMonthPrice: String? {
        let product = package.product
        guard let months = billingPeriod.months,
              months > 1,
              let format = PriceFormat(currencyCode: product.currencyCode, locale: product.priceLocale) else { return nil }
        return format.string(format.roundedDown(product.price / Decimal(months)))
    }
}

/// The offering's purchasable options, monthly first.
public struct PlusCatalog: Sendable, Equatable {
    /// Monthly, then annual, each only when its product id matches.
    public var offers: [PlusOffer]

    public init(offers: [PlusOffer]) {
        self.offers = offers
    }

    /// No offers.
    public static let empty = PlusCatalog(offers: [])

    /// The offer for `period`.
    public func offer(for period: PlusPeriod) -> PlusOffer? {
        offers.first { $0.period == period }
    }

    public var monthly: PlusOffer? { offer(for: .monthly) }
    public var annual: PlusOffer? { offer(for: .annual) }
    public var isEmpty: Bool { offers.isEmpty }

    /// The mapped packages of `offering`: monthly when its product matches
    /// ``Brand/Products/plusMonthly``, annual when its product matches ``Brand/Products/plusAnnual``. No trials yet.
    public static func packages(in offering: StoreOffering?) -> [PlusOffer] {
        var result: [PlusOffer] = []
        if let monthly = offering?.monthly, RevenueCatKey.matchesStoreProduct(monthly.product.identifier, Brand.Products.plusMonthly) {
            result.append(PlusOffer(period: .monthly, package: monthly))
        }
        if let annual = offering?.annual, RevenueCatKey.matchesStoreProduct(annual.product.identifier, Brand.Products.plusAnnual) {
            result.append(PlusOffer(period: .annual, package: annual))
        }
        return result
    }

    /// The product ids whose introduction is free, in offer order. Only
    /// these are sent to the eligibility check.
    public static func freeIntroProductIds(_ offers: [PlusOffer]) -> [String] {
        offers.filter { $0.introOffer?.isFree == true }.map(\.productIdentifier)
    }

    /// Applies an eligibility answer (a missing product is unknown) to the free introductions.
    public static func applyingEligibility(_ offers: [PlusOffer], _ eligibility: [String: IntroEligibilityStatus]) -> [PlusOffer] {
        offers.map { offer in
            guard offer.introOffer?.isFree == true else { return offer }
            var copy = offer
            let status = eligibility[offer.productIdentifier]
            copy.trial = FreeTrial.confirmed(intro: offer.introOffer, eligibility: status)
            return copy
        }
    }
}

/// Formats amounts in a storefront currency (Sendable, unlike `NumberFormatter`).
public struct PriceFormat: Sendable, Equatable {
    public var currencyCode: String
    public var locale: Locale

    /// Nil without a currency code or locale.
    public init?(currencyCode: String?, locale: Locale?) {
        guard let currencyCode, !currencyCode.isEmpty, let locale else { return nil }
        self.currencyCode = currencyCode
        self.locale = locale
    }

    /// The currency's minor-unit digits in this locale (2 for USD, 0 for JPY, 3 for KWD).
    public var fractionDigits: Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        return formatter.maximumFractionDigits
    }

    /// `amount` rounded toward zero to the currency's minor unit (a per-unit price never overstates
    /// the discount).
    public func roundedDown(_ amount: Decimal) -> Decimal {
        var value = amount
        var result = Decimal()
        NSDecimalRound(&result, &value, fractionDigits, .down)
        return result
    }

    /// The amount as a currency string (`$3.33`).
    public func string(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: currencyCode).locale(locale))
    }
}
