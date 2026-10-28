import LZCore
import Foundation

/// The free-trial timeline built from the **live** introductory offer, shown only when the store
/// confirmed eligibility: Today → the first charge. The billed price stays the prominent one. (No
/// reminder step: Lahza sends no notifications, so the timeline never implies one.)
public struct TrialTimeline: Sendable, Equatable {
    /// One step on the timeline.
    public struct Step: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case start
            case billing
        }

        public var kind: Kind
        public var date: Date
        /// "Today", or the step's date ("Oct 6").
        public var title: String
        public var detail: String
    }

    public var trial: FreeTrial
    public var period: PlusPeriod
    /// The billed price (verbatim store string).
    public var priceString: String
    /// The store's renewal period for the product (``PlusOffer/billingPeriod``).
    public var billingPeriod: StorePeriod
    /// The trial starts now.
    public var startsAt: Date
    /// When the trial ends and the first charge happens (start + trial length).
    public var billingAt: Date
    /// Today, then billing.
    public var steps: [Step]
    /// `"1 week free, then $39.99 / year"`.
    public var summary: String

    /// The timeline for `offer`, or nil without a confirmed trial.
    public static func make(offer: PlusOffer?, now: Date, formatting: BillingFormatting) -> TrialTimeline? {
        guard let offer, let trial = offer.trial else { return nil }
        let calendar = formatting.calendar
        guard let billingAt = calendar.date(byAdding: trial.length, to: now) else { return nil }
        var steps = [Step(kind: .start, date: now, title: "Today", detail: "Your free trial of \(Brand.name) Plus starts.")]
        steps.append(Step(
            kind: .billing,
            date: billingAt,
            title: formatting.shortDate(billingAt),
            detail: "You’ll be charged \(offer.billedPriceText) unless you cancel at least 24 hours before."
        ))
        return TrialTimeline(
            trial: trial,
            period: offer.period,
            priceString: offer.priceString,
            billingPeriod: offer.billingPeriod,
            startsAt: now,
            billingAt: billingAt,
            steps: steps,
            summary: "\(trial.duration) free, then \(offer.billedPriceText)"
        )
    }
}

/// Dates and prices in the person's locale and time zone.
public struct BillingFormatting: Sendable, Equatable {
    public var locale: Locale
    public var timeZone: TimeZone

    public init(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        self.locale = locale
        self.timeZone = timeZone
    }

    /// A Gregorian calendar in ``timeZone`` (store periods are Gregorian).
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    /// `date` as a numeric date (`10/1/2026` in en-US).
    public func numericDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone))
    }

    /// A short month-and-day date (`Oct 6` in en-US).
    public func shortDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).month(.abbreviated).day())
    }
}
