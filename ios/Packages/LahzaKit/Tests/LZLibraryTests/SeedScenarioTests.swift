import Foundation
import LZGeo
import Testing
@testable import LZLibrary

/// The hero seed scenario keeps the promises of spec §8.1: its counts, a unique capture second per
/// item, real weekdays and Umm al-Qura days, the intended borrowing outcomes, home days clear of
/// trips, and the same library on every build.
@Suite struct SeedScenarioTests {
    private let hero = SeedScenario.hero

    // MARK: Counts

    @Test func countsMatchTheTable() {
        let expected: [SeedScenario.Tag: Int] = [
            .home: 135, .nakheel: 85, .otherPitch: 20, .salam: 10, .kingdom: 15, .sufra: 8, .diriyah: 12, .desert: 16, .iftar: 28,
            .eid: 18, .dubai1: 32, .dubai2: 25, .greece: 75, .london: 30, .sydney: 15, .summer2026: 2, .screens: 20, .received: 6,
            .orphans: 5, .undated: 4,
        ]
        for tag in SeedScenario.Tag.allCases {
            #expect(hero.items(tag).count == expected[tag], "\(tag)")
        }
        #expect(hero.items.count == 561)
        #expect(hero.expectedPhotoKitCount == 557)
        #expect(hero.libraryAssets.count == 561)
        #expect(hero.expectedVideoCount == 9)
        #expect(hero.expectedLocatedCount == 520)
        #expect(hero.items(.nakheel).filter(\.isVideo).count == 3)
        #expect(hero.items(.nakheel).filter { !$0.isLocated }.count == 2)
        #expect(hero.items(.greece).filter { !$0.isLocated }.count == 4)
        #expect(hero.items(.dubai1).filter { $0.coordinate.map { $0.distance(to: SeedPlace.salamParkDubai.coordinate) < 500 } ?? false }.count == 8)
        #expect(hero.items(.eid).filter(\.isSelfie).count == 4)
        #expect(hero.items.filter(\.isSelfie).count == 4)
    }

    @Test func numbersAndIdsFollowCaptureOrder() throws {
        #expect(hero.items.map(\.number) == Array(1...561))
        let dated = hero.items.compactMap(\.utc)
        #expect(dated.count == 557)
        #expect(dated == dated.sorted())
        #expect(hero.items.suffix(4).allSatisfy { $0.media == .undated })
        let item = try #require(hero.item(id: "seed/0142"))
        #expect(item.number == 142)
        #expect(item.fileName.hasPrefix("seed-0142."))
        #expect(hero.item(id: "seed/0000") == nil)
        #expect(hero.item(id: "seed/0562") == nil)
        #expect(hero.item(id: "ABC/L0/001") == nil)
        let utc = try #require(item.utc)
        #expect(hero.item(matchingUTC: utc)?.id == item.id)
        #expect(hero.item(matchingUTC: utc + 1)?.id == item.id)
        #expect(hero.item(matchingUTC: utc - 1)?.id == item.id)
        #expect(hero.item(matchingUTC: utc + 1, tolerance: 0) == nil)
    }

    @Test func theScenarioIsDeterministic() {
        let again = SeedScenario(.hero)
        #expect(again.items == hero.items)
        #expect(again.trips == hero.trips)
        // Pinned, so a change of jitter, order or zone data shows up here first.
        let first = hero.items[0]
        #expect(first.tag == .london)
        #expect(first.localDateTime == "2021-12-30T14:00:00")
        #expect(first.utc == 1_640_872_800)
        let last = hero.items[556]
        #expect(last.tag == .home)
        #expect(last.localDateTime == "2026-10-14T21:50:00")
    }

    // MARK: Invariants

    @Test func everyItemHasItsOwnCaptureSecond() {
        let seconds = hero.items.compactMap(\.utc).sorted()
        #expect(Set(seconds).count == seconds.count)
        // At least 2 s apart, so mapping PhotoKit back by UTC ±1 s is unambiguous.
        #expect(zip(seconds, seconds.dropFirst()).allSatisfy { $1 - $0 >= 2 })
    }

    @Test func statedWeekdaysAreReal() {
        let stated = hero.items.filter { $0.weekday != nil }
        #expect(stated.count > 300)
        for item in stated {
            #expect(item.civilDay.map(LocalTime.weekday(day:)) == item.weekday, "\(item.id) \(item.tag) \(item.localDateTime)")
        }
        // Every park, pitch and received item is on a Saturday.
        for tag: SeedScenario.Tag in [.nakheel, .otherPitch, .salam, .received] {
            #expect(hero.items(tag).allSatisfy { $0.civilDay.map(LocalTime.weekday(day:)) == 7 }, "\(tag)")
        }
    }

    @Test func ramadanAndEidDaysComeFromUmmAlQura() throws {
        var hijri = Calendar(identifier: .islamicUmmAlQura)
        hijri.timeZone = try #require(TimeZone(identifier: "Asia/Riyadh"))
        func hijriDate(_ item: SeedItem) throws -> (year: Int, month: Int, day: Int) {
            let parts = hijri.dateComponents([.year, .month, .day], from: try #require(item.date))
            return (parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let iftars = hero.items(.iftar)
        var sessions = Set<String>()
        for item in iftars where item.localDateTime.hasSuffix("T21:00:00") == false {
            let date = try hijriDate(item)
            #expect(date.month == 9 && [5, 15, 25].contains(date.day) && (1445...1447).contains(date.year), "\(item.localDateTime)")
            sessions.insert("\(date.year)-\(date.day)")
        }
        #expect(sessions.count == 9)
        let eve = try #require(iftars.first { $0.localDateTime.hasSuffix("T21:00:00") })
        #expect(eve.localDateTime == "2025-02-28T21:00:00")
        #expect(try hijriDate(eve).month == 8, "the eve is the last day of Sha'ban")
        let eidDays = Set(hero.items(.eid).map { String($0.localDateTime.prefix(10)) })
        #expect(eidDays == ["2024-04-10", "2025-03-30"])
        for item in hero.items(.eid) {
            let date = try hijriDate(item)
            #expect(date.month == 10 && date.day == 1)
        }
        // The spec's Ramadan starts, as this Mac's calendar gives them.
        let firstIftar1445 = try #require(iftars.first)
        #expect(firstIftar1445.localDateTime.hasPrefix("2024-03-15"))
    }

    @Test func intendedBorrowingHolds() throws {
        let located = hero.items.filter(\.isLocated).compactMap { item in item.utc.map { (utc: $0, day: item.momentDay) } }
        for item in hero.items where item.borrowing != .none {
            let utc = try #require(item.utc)
            #expect(!item.isLocated)
            let gaps = located.map { abs($0.utc - utc) }
            let nearest = try #require(gaps.min())
            switch item.borrowing {
            case .moment:
                let sameDay = located.filter { $0.day == item.momentDay }.map { abs($0.utc - utc) }
                #expect((sameDay.min() ?? .max) <= 10 * 60, "\(item.id)")
            case .beyondMoment:
                #expect(nearest > 2 * 3600, "\(item.id)")
            case .sameDay:
                let sameDay = located.filter { $0.day == item.momentDay }
                #expect(!sameDay.isEmpty, "\(item.id) has located items that day")
                #expect(sameDay.allSatisfy { utc - $0.utc > 90 * 60 }, "\(item.id)")
            case .noZone:
                #expect(nearest >= 12 * 3600, "\(item.id)")
            case .none:
                break
            }
        }
        #expect(hero.items.filter { $0.borrowing == .moment }.count == 2)
        #expect(hero.items.filter { $0.borrowing == .beyondMoment }.count == 4)
        #expect(hero.items.filter { $0.borrowing == .sameDay }.count == 6)
        #expect(hero.items.filter { $0.borrowing == .noZone }.count == 5)
    }

    @Test func homeDaysStayClearOfTrips() throws {
        for item in hero.items(.home) {
            let day = try #require(item.momentDay)
            #expect(!hero.trips.contains { $0.contains(day: day, margin: 1) }, "\(item.localDateTime)")
        }
        let homes = hero.items(.home)
        #expect(homes.first?.localDateTime == "2022-01-06T20:30:00")
        #expect(homes.allSatisfy { $0.coordinate.map { $0.distance(to: SeedPlace.home.coordinate) <= 25.5 } ?? false })
    }

    @Test func tripsHoldTheirItems() throws {
        #expect(hero.trips.map(\.name) == ["London", "Sydney", "Greece", "Saudi Arabia", "Dubai", "Dubai"])
        let tags: [SeedScenario.Tag] = [.london, .sydney, .greece, .desert, .dubai1, .dubai2]
        for (trip, tag) in zip(hero.trips, tags) {
            let days = Set(hero.items(tag).compactMap(\.momentDay))
            #expect(days.allSatisfy { trip.contains(day: $0) }, "\(tag)")
            #expect(days.contains(trip.firstDay) && days.contains(trip.lastDay), "\(tag) spans its trip")
        }
        // Nothing else happens during a trip.
        let others = hero.items.filter { !tags.contains($0.tag) && $0.utc != nil }
        for item in others {
            let day = try #require(item.momentDay)
            #expect(!hero.trips.contains { $0.contains(day: day) }, "\(item.id) \(item.tag)")
        }
    }

    @Test func timesAndPlacesMatchTheSpec() throws {
        let party = hero.items(.london).filter { $0.coordinate.map { $0.distance(to: SeedPlace.towerBridge.coordinate) < 500 } ?? false }
            .map(\.localDateTime).filter { $0 >= "2021-12-31T21" && $0 <= "2022-01-01T03" }
        #expect(party.first == "2021-12-31T22:00:00")
        #expect(party.last == "2022-01-01T02:30:00")
        #expect(party.count == 15)
        // Past midnight still belongs to the evening's day.
        let night = try #require(hero.items(.london).first { $0.localDateTime == "2022-01-01T02:30:00" })
        #expect(night.momentDay == LocalTime.day(year: 2021, month: 12, day: 31))
        let oia = hero.items(.greece).filter { $0.title == "Oia" && !$0.isVideo }.map(\.localDateTime)
        #expect(oia.first == "2023-07-07T20:00:00" && oia.last == "2023-07-07T20:45:00")
        let fira = try #require(hero.items(.greece).first { $0.title == "Fira" })
        #expect(fira.localDateTime == "2023-07-08T01:30:00")
        #expect(fira.offsetSeconds == 3 * 3600)
        #expect(fira.momentDay == LocalTime.day(year: 2023, month: 7, day: 7))
        #expect(hero.items(.sydney).allSatisfy { $0.offsetSeconds == 11 * 3600 })
        #expect(hero.items(.london).allSatisfy { $0.offsetSeconds == 0 })
        #expect(hero.items(.desert).filter { $0.localDateTime.contains("T01:3") }.count == 3)
        let sufraToKingdom = SeedPlace.sufraGrill.coordinate.distance(to: SeedPlace.kingdomCentre.coordinate)
        #expect(abs(sufraToKingdom - 651) < 5)
        let parkToHome = SeedPlace.alNakheelPark.coordinate.distance(to: SeedPlace.home.coordinate)
        #expect(abs(parkToHome - 1_650) < 50)
        #expect(hero.items(.nakheel).allSatisfy { $0.coordinate.map { $0.distance(to: SeedPlace.alNakheelPark.coordinate) <= 120.5 } ?? true })
        let received = hero.items(.received).map { String($0.localDateTime.prefix(10)) }
        #expect(received == ["2025-02-08", "2025-06-14", "2025-10-04", "2026-04-18", "2026-06-20", "2026-07-11"])
        #expect(hero.items(.received).allSatisfy { $0.localDateTime.hasSuffix("T23:40:00") })
        #expect(hero.items(.summer2026).map(\.localDateTime) == ["2026-07-30T21:00:00", "2026-08-14T21:00:00"])
    }

    // MARK: Fake reader facts

    @Test func assetsCarryTheIntendedFacts() throws {
        for item in hero.items {
            let facts = item.asset.facts
            #expect(facts.kind == (item.isVideo ? .video : .photo))
            #expect(facts.creationDate == item.date)
            #expect(facts.coordinate == item.coordinate)
            #expect(facts.pixelWidth == item.pixelWidth && facts.pixelHeight == item.pixelHeight)
            switch item.media {
            case .received:
                #expect(AssetClassifier.isLikelyReceived(facts), "\(item.id)")
            case .screenshot:
                #expect(AssetClassifier.isScreenCapture(facts) && facts.format == .png)
            case .photo, .dateOnly, .undated:
                #expect(AssetClassifier.isCameraPhoto(facts), "\(item.id)")
            case .video:
                #expect(facts.duration == 3)
            }
        }
        #expect(hero.libraryAssets.filter(\.isSelfie).count == 4)
        // Camera photos avoid the messaging sizes, so only the received ones match the shape rule.
        #expect(hero.libraryAssets.filter { AssetClassifier.matchesReceivedShape($0.facts) }.count == 6)
    }

    @Test func artworkDrawsEveryKind() throws {
        for media in SeedItem.Media.allCases {
            let item = try #require(hero.items.first { $0.media == media })
            let image = try #require(SeedArtwork.image(for: item, width: item.pixelWidth / 8, height: item.pixelHeight / 8))
            #expect(image.width == item.pixelWidth / 8 && image.height == item.pixelHeight / 8)
        }
        let item = try #require(hero.items(.nakheel).first)
        #expect(SeedArtwork.dateLine(item) == "Sat 2 Mar 2024 · 17:00")
    }
}
