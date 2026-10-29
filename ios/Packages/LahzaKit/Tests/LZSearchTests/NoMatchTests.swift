import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// No match (search spec §6.8): each case names the failing slot and offers widening taps with counts above 0.
/// The combination, place-empty and only-unsupported cases are HeroSuite goldens #11, #22, #28 and #29.
@Suite struct NoMatchTests {
    static let hero = SeedScenario.hero

    /// "Qwertyville 2025" with the place as a sure name and the year (the parser would call the made-up word a
    /// maybe-place, which no place confirms: `.unconfirmed`).
    private func madeUpPlace(year: Bool = true) -> ParsedQuery {
        var slots = [QuerySlot(id: 0, value: .place(.named("Qwertyville", relation: .in, confidence: .certain)), span: TextSpan(location: 0, length: 11))]
        if year { slots.append(QuerySlot(id: 1, value: .time(.year(2025)), span: TextSpan(location: 12, length: 4))) }
        return ParsedQuery(text: year ? "Qwertyville 2025" : "Qwertyville", slots: slots)
    }

    private var bestIn2025: Int {
        let first = LocalTime.day(year: 2025, month: 1, day: 1), last = LocalTime.day(year: 2025, month: 12, day: 31)
        return Self.hero.items.count { $0.media != .screenshot && $0.momentDay.map { (first...last).contains($0) } == true }
    }

    @Test func aPlaceThatCantBeFoundOffersTheSearchWithoutIt() async throws {
        let offline = try await HeroSearch(reachable: false)
        let result = try await offline.search(SearchRequest(text: "Qwertyville 2025", parsed: madeUpPlace()))
        #expect(result.noMatch?.kind == .placeNotFound(.offline))
        #expect(result.noMatch?.headline == "Couldn’t look up “Qwertyville” offline.")
        #expect(result.noMatch?.offers.map(\.label) == ["Search without the place"])
        #expect(result.noMatch?.offers.first?.count == bestIn2025)
        #expect(result.noMatch?.offers.first?.edits == [.remove(slot: 0)])

        let online = try await HeroSearch()
        let notFound = try await online.search(SearchRequest(text: "Qwertyville", parsed: madeUpPlace(year: false)))
        #expect(notFound.noMatch?.kind == .placeNotFound(.notFound))
        #expect(notFound.noMatch?.headline == "Couldn’t find “Qwertyville” in your photos or on the map.")
        #expect(notFound.noMatch?.offers.isEmpty == true, "nothing is left to search")
        #expect(online.mapsSearches == 1)

        let off = try await online.engine.search(SearchRequest(text: "Qwertyville", parsed: madeUpPlace(year: false)), reader: online.index.reader,
                                                 writer: nil, index: SearchIndexContext(appleMapsEnabled: false))
        #expect(off.noMatch?.kind == .placeNotFound(.notFound), "the cached answer (nothing) is reused")
    }

    @Test func appleMapsOffIsNamed() async throws {
        let search = try await HeroSearch()
        let result = try await search.engine.search(SearchRequest(text: "Qwertyville", parsed: madeUpPlace(year: false)), reader: search.index.reader,
                                                    writer: nil, index: SearchIndexContext(appleMapsEnabled: false))
        #expect(result.noMatch?.kind == .placeNotFound(.appleMapsOff))
        #expect(search.mapsSearches == 0)
    }

    @Test func anAreaWithPhotosJustBeyondItOffersToWiden() async throws {
        let search = try await HeroSearch()
        // A saved spot 600 m north of the park, 150 m across.
        let north = SeedPlace.alNakheelPark.coordinate.latitude + 600 / 111_320
        try await search.index.database.write { db in
            try db.execute(sql: """
                INSERT INTO saved_place (id, name, name_folded, lat, lon, radius_m, is_home, created_utc, updated_utc)
                VALUES (3, 'Spot', 'spot', ?, ?, 150, 0, 0, 0)
                """, arguments: [north, SeedPlace.alNakheelPark.coordinate.longitude])
        }
        let parsed = ParsedQuery(text: "Spot", slots: [QuerySlot(id: 0, value: .place(.alias(.saved(3), relation: .at)), span: TextSpan(location: 0, length: 4))])
        let result = try await search.search(SearchRequest(text: "Spot", parsed: parsed))
        #expect(result.noMatch?.kind == .onlyBeyondRadius)
        #expect(result.noMatch?.headline == "None within 150 m of Spot. \(Self.hero.items(.nakheel).count) within 750 m.")
        #expect(result.noMatch?.offers.first?.edits == [.setRadius(slot: 0, metres: 750)])
    }

    @Test func datesWithoutPhotosOfferEveryOccurrenceAndTheClosestYear() async throws {
        let search = try await HeroSearch()
        let result = try await search.search("Ramadan 2019")
        let noMatch = try #require(result.noMatch)
        #expect(noMatch.kind == .timeEmpty)
        #expect(noMatch.headline == "No photos from Ramadan 2019.")
        #expect(noMatch.detail == "Your library starts in 2021.")
        #expect(noMatch.offers.first?.label == "Every Ramadan")
        #expect(noMatch.offers.first?.edits == [.replaceTime(slot: 0, .hijri(.ramadan, .every, hijriYear: nil))])
        #expect(noMatch.offers.dropFirst().first?.label.hasPrefix("Closest: Ramadan 20") == true)
        #expect(noMatch.offers.allSatisfy { $0.count > 0 })
        // A Hijri year's closest year is counted from the Gregorian year its Ramadan began in.
        #expect(NoMatchBuilder.gregorianYear(of: .ramadan, hijriYear: 1440) == 2019)
        #expect(NoMatchBuilder.gregorianYear(of: .ramadan, hijriYear: 1447) == 2026)
        #expect(NoMatchBuilder.gregorianYear(of: .eidAlAdha, hijriYear: 1446) == 2025)

        let reading = try await search.search("Ramadan 2019", index: SearchIndexContext(isPartial: true, coveredSince: Date(timeIntervalSince1970: 1_609_459_200)))
        #expect(reading.noMatch?.kind == .stillReading)
        #expect(reading.noMatch?.headline == "Still reading your library: photos before Jan 2021 aren’t searchable yet.")

        let future = try await search.search("summer 2030")
        #expect(future.noMatch?.kind == .future)
        #expect(future.noMatch?.headline == "That’s in the future.")
    }

    @Test func aPhotoTypeWithoutPhotosIsNamedFirst() async throws {
        let search = try await HeroSearch()
        let result = try await search.search("favorite videos at Al-Nakheel Park")
        #expect(result.noMatch?.kind == .mediaEmpty)
        #expect(result.noMatch?.headline == "No favorites found.")
        #expect(result.noMatch?.offers.map(\.label) == ["All photos"])
        #expect(result.noMatch?.offers.first?.count == Self.hero.items(.nakheel).count)
    }

    @Test func tripsAtAPlaceAtHomeOfferEachSlotAlone() async throws {
        let search = try await HeroSearch()
        // The park is in the home city, so no trip goes there; trips and the park each find photos alone.
        let result = try await search.search("trips at Al-Nakheel Park")
        #expect(result.noMatch?.kind == .nothing)
        #expect(result.noMatch?.headline == "Nothing matches all of that.")
        let onTrips = Self.hero.items.count { item in item.momentDay.map { day in Self.hero.trips.contains { $0.contains(day: day) } } == true }
        #expect(result.noMatch?.offers.map(\.label) == ["Anywhere", "Not only trips"])
        #expect(result.noMatch?.offers.map(\.count) == [onTrips, Self.hero.items(.nakheel).count])
    }

    @Test func aLeftoverWordNeitherBlocksThePlaceNorSpendsItsAppleMapsSearch() async throws {
        // Offline and with Apple Maps off, "kebab" can't be looked up; the park is still searched.
        for (reachable, appleMaps) in [(false, true), (true, false)] {
            let search = try await HeroSearch(reachable: reachable)
            let result = try await search.engine.search(SearchRequest(text: "kebab at Al-Nakheel Park"), reader: search.index.reader, writer: search.index.writer,
                                                        index: SearchIndexContext(appleMapsEnabled: appleMaps))
            #expect(result.noMatch == nil)
            #expect(Set(result.items(.best).map(\.id)) == Set(Self.hero.items(.nakheel).map(\.id)))
            #expect(result.query.slots.map(\.slot.kind) == [.visual, .place], "kebab is words about what’s in the photos")
            #expect(result.unsupportedNotice == "Lahza can’t see what’s in photos yet, so “kebab” was left out. Showing all your photos at Al-Nakheel Park.")
            #expect(search.mapsSearches == 0)
        }
        // Online, the place a preposition introduced gets the query's one Apple Maps search.
        let online = try await HeroSearch()
        let sufra = try await online.search("kebab at Sufra Grill")
        #expect(Set(sufra.items(.best).map(\.id)) == Set(Self.hero.items(.sufra).map(\.id)))
        #expect(online.maps.calls.map { if case .search(let text, _) = $0 { text } else { "" } } == ["Sufra Grill"])
        // Alone, a leftover word that can't be looked up is still the failing place.
        let offline = try await HeroSearch(reachable: false)
        #expect(try await offline.search("Qwertyville").noMatch?.kind == .placeNotFound(.offline))
    }

    /// Apple Maps answers "Louvre" with "Musée du Louvre", a name that isn't the words typed.
    private static var louvreTable: FakeMapsClient.Table {
        var table = SeedMaps.hero
        table.searches["louvre"] = [MapPlace(appleID: "louvre", name: "Musée du Louvre", category: .museum,
                                             coordinate: Coordinate(latitude: 48.8606, longitude: 2.3376), cityName: "Paris", countryCode: "FR")]
        return table
    }

    @Test func aNameNoPlaceConfirmsIsAPlaceThatWasntFound() async throws {
        let search = try await HeroSearch(table: Self.louvreTable)
        let louvre = try await search.search("Louvre")
        #expect(louvre.noMatch?.kind == .placeNotFound(.unconfirmed))
        #expect(louvre.noMatch?.headline == "Couldn’t find “Louvre” in your photos or on the map.")
        #expect(louvre.noMatch?.detail == nil)
        #expect(louvre.noMatch?.offers.isEmpty == true, "nothing is left to search")
        #expect(louvre.query.slots.map(\.chip) == ["Louvre"])
        #expect(louvre.query.slots.map(\.systemImage) == ["mappin"])
        #expect(louvre.query.slots.map(\.isSupported) == [true], "a place chip, not words about what’s in the photos")
        #expect(louvre.unsupported.isEmpty && louvre.unsupportedNotice == nil)
        #expect(search.mapsSearches == 1)

        // Again: the same answer, though Apple's places are kept in the index (no second Apple Maps search). The
        // words are quoted as typed, and the dates stay searchable without the place.
        let again = try await search.search("Louvre")
        #expect(again.noMatch?.headline == louvre.noMatch?.headline)
        let typed = try await search.search("louvre 2025")
        #expect(typed.noMatch?.headline == "Couldn’t find “louvre” in your photos or on the map.")
        #expect(typed.noMatch?.offers.map(\.label) == ["Search without the place"])
        #expect(typed.noMatch?.offers.first?.count == bestIn2025)
        #expect(typed.query.slots.first?.chip == "Louvre")
        #expect(search.mapsSearches == 1)

        // A lone word that is neither about what's in photos nor a place Apple Maps knows ("kebab") reads the same.
        let kebab = try await search.search("kebab")
        #expect(kebab.noMatch?.kind == .placeNotFound(.unconfirmed))
        #expect(kebab.noMatch?.headline == "Couldn’t find “kebab” in your photos or on the map.")
        #expect(kebab.query.slots.map(\.chip) == ["Kebab"])
        #expect(kebab.query.slots.map(\.slot.kind) == [.place])

        // Words about what's in photos are still that, without an Apple Maps search.
        let sunset = try await search.search("sunset")
        #expect(sunset.noMatch?.kind == .onlyUnsupported)
        #expect(sunset.query.slots.map(\.slot.kind) == [.visual])
        #expect(search.mapsSearches == 2)
    }

    @Test func anUnconfirmedNameThatCouldntBeLookedUpSaysWhy() async throws {
        let offline = try await HeroSearch(reachable: false, table: Self.louvreTable)
        let away = try await offline.search("Louvre")
        #expect(away.noMatch?.kind == .placeNotFound(.offline))
        #expect(away.noMatch?.headline == "Couldn’t look up “Louvre” offline.")
        #expect(away.noMatch?.detail == "Places in your photos still work without internet.")
        #expect(away.query.slots.map(\.systemImage) == ["mappin"] && away.query.slots.map(\.isSupported) == [true])

        let online = try await HeroSearch(table: Self.louvreTable)
        let off = try await online.search("Louvre", index: SearchIndexContext(appleMapsEnabled: false))
        #expect(off.noMatch?.kind == .placeNotFound(.appleMapsOff))
        #expect(off.noMatch?.headline == "Couldn’t find “Louvre” in your photos.")
        #expect(off.noMatch?.detail == "Apple Maps place names are off in Settings › Search index.")
        #expect(off.query.slots.map(\.systemImage) == ["mappin"] && off.query.slots.map(\.isSupported) == [true])
        #expect(online.mapsSearches == 0)

        let clock = FixedClock(SearchFixture.now)
        let busy = try await HeroSearch(budget: MapsBudget(perMinute: 30, capacity: 1, interactiveReserve: 0, clock: clock), table: Self.louvreTable)
        busy.maps.failNext(.throttled)
        let throttled = try await busy.search("Louvre")
        #expect(throttled.noMatch?.kind == .placeNotFound(.mapsBusy))
        #expect(throttled.noMatch?.headline == "Couldn’t look up “Louvre” right now.")
        #expect(throttled.query.slots.map(\.systemImage) == ["mappin"] && throttled.query.slots.map(\.isSupported) == [true])
    }

    @Test func onlyTheFirstUnconfirmedNameIsThePlace() async throws {
        // The name after "at" is looked up first and isn't confirmed; "kebab" then stays words about what's in the photos.
        let search = try await HeroSearch(table: Self.louvreTable)
        let result = try await search.search("kebab at the Louvre")
        #expect(result.noMatch?.kind == .placeNotFound(.unconfirmed))
        #expect(result.noMatch?.headline == "Couldn’t find “Louvre” in your photos or on the map.")
        #expect(result.query.slots.map(\.slot.kind) == [.visual, .place])
        #expect(result.query.slots.map(\.chip) == ["kebab", "Louvre"])
        #expect(result.unsupportedNotice == "Lahza can’t see what’s in photos yet, so “kebab” was left out.")
        #expect(search.maps.calls.map { if case .search(let text, _) = $0 { text } else { "" } } == ["Louvre"])

        // Next to a place that is found, a leftover word is words about what's in the photos, as before.
        let park = try await search.search("kebab at Al-Nakheel Park")
        #expect(park.noMatch == nil)
        #expect(park.query.slots.map(\.slot.kind) == [.visual, .place])
        #expect(search.mapsSearches == 1)
    }

    @Test func anUnconfirmedNameNextToAFoundPlaceIsASecondPlace() async throws {
        // "Louvre" (after "at") is looked up first and isn't confirmed; the leftover "nakheel" then finds the park
        // without Apple Maps. The name is left out as a second place, as when the park is typed in full, never as
        // words about what's in the photos.
        let search = try await HeroSearch(table: Self.louvreTable)
        for text in ["nakheel at the Louvre", "Al-Nakheel Park at the Louvre"] {
            let result = try await search.search(text)
            #expect(result.noMatch == nil, "\(text)")
            #expect(Set(result.items(.best).map(\.id)) == Set(Self.hero.items(.nakheel).map(\.id)), "\(text)")
            #expect(result.query.slots.map(\.chip) == ["Al-Nakheel Park", "Louvre"], "\(text)")
            #expect(result.query.slots.map(\.slot.kind) == [.place, .place], "\(text)")
            #expect(result.query.slots.map(\.isSupported) == [true, false], "\(text)")
            #expect(result.unsupportedNotice
                == "Lahza can’t search for everything you asked yet, so “Louvre” was left out. Showing all your photos at Al-Nakheel Park.", "\(text)")
        }
        #expect(search.mapsSearches == 1, "only the first query looks the name up")
    }

    @Test func aBusyAppleMapsIsntCalledOffline() async throws {
        let clock = FixedClock(SearchFixture.now)
        let search = try await HeroSearch(budget: MapsBudget(perMinute: 30, capacity: 1, interactiveReserve: 0, clock: clock))
        search.maps.failNext(.throttled)
        let result = try await search.search(SearchRequest(text: "Qwertyville", parsed: madeUpPlace(year: false)))
        #expect(result.noMatch?.kind == .placeNotFound(.mapsBusy))
        #expect(result.noMatch?.headline == "Couldn’t look up “Qwertyville” right now.")
        #expect(result.noMatch?.detail == "Apple Maps is busy. Try again in a few minutes.")
        #expect(result.query.searchedAppleMaps)
        // Backing off, no request is sent, and none is counted.
        let again = try await search.search(SearchRequest(text: "Qwertyville", parsed: madeUpPlace(year: false)))
        #expect(again.noMatch?.kind == .placeNotFound(.mapsBusy))
        #expect(!again.query.searchedAppleMaps)
        #expect(search.mapsSearches == 1)
    }
}
