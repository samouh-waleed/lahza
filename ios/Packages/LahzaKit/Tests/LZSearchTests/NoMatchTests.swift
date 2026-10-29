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
    /// maybe-place, which turns into words about what's in photos).
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
