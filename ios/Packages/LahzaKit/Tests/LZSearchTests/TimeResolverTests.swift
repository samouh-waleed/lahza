import Foundation
import LZGeo
import Testing
@testable import LZSearch

/// Time goldens at now = 2026-10-28T12:00+03:00 (search spec §9.1), from a Saudi home and from a Sydney home. Ranges are
/// local wall seconds; a day runs 04:00 → 04:00.
@Suite struct TimeResolverTests {
    private func constraint(_ text: String, _ resolver: TimeResolver = SearchFixture.saudi()) throws -> TimeConstraint {
        let query = SearchFixture.parse(text)
        return try #require(resolver.resolve(query.timeExpressions).constraint, "\(text)")
    }

    private func range(_ from: (Int, Int, Int, Int), _ to: (Int, Int, Int, Int)) -> Range<Int64> {
        SearchFixture.wall(from.0, from.1, from.2, from.3)..<SearchFixture.wall(to.0, to.1, to.2, to.3)
    }

    private let thin = "\u{2009}–\u{2009}"

    // MARK: Saudi home

    @Test func lastSummerWinterAndDecember() throws {
        let summer = try constraint("last summer")
        #expect(summer.ranges == [range((2026, 6, 1, 4), (2026, 9, 1, 4))])
        #expect(summer.label == "Last summer · Jun\(thin)Aug 2026")
        #expect(summer.tau == (summer.ranges![0].upperBound - summer.ranges![0].lowerBound) / 10, "a season fades over about 9 days")
        let winter = try constraint("last winter")
        #expect(winter.ranges == [range((2025, 12, 1, 4), (2026, 3, 1, 4))])
        #expect(winter.label == "Last winter · Dec 2025\(thin)Feb 2026")
        let december = try constraint("last December")
        #expect(december.ranges == [range((2025, 12, 1, 4), (2026, 1, 1, 4))])
        #expect(december.label == "Last December · Dec 2025")
        #expect(try constraint("December 2025").ranges == december.ranges)
    }

    @Test func ramadanStartsAt18OnTheEve() throws {
        let ramadan2024 = try constraint("Ramadan 2024")
        #expect(ramadan2024.ranges == [range((2024, 3, 10, 18), (2024, 4, 10, 4))])
        #expect(ramadan2024.label == "Ramadan 1445 · 11 Mar\(thin)9 Apr 2024")
        #expect(ramadan2024.tau == TimeResolver.day, "Hijri events fade over one day (moon sighting)")
        #expect(try constraint("Ramadan 1445").ranges == ramadan2024.ranges, "the Hijri year names the same Ramadan")
        let last = try constraint("last Ramadan")
        #expect(last.ranges == [range((2026, 2, 17, 18), (2026, 3, 20, 4))])
        #expect(last.label == "Ramadan 1447 · 18 Feb\(thin)19 Mar 2026")
        let twice = try constraint("Ramadan in 2030")
        #expect(twice.ranges == [range((2030, 1, 4, 18), (2030, 2, 4, 4)), range((2030, 12, 25, 18), (2031, 1, 24, 4))])
        #expect(twice.label == "Ramadan 2030 · 1451 and 1452")
        #expect(twice.isFuture)
    }

    @Test func hijriWindowsOf1445And1446() throws {
        let saudi = SearchFixture.saudi()
        func ranges(_ event: HijriEvent, _ year: Int) -> [Range<Int64>]? {
            saudi.resolve(.hijri(event, .every, hijriYear: year)).constraint?.ranges
        }
        #expect(ranges(.ramadan, 1445) == [range((2024, 3, 10, 18), (2024, 4, 10, 4))], "30 days: 11 Mar – 9 Apr")
        #expect(ranges(.ramadan, 1446) == [range((2025, 2, 28, 18), (2025, 3, 30, 4))], "29 days: 1 – 29 Mar; the seed's eve photo at 21:00 counts")
        #expect(ranges(.eidAlFitr, 1445) == [range((2024, 4, 9, 18), (2024, 4, 13, 4))], "1–3 Shawwal = 10–12 Apr")
        #expect(ranges(.eidAlFitr, 1446) == [range((2025, 3, 29, 18), (2025, 4, 2, 4))], "1 Shawwal 1446 = 30 Mar")
        #expect(ranges(.eidAlAdha, 1445) == [range((2024, 6, 15, 18), (2024, 6, 20, 4))], "10–13 Dhu al-Hijjah = 16–19 Jun")
        #expect(ranges(.eidAlAdha, 1446) == [range((2025, 6, 5, 18), (2025, 6, 10, 4))])
        #expect(ranges(.hajj, 1446) == [range((2025, 6, 3, 18), (2025, 6, 10, 4))], "8–13 Dhu al-Hijjah")
        #expect(ranges(.eid, 1445)?.count == 2)
        #expect(try constraint("Eid al-Adha 2025").ranges == ranges(.eidAlAdha, 1446))
        #expect(try constraint("Eid al-Adha 2025").label == "Eid al-Adha 1446 · 6\(thin)9 Jun 2025")

        // Every Eid over the library's years, both Eids of each year.
        let every = try constraint("Eid")
        #expect(every.label == "Every Eid")
        #expect(every.ranges?.count == 12, "2021–2026, two a year")
        #expect(every.contains(wall: SearchFixture.wall(2024, 4, 10, 10), latitude: 24.7), "the seed's Eid 1445 morning")
        #expect(every.contains(wall: SearchFixture.wall(2024, 4, 12, 15), latitude: 25.2), "the Dubai trip's Eid days 2–3")
        #expect(!every.contains(wall: SearchFixture.wall(2024, 4, 14, 10), latitude: 25.2))
    }

    @Test func weekendsAreFridayAndSaturdayAtASaudiHome() throws {
        let saudi = SearchFixture.saudi()
        #expect(saudi.context.weekendDays == [6, 7])
        let weekends = try constraint("weekends")
        #expect(weekends.weekdays == [6, 7] && weekends.ranges == nil)
        #expect(try constraint("last weekend").ranges == [range((2026, 10, 23, 4), (2026, 10, 25, 4))])
        #expect(try constraint("this weekend").isFuture)
        #expect(try constraint("weekdays").weekdays == [1, 2, 3, 4, 5])
        // Friday night past midnight is still Friday's moment day.
        #expect(weekends.contains(wall: SearchFixture.wall(2024, 1, 6, 1, 30), latitude: 25.47), "the desert camp's 01:30 Saturday photos")
        #expect(!weekends.contains(wall: SearchFixture.wall(2024, 1, 4, 20), latitude: 24.7), "a Thursday")
    }

    @Test func yearsAgoAndRelativeDates() throws {
        let threeYears = try constraint("3 years ago")
        #expect(threeYears.ranges == [range((2023, 1, 1, 4), (2024, 1, 1, 4))])
        #expect(threeYears.label == "2023 (3 years ago)")
        #expect(threeYears.tau == 3_153_600, "a year fades over 36.5 days")
        let onThisDay = try constraint("3 years ago today")
        #expect(onThisDay.ranges == [range((2023, 10, 25, 4), (2023, 11, 1, 4))], "±3 days")
        #expect(onThisDay.label == "On this day in 2023")
        #expect(try constraint("on this day").ranges?.count == 5, "every earlier year of the library")
        #expect(try constraint("today").ranges == [range((2026, 10, 28, 4), (2026, 10, 29, 4))])
        #expect(try constraint("yesterday").label == "Yesterday")
        #expect(try constraint("last week").ranges == [range((2026, 10, 19, 4), (2026, 10, 26, 4))], "Monday to Sunday in the UK region")
        #expect(try constraint("this year").ranges == [range((2026, 1, 1, 4), (2026, 10, 29, 4))], "year to date")
        #expect(try constraint("last year").label == "Last year · 2025")
        #expect(try constraint("past 30 days").ranges == [range((2026, 9, 29, 4), (2026, 10, 29, 4))])
        #expect(try constraint("recently").ranges == (try constraint("past 30 days")).ranges)
        #expect(try constraint("2 months ago").label == "August 2026 (2 months ago)")
        #expect(try constraint("last Saturday").ranges == [range((2026, 10, 24, 4), (2026, 10, 25, 4))])
        #expect(try constraint("last Saturday").label == "Last Saturday · Sat, 24 Oct 2026")
        #expect(try constraint("14 June").ranges == [range((2026, 6, 14, 4), (2026, 6, 15, 4))], "the latest 14 June on or before today")
        #expect(try constraint("14 December").ranges == [range((2025, 12, 14, 4), (2025, 12, 15, 4))])
        #expect(try constraint("last June").label == "Last June · Jun 2026")
    }

    @Test func holidays() throws {
        let nye = try constraint("New Year's Eve 2021")
        #expect(nye.ranges == [range((2021, 12, 31, 18), (2022, 1, 1, 4))])
        #expect(nye.label == "New Year’s Eve 2021 · Fri, 31 Dec 2021")
        let party = SearchFixture.wall(2022, 1, 1, 2, 30)
        #expect(try constraint("new year's eve").contains(wall: party, latitude: 51.5), "the London party until 02:30")
        #expect(try constraint("Christmas 2023").ranges == [range((2023, 12, 24, 4), (2023, 12, 27, 4))])
        #expect(try constraint("National Day 2025").ranges == [range((2025, 9, 23, 4), (2025, 9, 24, 4))])
        #expect(try constraint("Founding Day 2026").ranges == [range((2026, 2, 22, 4), (2026, 2, 23, 4))])
        #expect(SearchFixture.sydneyHome().resolve(.holiday(.nationalDay, .every)) == .unsupported("National day of which country?"))
    }

    @Test func seasonsRecurPerPhotoHemisphere() throws {
        let summer = try constraint("summer")
        #expect(summer.ranges == nil)
        #expect(summer.months == MonthRule(north: [6, 7, 8], south: [12, 1, 2]))
        #expect(summer.contains(wall: SearchFixture.wall(2022, 1, 10, 12), latitude: -33.9), "Sydney in January")
        #expect(!summer.contains(wall: SearchFixture.wall(2022, 1, 1, 12), latitude: 51.5), "London in January")
        #expect(summer.contains(wall: SearchFixture.wall(2023, 7, 5, 12), latitude: 37.4), "Greece in July")
        #expect(try constraint("June").months == MonthRule(months: [6]))
        #expect(try constraint("summer 2023").ranges == [range((2023, 6, 1, 4), (2023, 9, 1, 4))])
        #expect(try constraint("winter 2025").ranges == [range((2025, 12, 1, 4), (2026, 3, 1, 4))])
        let upcoming = try constraint("this summer")
        #expect(upcoming.ranges == [range((2027, 6, 1, 4), (2027, 9, 1, 4))] && upcoming.isFuture, "the upcoming one, reported as future")
    }

    @Test func rangesAndCombinations() throws {
        #expect(try constraint("between March and May 2024").ranges == [range((2024, 3, 1, 4), (2024, 6, 1, 4))])
        #expect(try constraint("between March and May 2024").label == "March 2024 – May 2024")
        let since = try constraint("since 2025")
        #expect(since.ranges?.first?.lowerBound == SearchFixture.wall(2025, 1, 1, 4))
        #expect(since.label == "Since 2025")
        #expect(try constraint("before 2022").ranges?.first?.upperBound == SearchFixture.wall(2022, 1, 1, 4))
        let evening = try constraint("Saturday evening in July 2023")
        #expect(evening.weekdays == [7])
        #expect(evening.minuteWindows == [PartOfDay.evening.window])
        #expect(evening.ranges == [range((2023, 7, 1, 4), (2023, 8, 1, 4))])
        #expect(evening.label == "Saturday evening · July 2023")
        #expect(try constraint("Saturday evening").label == "Saturday evening")
        #expect(try constraint("tonight").minuteWindows == [MinuteWindow(start: 17 * 60, end: 4 * 60)])
        #expect(try constraint("June 2023 2024").ranges == [], "contradicting parts match nothing")
        // Separate time slots of one query intersect.
        let both = SearchFixture.saudi().resolve([.weekday(7, .every), .year(2025)]).constraint
        #expect(both?.weekdays == [7] && both?.ranges == [range((2025, 1, 1, 4), (2026, 1, 1, 4))])
    }

    @Test func minuteWindowsWrapPastMidnight() {
        let night = PartOfDay.night.window
        #expect(night.contains(minute: 23 * 60) && night.contains(minute: 60) && !night.contains(minute: 12 * 60))
        #expect(night.distance(minute: 20 * 60 + 30) == 30)
        #expect(PartOfDay.lateNight.window.distance(minute: 23 * 60 + 50) == 10)
        #expect(PartOfDay.evening.window.distance(minute: 17 * 60) == 0)
    }

    @Test func labelsFollowTheRegion() throws {
        let us = TimeResolver(context: TimeContext(now: SearchFixture.now, zone: SearchFixture.riyadh, homeCountry: "SA", locale: SearchFixture.us,
                                                   years: 2021...2026))
        #expect(us.resolve(.hijri(.ramadan, .year(2024), hijriYear: nil)).constraint?.label == "Ramadan 1445 · Mar 11\(thin)Apr 9, 2024")
        #expect(us.resolve(.weekday(7, .last)).constraint?.label == "Last Saturday · Sat, Oct 24, 2026")
        #expect(us.context.firstWeekday == 1, "US weeks start on Sunday")
    }

    // MARK: Sydney home

    @Test func theSameGoldensFromSydney() throws {
        let sydney = SearchFixture.sydneyHome()
        #expect(sydney.context.weekendDays == [1, 7])
        let summer = try constraint("last summer", sydney)
        #expect(summer.ranges == [range((2025, 12, 1, 4), (2026, 3, 1, 4))], "the southern summer that last ended")
        #expect(summer.label == "Last summer · Dec 2025\(thin)Feb 2026")
        #expect(try constraint("last winter", sydney).ranges == [range((2026, 6, 1, 4), (2026, 9, 1, 4))])
        #expect(try constraint("last December", sydney).ranges == [range((2025, 12, 1, 4), (2026, 1, 1, 4))])
        #expect(try constraint("summer 2023", sydney).ranges == [range((2022, 12, 1, 4), (2023, 3, 1, 4))], "the one holding January 2023")
        #expect(try constraint("Ramadan 2024", sydney).ranges == [range((2024, 3, 10, 18), (2024, 4, 10, 4))])
        #expect(try constraint("last Ramadan", sydney).label == "Ramadan 1447 · 18 Feb\(thin)19 Mar 2026")
        #expect(try constraint("Eid al-Adha 2025", sydney).ranges == [range((2025, 6, 5, 18), (2025, 6, 10, 4))])
        #expect(try constraint("weekends", sydney).weekdays == [1, 7])
        #expect(try constraint("last weekend", sydney).ranges == [range((2026, 10, 24, 4), (2026, 10, 26, 4))])
        #expect(try constraint("3 years ago", sydney).ranges == [range((2023, 1, 1, 4), (2024, 1, 1, 4))])
        #expect(try constraint("new year's eve 2021", sydney).ranges == [range((2021, 12, 31, 18), (2022, 1, 1, 4))])
        let recurring = try constraint("summer", sydney)
        #expect(recurring.months?.months(latitude: nil) == [12, 1, 2], "unlocated photos use the home hemisphere")
    }

    /// "Today" is the home zone's: at 12:00 in Riyadh it is already evening in Sydney, and still the same date.
    @Test func todayIsTheHomeZones() {
        let early = Date(timeIntervalSince1970: 1_793_134_800)   // 2026-10-28 00:00 Riyadh = 2026-10-28 08:00 Sydney
        let riyadh = TimeResolver(context: TimeContext(now: early, zone: SearchFixture.riyadh, locale: SearchFixture.uk))
        let sydney = TimeResolver(context: TimeContext(now: early, zone: SearchFixture.sydney, locale: SearchFixture.uk))
        #expect(riyadh.today == LocalTime.day(year: 2026, month: 10, day: 27), "before the 04:00 break it is still yesterday's moment day")
        #expect(sydney.today == LocalTime.day(year: 2026, month: 10, day: 28))
    }
}
