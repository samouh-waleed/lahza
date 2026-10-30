import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// Search over saved places (search spec §7.4, PR 4 acceptance 5) and the DEBUG query lab (§8.3).
@Suite struct SavedPlaceSearchTests {
    /// The keys of the ten nakheel sessions (Apple Maps labels them with the park) and a session's centre.
    private func nakheel(_ search: HeroSearch) async throws -> (keys: [MomentKey], center: Coordinate) {
        let keys = try await search.index.reader.moments(after: nil, limit: 500).filter { $0.label == "Al-Nakheel Park" }.map(\.key)
        let first = try #require(keys.first)
        let center = try #require(try await search.index.reader.moment(first)?.moment.center)
        return (keys, center)
    }

    @Test func atMyPitchFindsTheNakheelSessionsAndTheirLabelsReadIt() async throws {
        let search = try await HeroSearch()
        let (keys, center) = try await nakheel(search)
        #expect(keys.count == 10)
        _ = try await search.search("Al-Nakheel Park")
        try await search.index.writer.savePlace(name: "My pitch", center: center, radius: 250, isHome: false)
        await search.engine.savedPlacesChanged()
        await search.index.indexer.settled()

        let result = try await search.search("at my pitch")
        #expect(result.query.slots.first?.chip == "My pitch")
        let nakheel = SeedScenario.hero.items.filter { $0.tag == .nakheel }
        #expect(nakheel.count == 85)
        #expect(Set(result.items(.best).map(\.number)) == Set(nakheel.map(\.number)), "Best is the 85 nakheel items")
        #expect(result.items(.more).allSatisfy { $0.coordinate == nil }, "More holds only photos saved the days of the sessions")
        let labelled = result.cards.compactMap(\.moment).filter { keys.contains($0.key) }
        #expect(labelled.count == 10 && labelled.allSatisfy { $0.label == "My pitch" }, "the moment labels read the saved name")

        let bare = try await search.search("pitch")
        #expect(bare.query.slots.first?.chip == "My pitch", "the name without “my” is an alias too")
        #expect(Set(bare.items(.best).map(\.number)) == Set(nakheel.map(\.number)))
    }

    @Test func theParseKnowsASavedNameOnceSearchIsTold() async throws {
        let search = try await HeroSearch()
        let (_, center) = try await nakheel(search)
        #expect(await search.engine.parse("my pitch", reader: search.index.reader).values == [.visual("pitch")])
        let id = try await search.index.writer.savePlace(name: "My pitch", center: center, radius: 250, isHome: false)
        // The clock is fixed, so the vocabulary's 2 s debounce never ends on its own.
        #expect(await search.engine.parse("my pitch", reader: search.index.reader).values == [.visual("pitch")])
        await search.engine.savedPlacesChanged()
        #expect(await search.engine.parse("my pitch", reader: search.index.reader).values == [.place(.alias(.saved(id), relation: .at))])
    }

    /// E22: "at my pitch" with no saved place of that name says so, as a place, with the examples under it, and never
    /// asks Apple Maps; once saved, the name finds the place.
    @Test func anUnsavedNameSaysSoAndIsNeverLookedUp() async throws {
        let search = try await HeroSearch()
        let examples = try await search.engine.examples(reader: search.index.reader)
        let pitch = try await search.search("at my pitch")
        let noMatch = try #require(pitch.noMatch)
        #expect(noMatch.kind == .placeNotFound(.notSaved))
        #expect(noMatch.headline == "You have no saved place called “my pitch”.")
        #expect(noMatch.detail == "Save one from a moment.")
        #expect(noMatch.offers.isEmpty && noMatch.examples == examples, "the examples are the next tap")
        #expect(pitch.query.slots.map(\.chip) == ["My pitch"] && pitch.query.slots.map(\.isSupported) == [true], "a place chip, not “not yet”")
        #expect(pitch.query.slots.first?.resolution == .place(.notFound(.notSaved)))
        #expect(pitch.unsupportedNotice == nil)

        let cabin = try await search.search("near our cabin")
        #expect(cabin.noMatch?.headline == "You have no saved place called “our cabin”.")
        #expect(cabin.query.slots.map(\.chip) == ["Near our cabin"])

        // With dates, the search without the place is the offer.
        let summer = try await search.search("at my pitch last summer")
        #expect(summer.noMatch?.kind == .placeNotFound(.notSaved))
        #expect(summer.noMatch?.offers.map(\.label) == ["Search without the place"] && summer.noMatch?.examples.isEmpty == true)
        let lastSummer = try await search.search("last summer")
        #expect(summer.noMatch?.offers.first?.count == lastSummer.items(.best).count)

        // Next to a place that is found, it is left out like a second place.
        let park = try await search.search("Al-Nakheel Park near my house")
        #expect(park.noMatch == nil && park.query.slots.map(\.chip) == ["Al-Nakheel Park", "near my house"])
        #expect(park.unsupported.map(\.kind) == [.place])
        #expect(search.maps.calls.isEmpty, "none of these words went to Apple Maps")

        // Words about what's in photos, people and home are as they were.
        #expect(try await search.search("photos of my dog").noMatch?.kind == .onlyUnsupported)
        #expect(try await search.search("my dog").query.slots.map(\.slot.kind) == [.visual])
        #expect(try await search.search("with my kids").query.slots.map(\.slot.kind) == [.people])
        for text in ["at home", "at my home"] {
            let home = try await search.search(text)
            #expect(home.noMatch == nil && home.query.slots.map(\.chip) == ["Home (estimated)"], "\(text)")
        }
        let soccer = try await search.search("soccer at Al-Nakheel Park")
        #expect(soccer.query.slots.map(\.chip) == ["soccer", "Al-Nakheel Park"] && soccer.noMatch == nil)

        // Saved, the same words find it; another unsaved name still says so.
        let (_, center) = try await nakheel(search)
        try await search.index.writer.savePlace(name: "My pitch", center: center, radius: 250, isHome: false)
        await search.engine.savedPlacesChanged()
        await search.index.indexer.settled()
        let saved = try await search.search("at my pitch")
        #expect(saved.noMatch == nil && saved.query.slots.map(\.chip) == ["My pitch"])
        #expect(Set(saved.items(.best).map(\.number)) == Set(SeedScenario.hero.items(.nakheel).map(\.number)))
        #expect(try await search.search("near our cabin").noMatch?.kind == .placeNotFound(.notSaved))
        #expect(search.maps.calls.isEmpty)
    }

    /// E22 is for places only: "my …" after "from", "in" or "by" with no place word stays words about photos, as do
    /// people after "near"; words naming a trip still search trips. None of it is looked up.
    @Test func peopleAndTripsAfterMyAreNoPlace() async throws {
        let search = try await HeroSearch()
        for text in ["photos from my uncle", "photos by my boyfriend", "photos from my WhatsApp", "in my twenties", "near my uncle"] {
            let result = try await search.search(text)
            #expect(result.noMatch?.kind == .onlyUnsupported, "\(text)")
            #expect(result.query.slots.map(\.slot.kind) == [.visual] && result.query.slots.map(\.isSupported) == [false], "\(text)")
        }
        let trips = try await search.search("trips")
        let travels = try await search.search("photos from my travels")
        #expect(travels.noMatch == nil && travels.query.slots.map(\.chip) == ["Trips"])
        #expect(Set(travels.items(.best).map(\.id)) == Set(trips.items(.best).map(\.id)))
        let greece = try await search.search("from my travels in Greece")
        #expect(greece.noMatch == nil && greece.query.slots.map(\.chip) == ["Trips", "Greece"])
        let overseas = try await search.search("photos from my overseas trip")
        #expect(overseas.noMatch == nil && overseas.query.slots.map(\.chip) == ["Abroad", "Trips"])
        #expect(search.maps.calls.isEmpty)
    }

    /// "home" after the person chose No home says so; before Lahza has worked one out, it says that.
    @Test func homeAfterNoHomeSaysYouChoseIt() async throws {
        let search = try await HeroSearch()
        #expect(try await search.search("home").noMatch == nil)
        try await search.index.writer.setHome(.noHome)
        await search.engine.savedPlacesChanged()
        await search.index.indexer.settled()
        let home = try await search.search("home")
        #expect(home.noMatch?.kind == .placeNotFound(.choseNoHome))
        #expect(home.noMatch?.headline == "You chose No home.")
        #expect(home.noMatch?.detail == "Choose one in Settings › Saved places.")
        #expect(home.query.slots.map(\.chip) == ["Home"])

        let empty = try await HeroSearch(placeNames: false)
        try await empty.index.database.write { db in try db.execute(sql: "DELETE FROM home_base") }
        await empty.engine.releaseCaches()
        let unknown = try await empty.search("at home")
        #expect(unknown.noMatch?.kind == .placeNotFound(.noHome))
        #expect(unknown.noMatch?.headline == "Lahza hasn’t worked out your home yet." && unknown.noMatch?.detail == "Save it from a photo.")
    }

    #if DEBUG
    @Test func theQueryLabShowsEachStep() async throws {
        let search = try await HeroSearch.shared.value
        let lab = try await search.engine.lab("Al-Nakheel Park last summer", reader: search.index.reader, appleMaps: false)
        #expect(lab.chips.first == "place → Al-Nakheel Park")
        #expect(lab.chips.contains { $0.hasPrefix("time → Last summer") })
        #expect(lab.parsedJSON.contains("\"span\"") && lab.parsedJSON.contains("\"location\""), "slots with their UTF-16 spans")
        #expect(lab.time.first?.hasPrefix("2026-06-01T") == true && lab.time.first?.contains("→ 2026-09-01T") == true, "ranges as ISO local times")
        let chosen = try #require(lab.candidates.first { $0.isChosen })
        #expect(chosen.name == "Al-Nakheel Park" && chosen.photos >= 83 && chosen.source == "ownIndex")
        #expect(lab.slotCounts.count == 2 && lab.slotCounts.first?.label == "place Al-Nakheel Park" && lab.slotCounts[1].label.hasPrefix("time Last summer"))
        let place = try await search.search("Al-Nakheel Park"), both = try await search.search("Al-Nakheel Park last summer")
        #expect(lab.slotCounts.first?.best == place.hits.count { $0.tier == .best }, "the place alone counts what its search's Best holds")
        #expect(lab.tiers[.best] == both.hits.count { $0.tier == .best } && (lab.tiers[.best] ?? 0) > 0, "the same Best as the search")
        #expect(lab.top.count == 20)
        #expect(lab.top.map(\.score) == lab.top.map(\.score).sorted(by: >))
        #expect(lab.top.first?.tier == .best && lab.top.first?.slots.hasPrefix("place 1.00 · time 1.00") == true)
        #expect(lab.timings.total > .zero && !lab.searchedAppleMaps)
    }
    #endif
}
