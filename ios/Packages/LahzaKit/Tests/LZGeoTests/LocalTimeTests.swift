import Foundation
import Testing
@testable import LZGeo

/// Local wall time, the 04:00 moment day and the moment rule, with per-photo zones.
@Suite struct LocalTimeTests {
    // MARK: LocalTime

    @Test func theDayBreaksAt0400Local() {
        let riyadh = zone("Asia/Riyadh")
        // Riyadh is UTC+3: 00:59Z is 03:59 there and 01:00Z is 04:00.
        #expect(day(utc("2023-10-05T00:59:59Z"), riyadh) == LocalTime.day(year: 2023, month: 10, day: 4))
        #expect(day(utc("2023-10-05T01:00:00Z"), riyadh) == LocalTime.day(year: 2023, month: 10, day: 5))
        #expect(LocalTime.minuteOfDay(wallSeconds: LocalTime.wallSeconds(utc("2023-10-05T18:30:00Z"), in: riyadh)) == 21 * 60 + 30)
    }

    @Test func theBreakStaysAt0400OnAthensDaylightSavingDays() {
        let athens = zone("Europe/Athens")
        // 29 March 2026: clocks jump from 03:00 EET to 04:00 EEST at 01:00Z, so 02:59:59 is followed by 04:00.
        #expect(day(utc("2026-03-29T00:59:59Z"), athens) == LocalTime.day(year: 2026, month: 3, day: 28))
        #expect(day(utc("2026-03-29T01:00:00Z"), athens) == LocalTime.day(year: 2026, month: 3, day: 29))
        // 25 October 2026: clocks fall back from 04:00 EEST to 03:00 EET at 01:00Z, so 03:00–04:00 happens twice
        // and the 24th's moment day runs 25 hours, to 04:00 EET (02:00Z).
        #expect(day(utc("2026-10-25T00:30:00Z"), athens) == LocalTime.day(year: 2026, month: 10, day: 24))
        #expect(day(utc("2026-10-25T01:30:00Z"), athens) == LocalTime.day(year: 2026, month: 10, day: 24))
        #expect(day(utc("2026-10-25T01:59:59Z"), athens) == LocalTime.day(year: 2026, month: 10, day: 24))
        #expect(day(utc("2026-10-25T02:00:00Z"), athens) == LocalTime.day(year: 2026, month: 10, day: 25))
    }

    @Test func sydneyInSummerIsUTCPlus11() {
        let sydney = zone("Australia/Sydney")
        #expect(LocalTime.wallSeconds(utc("2022-01-08T17:00:00Z"), in: sydney) - Int64(utc("2022-01-08T17:00:00Z").timeIntervalSince1970) == 11 * 3600)
        #expect(day(utc("2022-01-08T16:59:59Z"), sydney) == LocalTime.day(year: 2022, month: 1, day: 8))
        #expect(day(utc("2022-01-08T17:00:00Z"), sydney) == LocalTime.day(year: 2022, month: 1, day: 9))
    }

    @Test func daysBefore1970RoundDown() {
        #expect(LocalTime.day(year: 1970, month: 1, day: 1) == 0)
        #expect(LocalTime.day(year: 1969, month: 12, day: 31) == -1)
        #expect(LocalTime.civil(day: -1) == (year: 1969, month: 12, day: 31))
        #expect(LocalTime.momentDay(wallSeconds: 0) == -1)           // 00:00 on 1 Jan 1970 belongs to 31 Dec 1969
        #expect(LocalTime.momentDay(wallSeconds: 14_399) == -1)
        #expect(LocalTime.momentDay(wallSeconds: 14_400) == 0)
        #expect(LocalTime.momentDay(wallSeconds: -86_400 * 365) == LocalTime.day(year: 1968, month: 12, day: 31))
        #expect(LocalTime.minuteOfDay(wallSeconds: -60) == 1_439)
        #expect(LocalTime.wallSeconds(Date(timeIntervalSince1970: -0.5), in: zone("UTC")) == -1)
    }

    @Test func civilDatesRoundTripOver400Years() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone("UTC")
        let first = LocalTime.day(year: 1826, month: 1, day: 1), last = LocalTime.day(year: 2226, month: 12, day: 31)
        var previous = LocalTime.civil(day: first - 1)
        for day in first...last {
            let date = LocalTime.civil(day: day)
            #expect(LocalTime.day(year: date.year, month: date.month, day: date.day) == day)
            let next = date.day == 1 ? (date.month == 1 ? previous.year + 1 == date.year : previous.month + 1 == date.month)
                : (previous.year, previous.month, previous.day + 1) == (date.year, date.month, date.day)
            #expect(next, "\(date) after \(previous)")
            previous = date
            if day % 97 == 0 {
                let reference = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(day) * 86_400))
                #expect(reference.year == date.year && reference.month == date.month && reference.day == date.day)
            }
        }
    }

    @Test func weekdaysStartOnSunday() {
        #expect(LocalTime.weekday(day: 0) == 5)                                                 // Thu 1 Jan 1970
        #expect(LocalTime.weekday(day: LocalTime.day(year: 2026, month: 10, day: 28)) == 4)     // Wednesday
        #expect(LocalTime.weekday(day: LocalTime.day(year: 2024, month: 1, day: 6)) == 7)       // Saturday
        #expect(LocalTime.weekday(day: LocalTime.day(year: 1969, month: 12, day: 28)) == 1)     // Sunday
    }

    @Test(arguments: [(46.7, "Etc/GMT-3", 3), (0.0, "Etc/GMT", 0), (-40.0, "Etc/GMT+3", -3), (180.0, "Etc/GMT-12", 12), (-180.0, "Etc/GMT+12", -12)])
    func fixedOffsetZonesInvertTheirSign(_ longitude: Double, _ identifier: String, _ hours: Int) throws {
        #expect(LocalTime.etcZoneIdentifier(longitude: longitude) == identifier)
        let zone = try #require(TimeZone(identifier: identifier))
        #expect(zone.secondsFromGMT() == hours * 3600)
    }

    // MARK: MomentSegmenter

    @Test func theCensusCasesSplitOnGapsJumpsAndTheDayBreak() {
        let home = Coordinate(latitude: 24.7136, longitude: 46.6753)
        let north = Coordinate(latitude: home.latitude + 0.0108, longitude: home.longitude)     // 1.2 km from home
        let nearby = Coordinate(latitude: north.latitude + 0.0045, longitude: north.longitude)  // 0.5 km from north
        let items = [
            item("2023-10-05T10:00:00Z", at: home), item("2023-10-05T10:30:00Z", at: home),
            item("2023-10-05T11:59:00Z"),                                     // 89 min: same moment
            item("2023-10-05T13:31:00Z", at: home),                           // 92 min: gap
            item("2023-10-05T13:40:00Z", at: north),                          // 1.2 km: jump
            item("2023-10-05T13:50:00Z"),                                     // no GPS: never splits
            item("2023-10-05T14:00:00Z", at: nearby),                         // 0.5 km: same moment
            item("2023-10-06T03:00:00Z"), item("2023-10-06T03:50:00Z"),       // a gap, then 50 min
            item("2023-10-06T04:10:00Z"),                                     // 20 min, but past 04:00: day break
            item("2023-10-07T23:30:00Z"), item("2023-10-08T00:30:00Z"),       // midnight doesn't split
        ]
        let boundaries = MomentSegmenter.boundaries(items)
        #expect(boundaries.map(\.index) == [3, 4, 7, 9, 10])
        #expect(boundaries.map(\.reason) == [.gap, .jump, .gap, .dayBreak, .gap])
    }

    @Test func ninetyMinutesExactlyStaysTogether() {
        let items = [item("2023-10-05T10:00:00Z"), item("2023-10-05T11:30:00Z"), item("2023-10-05T13:00:01Z")]
        #expect(MomentSegmenter.boundaries(items).map(\.index) == [2])
        #expect(MomentSegmenter.boundaries(items).map(\.reason) == [.gap])
    }

    @Test func aJumpIsMeasuredFromTheMomentsLastLocatedItem() {
        let start = Coordinate(latitude: 24.70, longitude: 46.70)
        func north(_ metres: Double) -> Coordinate {
            Coordinate(latitude: start.latitude + metres / 6_371_000 * 180 / .pi, longitude: start.longitude)
        }
        // 999 m steps add up to 2 km without a split; a 1,001 m step splits.
        let walk = [item("2023-10-05T10:00:00Z", at: start), item("2023-10-05T10:10:00Z", at: north(999)),
                    item("2023-10-05T10:20:00Z", at: north(1_998)), item("2023-10-05T10:30:00Z", at: north(2_999))]
        #expect(MomentSegmenter.boundaries(walk).map(\.index) == [3])
        // An item without GPS doesn't move the reference point.
        let blind = [item("2023-10-05T10:00:00Z", at: start), item("2023-10-05T10:10:00Z"), item("2023-10-05T10:20:00Z", at: north(1_200))]
        #expect(MomentSegmenter.boundaries(blind).map(\.reason) == [.jump])
        // After a split the new moment has no reference until its first located item.
        let reset = [item("2023-10-05T10:00:00Z", at: start), item("2023-10-05T12:00:00Z"), item("2023-10-05T12:10:00Z", at: north(5_000))]
        #expect(MomentSegmenter.boundaries(reset).map(\.reason) == [.gap])
    }

    @Test func eachItemBreaksItsDayInItsOwnZone() {
        let london = zone("Europe/London"), athens = zone("Europe/Athens")
        // A New Year's Eve party in London: 22:00 to 02:30 is one moment on 31 December.
        let party = stride(from: 0, through: 270, by: 30).map { minutes in
            item(utc("2021-12-31T22:00:00Z").addingTimeInterval(Double(minutes) * 60), zone: london)
        }
        #expect(MomentSegmenter.boundaries(party).isEmpty)
        #expect(party.last?.day == LocalTime.day(year: 2021, month: 12, day: 31))
        // 03:30 in Athens (01:30Z) then 02:10 in London 40 minutes later: both before their own 04:00, so one moment…
        let flight = [item(utc("2026-01-10T01:30:00Z"), zone: athens), item(utc("2026-01-10T02:10:00Z"), zone: london)]
        #expect(MomentSegmenter.boundaries(flight).isEmpty)
        // …while the second photo taken in Athens (04:10 there) starts a new day.
        let stayed = [item(utc("2026-01-10T01:30:00Z"), zone: athens), item(utc("2026-01-10T02:10:00Z"), zone: athens)]
        #expect(MomentSegmenter.boundaries(stayed).map(\.reason) == [.dayBreak])
    }

    @Test func emptyAndSingleInputsHaveNoBoundaries() {
        #expect(MomentSegmenter.boundaries([]).isEmpty)
        #expect(MomentSegmenter.boundaries([item("2023-10-05T10:00:00Z")]).isEmpty)
    }

    // MARK: Helpers

    private func zone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? .gmt
    }

    private func utc(_ iso: String) -> Date {
        (try? Date(iso, strategy: .iso8601)) ?? .distantPast
    }

    private func day(_ date: Date, _ zone: TimeZone) -> Int32 {
        LocalTime.momentDay(wallSeconds: LocalTime.wallSeconds(date, in: zone))
    }

    private func item(_ iso: String, at place: Coordinate? = nil) -> MomentSegmenter.Item {
        item(utc(iso), zone: zone("UTC"), at: place)
    }

    private func item(_ date: Date, zone: TimeZone, at place: Coordinate? = nil) -> MomentSegmenter.Item {
        MomentSegmenter.Item(utc: Int64(date.timeIntervalSince1970), day: day(date, zone), coordinate: place)
    }
}
