import Foundation
import Testing
@testable import LZGeo

/// Local dates in the iPhone's own format (Moments and search share them); the spec's examples are day first (UK).
@Suite struct LocalDateFormatTests {
    let uk = Locale(identifier: "en_GB")
    let us = Locale(identifier: "en_US")
    let thin = "\u{2009}–\u{2009}"

    @Test func daysMonthsAndRanges() {
        let day = LocalTime.day(year: 2026, month: 8, day: 22)
        #expect(LocalDateFormat.dayTitle(day, locale: uk) == "Sat, 22 Aug 2026")
        #expect(LocalDateFormat.dayTitle(day, locale: us) == "Sat, Aug 22, 2026")
        #expect(LocalDateFormat.day(day, locale: uk) == "22 Aug 2026")
        #expect(LocalDateFormat.monthTitle(year: 2025, month: 12, locale: uk) == "December 2025")
        #expect(LocalDateFormat.shortMonth(year: 2025, month: 12, locale: uk) == "Dec 2025")
        #expect(LocalDateFormat.monthName(6, locale: uk) == "June")
        #expect(LocalDateFormat.weekdayName(7, locale: uk) == "Saturday")
        #expect(LocalDateFormat.weekdayName(1, locale: uk) == "Sunday")
        #expect(LocalDateFormat.monthRange(from: (2026, 6), to: (2026, 8), locale: uk) == "Jun\(thin)Aug 2026")
        #expect(LocalDateFormat.monthRange(from: (2025, 12), to: (2026, 2), locale: uk) == "Dec 2025\(thin)Feb 2026")
        #expect(LocalDateFormat.monthRange(from: (2025, 12), to: (2025, 12), locale: uk) == "Dec 2025")
        let first = LocalTime.day(year: 2024, month: 3, day: 11), last = LocalTime.day(year: 2024, month: 4, day: 9)
        #expect(LocalDateFormat.dayRange(first, last, locale: uk) == "11 Mar\(thin)9 Apr 2024")
        #expect(LocalDateFormat.dayRange(first, last, locale: us) == "Mar 11\(thin)Apr 9, 2024")
        #expect(LocalDateFormat.dayRange(first, first, locale: uk) == "11 Mar 2024")
    }

    @Test func recentDaysAreNamedAndThisYearDropsTheYear() {
        let today = LocalTime.day(year: 2026, month: 10, day: 28)
        #expect(LocalDateFormat.recentDay(today, today: today, locale: uk) == "Today")
        #expect(LocalDateFormat.recentDay(today - 1, today: today, locale: uk) == "Yesterday")
        #expect(LocalDateFormat.recentDay(LocalTime.day(year: 2026, month: 10, day: 24), today: today, locale: uk) == "Saturday")
        #expect(LocalDateFormat.recentDay(LocalTime.day(year: 2026, month: 8, day: 22), today: today, locale: uk) == "Sat 22 Aug")
        #expect(LocalDateFormat.recentDay(LocalTime.day(year: 2026, month: 8, day: 22), today: today, locale: us) == "Sat, Aug 22")
        #expect(LocalDateFormat.recentDay(LocalTime.day(year: 2025, month: 6, day: 14), today: today, locale: uk) == "Sat, 14 Jun 2025")
    }

    @Test func dateOrderFollowsTheRegion() {
        #expect(!LocalDateFormat.monthComesFirst(uk) && LocalDateFormat.monthComesFirst(us))
        #expect(!LocalDateFormat.numericMonthComesFirst(uk) && LocalDateFormat.numericMonthComesFirst(us))
    }
}
