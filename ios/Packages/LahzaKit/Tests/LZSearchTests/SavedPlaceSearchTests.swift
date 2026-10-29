import Foundation
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
