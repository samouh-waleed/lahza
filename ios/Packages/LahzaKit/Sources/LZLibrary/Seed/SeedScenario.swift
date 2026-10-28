#if DEBUG
import Foundation
import LZGeo

/// A deterministic synthetic photo library (DEBUG builds only), the one source for `lz-seed` (files
/// imported into the Simulator's Photos), ``FakeLibraryReader`` (kit tests, app tests, DEBUG
/// launches), ``SeedMaps`` and the search goldens.
///
/// `hero` (spec §8.1): 557 photos and videos for PhotoKit across Riyadh, Dubai, Greece, London and
/// Sydney from Dec 2021 to Oct 2026, with Ramadan and Eid dates from the Umm al-Qura calendar, plus
/// 4 undated photos only the fake reader holds. Its invariants (unique capture seconds, weekdays,
/// Hijri days, the intended borrowing, home days clear of trips) are enforced by `LZLibraryTests`.
public struct SeedScenario: Sendable {
    public enum Name: String, Sendable, Hashable, CaseIterable {
        case hero
    }

    /// The groups the hero table lists.
    public enum Tag: String, Sendable, Hashable, Codable, CaseIterable {
        case home, nakheel, otherPitch, salam, kingdom, sufra, diriyah, desert, iftar, eid, dubai1, dubai2, greece, london,
             sydney, summer2026, screens, received, orphans, undated
    }

    /// A trip the index should find: local days, first and last inclusive.
    public struct Trip: Sendable, Hashable {
        public var name: String
        /// ISO 3166 alpha-2.
        public var countryCode: String
        public var firstDay: Int32
        public var lastDay: Int32

        init(_ name: String, _ countryCode: String, from first: (Int, Int, Int), to last: (Int, Int, Int)) {
            self.name = name
            self.countryCode = countryCode
            firstDay = LocalTime.day(year: first.0, month: first.1, day: first.2)
            lastDay = LocalTime.day(year: last.0, month: last.1, day: last.2)
        }

        public func contains(day: Int32, margin: Int32 = 0) -> Bool {
            (firstDay - margin...lastDay + margin).contains(day)
        }
    }

    public let name: Name
    /// Every item, PhotoKit's in capture order, then the undated ones.
    public let items: [SeedItem]
    /// The trips the index should find, oldest first.
    public let trips: [Trip]
    /// Where home is (a home base in every year).
    public let home: SeedPlace

    private let byUTC: [Int64: Int]

    /// The hero scenario, built once.
    public static let hero = SeedScenario(.hero)

    /// The scenario called `name` (built once).
    public static func named(_ name: Name) -> SeedScenario {
        switch name {
        case .hero: hero
        }
    }

    /// The Simulator's own sample photos, which sit next to the seed in its library.
    public static let builtInSampleCount = 6
    /// The GPS accuracy written into every located item (EXIF HPositioningError), in metres.
    public static let horizontalAccuracy: Double = 5
    /// The added date the fake reader gives undated items.
    public static let undatedAddedDate = Date(timeIntervalSince1970: 1_790_758_800)  // 2026-09-30 09:00 UTC

    public init(_ name: Name) {
        self.name = name
        var builder = HeroBuilder()
        builder.build()
        let dated = builder.drafts.compactMap { draft in draft.utc.map { (utc: $0, draft: draft) } }.sorted { $0.utc < $1.utc }.map(\.draft)
        let undated = builder.drafts.filter { $0.utc == nil }
        items = (dated + undated).enumerated().map { index, draft in
            var item = draft
            item.number = index + 1
            return item
        }
        trips = HeroBuilder.trips
        home = .home
        byUTC = Dictionary(items.enumerated().compactMap { index, item in item.utc.map { ($0, index) } }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Expectations

    /// What goes through PhotoKit (557).
    public var photoKitItems: [SeedItem] { items.filter(\.isInPhotoKit) }
    /// What the fake reader serves (561).
    public var libraryAssets: [LibraryAsset] { items.map(\.asset) }
    public var expectedPhotoKitCount: Int { photoKitItems.count }
    /// PhotoKit items with a position (photos and videos).
    public var expectedLocatedCount: Int { photoKitItems.filter(\.isLocated).count }
    public var expectedVideoCount: Int { items.filter(\.isVideo).count }

    public func items(_ tag: Tag) -> [SeedItem] { items.filter { $0.tag == tag } }

    public func item(id: String) -> SeedItem? {
        guard id.hasPrefix("seed/"), let number = Int(id.dropFirst(5)), items.indices.contains(number - 1) else { return nil }
        return items[number - 1]
    }

    /// The dated item captured within `tolerance` seconds of `utc` (how PhotoKit assets map back:
    /// capture seconds are at least 2 s apart, so ±1 s is unambiguous).
    public func item(matchingUTC utc: Int64, tolerance: Int64 = 1) -> SeedItem? {
        for delta in 0...max(0, tolerance) {
            if let index = byUTC[utc - delta] ?? byUTC[utc + delta] { return items[index] }
        }
        return nil
    }
}

// MARK: Hero

/// Builds the hero table of spec §8.1. Every position is jittered by a seeded generator, so the
/// library is the same on every run and machine.
private struct HeroBuilder {
    var drafts: [SeedItem] = []
    private var random = SeededGenerator(seed: 0x5EED_4E50)

    static let trips = [
        SeedScenario.Trip("London", "GB", from: (2021, 12, 30), to: (2022, 1, 3)),
        SeedScenario.Trip("Sydney", "AU", from: (2022, 1, 8), to: (2022, 1, 12)),
        SeedScenario.Trip("Greece", "GR", from: (2023, 7, 2), to: (2023, 7, 8)),
        SeedScenario.Trip("Saudi Arabia", "SA", from: (2024, 1, 5), to: (2024, 1, 6)),
        SeedScenario.Trip("Dubai", "AE", from: (2024, 4, 11), to: (2024, 4, 14)),
        SeedScenario.Trip("Dubai", "AE", from: (2024, 12, 19), to: (2024, 12, 21)),
    ]

    /// Al-Nakheel Park sessions (Saturdays).
    static let nakheelDays = [(2024, 3, 2), (2024, 5, 4), (2024, 11, 16), (2025, 2, 8), (2025, 6, 14), (2025, 10, 4),
                              (2026, 4, 18), (2026, 6, 20), (2026, 7, 11), (2026, 8, 22)]

    mutating func build() {
        home()
        nakheel()
        riyadhOutings()
        desert()
        ramadanAndEid()
        dubai()
        greece()
        london()
        sydney()
        withoutGPS()
    }

    // MARK: Riyadh

    /// 135 evenings at home, every 13 days from Thu 6 Jan 2022; a date within a day of a trip moves
    /// to the second day after it.
    mutating func home() {
        let first = LocalTime.day(year: 2022, month: 1, day: 6)
        for index in 0..<135 {
            var day = first + Int32(13 * index)
            if let trip = Self.trips.first(where: { $0.contains(day: day, margin: 1) }) { day = trip.lastDay + 2 }
            let (year, month, date) = LocalTime.civil(day: day)
            add(.home, .photo, at: .home, jitter: 25, utc: utc(year, month, date, 20, 30 + 20 * (index % 5), place: .home))
        }
        // Two summer evening videos at home.
        add(.summer2026, .video, at: .home, jitter: 25, utc: utc(2026, 7, 30, 21, 0, place: .home), weekday: 5)
        add(.summer2026, .video, at: .home, jitter: 25, utc: utc(2026, 8, 14, 21, 0, place: .home), weekday: 6)
    }

    /// Ten Saturday sessions at Al-Nakheel Park, 17:00–18:40: 8 photos each, a video on three of them,
    /// and on two a photo without GPS 5 minutes after a located one.
    mutating func nakheel() {
        let videoDays = [(2025, 6, 14), (2026, 4, 18), (2026, 7, 11)]
        let unlocatedDays = [(2024, 11, 16), (2025, 10, 4)]
        let place = SeedPlace.alNakheelPark
        for day in Self.nakheelDays {
            let times = session(day, from: (17, 0), to: (18, 40), count: 8, place: place)
            for time in times { add(.nakheel, .photo, at: place, jitter: 120, utc: time, weekday: 7) }
            if videoDays.contains(where: { $0 == day }) {
                add(.nakheel, .video, at: place, jitter: 120, utc: times[2] + 7 * 60, weekday: 7)
            }
            if unlocatedDays.contains(where: { $0 == day }) {
                add(.nakheel, .photo, at: place, jitter: 0, utc: times[3] + 5 * 60, located: false, borrowing: .moment, weekday: 7)
            }
        }
    }

    /// The other Riyadh outings: a second pitch, Salam Park, Kingdom Centre, Sufra Grill and At-Turaif.
    mutating func riyadhOutings() {
        for day in [(2025, 1, 18), (2026, 1, 24)] {
            for time in session(day, from: (17, 0), to: (18, 30), count: 10, place: .otherPitch) {
                add(.otherPitch, .photo, at: .otherPitch, jitter: 120, utc: time, weekday: 7)
            }
        }
        for time in session((2025, 4, 26), from: (17, 0), to: (18, 0), count: 10, place: .salamPark) {
            add(.salam, .photo, at: .salamPark, jitter: 120, utc: time, weekday: 7)
        }
        for time in session((2025, 1, 16), from: (21, 0), to: (23, 30), count: 15, place: .kingdomCentre) {
            add(.kingdom, .photo, at: .kingdomCentre, jitter: 40, utc: time, weekday: 5)
        }
        for time in session((2025, 11, 13), from: (20, 30), to: (21, 15), count: 8, place: .sufraGrill) {
            add(.sufra, .photo, at: .sufraGrill, jitter: 15, utc: time, weekday: 5)
        }
        for time in session((2024, 12, 27), from: (16, 0), to: (18, 0), count: 12, place: .atTuraif) {
            add(.diriyah, .photo, at: .atTuraif, jitter: 100, utc: time, weekday: 6)
        }
    }

    /// A night at a desert camp: Fri 5 Jan 2024 from 15:00, 3 photos at 01:30 Sat, until 11:00 Sat.
    mutating func desert() {
        let place = SeedPlace.desertCamp
        for time in session((2024, 1, 5), from: (15, 0), to: (19, 0), count: 7, place: place) {
            add(.desert, .photo, at: place, jitter: 80, utc: time, weekday: 6)
        }
        for second in [0, 40, 80] {
            add(.desert, .photo, at: place, jitter: 80, utc: utc(2024, 1, 6, 1, 30, place: place) + Int64(second), weekday: 7)
        }
        for time in session((2024, 1, 6), from: (8, 0), to: (11, 0), count: 6, place: place) {
            add(.desert, .photo, at: place, jitter: 80, utc: time, weekday: 7)
        }
    }

    /// Iftars on Ramadan days 5, 15 and 25 of 1445–1447 and the eve of Ramadan 1446; Eid al-Fitr 1445
    /// (with 4 selfies) and 1446. Hijri days come from the Umm al-Qura calendar.
    mutating func ramadanAndEid() {
        let place = SeedPlace.familyHouse
        for year in 1445...1447 {
            for ramadanDay in [5, 15, 25] {
                let day = Self.gregorian(hijriYear: year, month: 9, day: ramadanDay)
                for time in session(day, from: (18, 10), to: (18, 40), count: 3, place: place) {
                    add(.iftar, .photo, at: place, jitter: 20, utc: time)
                }
            }
        }
        let eve = Self.gregorian(hijriYear: 1446, month: 9, day: 1, offsetDays: -1)
        add(.iftar, .photo, at: place, jitter: 20, utc: utc(eve.0, eve.1, eve.2, 21, 0, place: place), weekday: 6)

        let eid1445 = session(Self.gregorian(hijriYear: 1445, month: 10, day: 1), from: (10, 0), to: (11, 0), count: 10, place: place)
        for (index, time) in eid1445.enumerated() {
            add(.eid, .photo, at: place, jitter: 20, utc: time, selfie: (3...6).contains(index), weekday: 4)
        }
        for time in session(Self.gregorian(hijriYear: 1446, month: 10, day: 1), from: (10, 0), to: (10, 35), count: 8, place: place) {
            add(.eid, .photo, at: place, jitter: 20, utc: time, weekday: 1)
        }
    }

    // MARK: Trips

    /// Dubai in April 2024 (over Eid al-Fitr days 2–3) and in December 2024.
    mutating func dubai() {
        let burj = session((2024, 4, 11), from: (19, 0), to: (20, 0), count: 7, place: .burjKhalifa)
        for time in burj { add(.dubai1, .photo, at: .burjKhalifa, jitter: 60, utc: time, weekday: 5) }
        add(.dubai1, .video, at: .burjKhalifa, jitter: 60, utc: burj[2] + 300, weekday: 5)
        for time in session((2024, 4, 12), from: (13, 0), to: (14, 0), count: 7, place: .dubaiMall) {
            add(.dubai1, .photo, at: .dubaiMall, jitter: 80, utc: time, weekday: 6)
        }
        let beach = session((2024, 4, 13), from: (10, 0), to: (11, 10), count: 8, place: .jbrBeach)
        for time in beach { add(.dubai1, .photo, at: .jbrBeach, jitter: 150, utc: time, weekday: 7) }
        add(.dubai1, .video, at: .jbrBeach, jitter: 150, utc: beach[3] + 300, weekday: 7)
        for time in session((2024, 4, 14), from: (9, 0), to: (10, 0), count: 8, place: .salamParkDubai) {
            add(.dubai1, .photo, at: .salamParkDubai, jitter: 120, utc: time, weekday: 1)
        }

        for time in session((2024, 12, 19), from: (19, 0), to: (20, 10), count: 8, place: .dubaiMarina) {
            add(.dubai2, .photo, at: .dubaiMarina, jitter: 150, utc: time, weekday: 5)
        }
        let jbr = session((2024, 12, 20), from: (11, 0), to: (12, 10), count: 8, place: .jbrBeach)
        for time in jbr { add(.dubai2, .photo, at: .jbrBeach, jitter: 150, utc: time, weekday: 6) }
        add(.dubai2, .video, at: .jbrBeach, jitter: 150, utc: jbr[3] + 300, weekday: 6)
        for time in session((2024, 12, 21), from: (10, 0), to: (11, 10), count: 8, place: .dubaiMarina) {
            add(.dubai2, .photo, at: .dubaiMarina, jitter: 150, utc: time, weekday: 7)
        }
    }

    /// Greece, Sun 2 – Sat 8 Jul 2023: Athens, Mykonos, then Santorini (Oia at sunset, Fira past
    /// midnight and the next morning), plus 4 photos without GPS far from any located one.
    mutating func greece() {
        for (offset, place) in [SeedPlace.acropolis, .acropolis, .acropolis, .mykonos, .mykonos].enumerated() {
            for time in session((2023, 7, 2 + offset), from: (10, 0), to: (12, 15), count: 10, place: place) {
                add(.greece, .photo, at: place, jitter: 300, utc: time, weekday: 1 + offset)
            }
        }
        let oia = session((2023, 7, 7), from: (20, 0), to: (20, 45), count: 10, place: .oia)
        for time in oia { add(.greece, .photo, at: .oia, jitter: 150, utc: time, weekday: 6) }
        add(.greece, .video, at: .oia, jitter: 150, utc: oia[4] + 150, weekday: 6)
        for time in session((2023, 7, 8), from: (1, 30), to: (1, 39), count: 4, place: .fira) {
            add(.greece, .photo, at: .fira, jitter: 100, utc: time, weekday: 7)
        }
        for time in session((2023, 7, 8), from: (10, 0), to: (11, 15), count: 6, place: .fira) {
            add(.greece, .photo, at: .fira, jitter: 150, utc: time, weekday: 7)
        }
        for (day, hour, minute, weekday) in [(2, 16, 0, 1), (4, 16, 30, 3), (5, 17, 0, 4), (6, 17, 30, 5)] {
            add(.greece, .photo, at: .acropolis, title: "Greece", jitter: 0, utc: utc(2023, 7, day, hour, minute, place: .acropolis),
                located: false, borrowing: .beyondMoment, weekday: weekday)
        }
    }

    /// London over New Year 2022, with a party from 22:00 on the 31st to 02:30 (a photo every 20 minutes).
    mutating func london() {
        for time in session((2021, 12, 30), from: (14, 0), to: (15, 0), count: 5, place: .hydePark) {
            add(.london, .photo, at: .hydePark, jitter: 300, utc: time, weekday: 5)
        }
        let party = utc(2021, 12, 31, 22, 0, place: .towerBridge)
        for step in 0..<14 {
            add(.london, .photo, at: .towerBridge, jitter: 150, utc: party + Int64(step * 20 * 60), weekday: step < 6 ? 6 : 7)
        }
        add(.london, .photo, at: .towerBridge, jitter: 150, utc: party + 270 * 60, weekday: 7)
        for time in session((2022, 1, 2), from: (11, 0), to: (12, 0), count: 5, place: .towerBridge) {
            add(.london, .photo, at: .towerBridge, jitter: 150, utc: time, weekday: 1)
        }
        for time in session((2022, 1, 3), from: (10, 0), to: (11, 0), count: 5, place: .hydePark) {
            add(.london, .photo, at: .hydePark, jitter: 300, utc: time, weekday: 2)
        }
    }

    /// Sydney, Sat 8 – Wed 12 Jan 2022 (UTC+11, southern summer).
    mutating func sydney() {
        for (day, place, start, weekday) in [(8, SeedPlace.operaHouse, 18, 7), (10, .bondiBeach, 9, 2), (12, .operaHouse, 12, 4)] {
            for time in session((2022, 1, day), from: (start, 0), to: (start + 1, 0), count: 5, place: place) {
                add(.sydney, .photo, at: place, jitter: place == .bondiBeach ? 200 : 100, utc: time, weekday: weekday)
            }
        }
    }

    // MARK: Without GPS

    /// Screenshots, photos received late on park days, photos far from any located one, and undated photos.
    mutating func withoutGPS() {
        let riyadh = SeedPlace.home
        let firstScreen = LocalTime.day(year: 2025, month: 1, day: 9)
        for index in 0..<20 {
            let (year, month, day) = LocalTime.civil(day: firstScreen + Int32(32 * index))
            add(.screens, .screenshot, at: riyadh, title: "Screenshot", jitter: 0,
                utc: utc(year, month, day, 10, 15 + 25 * (index % 7), place: riyadh), located: false)
        }
        for day in Self.nakheelDays.filter({ $0.0 >= 2025 }).prefix(6) {
            add(.received, .received, at: riyadh, title: "Received", jitter: 0, utc: utc(day.0, day.1, day.2, 23, 40, place: riyadh),
                located: false, borrowing: .sameDay, weekday: 7)
        }
        for (month, day) in [(2, 17), (5, 19), (7, 23), (9, 10), (12, 1)] {
            add(.orphans, .dateOnly, at: riyadh, title: "No place", jitter: 0, utc: utc(2025, month, day, 12, 0, place: riyadh),
                located: false, borrowing: .noZone)
        }
        for _ in 0..<4 {
            add(.undated, .undated, at: riyadh, title: "Undated", jitter: 0, utc: nil, located: false)
        }
    }

    // MARK: Helpers

    /// `count` capture times spread evenly from `start` to `end` local time on `day` at `place`.
    func session(_ day: (Int, Int, Int), from start: (Int, Int), to end: (Int, Int), count: Int, place: SeedPlace) -> [Int64] {
        let first = utc(day.0, day.1, day.2, start.0, start.1, place: place)
        let last = utc(day.0, day.1, day.2, end.0, end.1, place: place)
        guard count > 1 else { return [first] }
        return (0..<count).map { first + (last - first) * Int64($0) / Int64(count - 1) }
    }

    /// UTC seconds of a local wall time at `place` (minutes past 59 roll into the next hour).
    func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, place: SeedPlace) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = place.timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour + minute / 60, minute: minute % 60)
        guard let date = calendar.date(from: components) else {
            preconditionFailure("invalid seed date \(year)-\(month)-\(day)")
        }
        return Int64(date.timeIntervalSince1970)
    }

    /// The Gregorian date (Riyadh) of a Hijri date on the Umm al-Qura calendar, moved by `offsetDays`.
    static func gregorian(hijriYear: Int, month: Int, day: Int, offsetDays: Int32 = 0) -> (Int, Int, Int) {
        var hijri = Calendar(identifier: .islamicUmmAlQura)
        hijri.timeZone = SeedPlace.familyHouse.timeZone
        guard let date = hijri.date(from: DateComponents(year: hijriYear, month: month, day: day, hour: 12)) else {
            preconditionFailure("invalid Hijri date \(hijriYear)-\(month)-\(day)")
        }
        let wall = LocalTime.wallSeconds(date, in: hijri.timeZone)
        return LocalTime.civil(day: SeedItem.days(wall) + offsetDays)
    }

    mutating func add(_ tag: SeedScenario.Tag, _ media: SeedItem.Media, at place: SeedPlace, title: String? = nil, jitter: Double,
                      utc: Int64?, located: Bool = true, selfie: Bool = false, borrowing: SeedItem.Borrowing = .none, weekday: Int? = nil) {
        let coordinate = located ? jittered(place.coordinate, metres: jitter) : nil
        drafts.append(SeedItem(number: 0, tag: tag, media: media, title: title ?? place.name, utc: utc, zone: place.zone,
                               coordinate: coordinate, isSelfie: selfie, borrowing: borrowing, weekday: weekday))
    }

    /// A point within `metres` of `center`, rounded to 6 decimals (about 0.1 m).
    mutating func jittered(_ center: Coordinate, metres: Double) -> Coordinate {
        let distance = metres * random.unit().squareRoot()
        let bearing = 2 * Double.pi * random.unit()
        let latitude = center.latitude + distance * cos(bearing) / 111_320
        let longitude = center.longitude + distance * sin(bearing) / (111_320 * cos(center.latitude * .pi / 180))
        return Coordinate(latitude: (latitude * 1e6).rounded() / 1e6, longitude: (longitude * 1e6).rounded() / 1e6)
    }
}
#endif
