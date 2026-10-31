import Foundation
import LZCore
import LZGeo
import LZLibrary
import Synchronization
import Testing
@testable import LZIndex
@testable import LZSearch

/// Search by photo tags (content search Milestone A) beyond the HeroSuite goldens: photos not checked yet are left out
/// and counted, never "no" (E25); before any photo is checked search says so; related tags can be removed and brought
/// back (E24); what the index can search comes from the index; words with no tag are named.
@Suite struct VisualSearchTests {
    /// The seed tagged, but for the items `skip` picks, which are left only in iCloud.
    struct PartialAnalyzer: VisualAnalyzer {
        let seed = SeedVisualAnalyzer(labels: VisualVocabulary.english.labels)
        let skip: @Sendable (SeedItem) -> Bool

        func supportedLabels() async -> [String] { await seed.supportedLabels() }

        func analyze(_ asset: VisualAsset) async -> VisualOutcome {
            if let item = SeedScenario.hero.item(id: asset.localID), skip(item) { return .inCloud }
            return await seed.analyze(asset)
        }
    }

    /// A hero search whose index was tagged by `analyzer`.
    private func search(tagging analyzer: any VisualAnalyzer) async throws -> HeroSearch {
        let search = try await HeroSearch()
        let queue = VisualQueue(database: search.index.database, analyzer: analyzer, clock: search.clock,
                                notify: { await search.index.indexer.enqueue(.restructure) })
        await queue.run()
        await search.index.indexer.settled()
        return search
    }

    static var nakheel2026: @Sendable (SeedItem) -> Bool {
        { $0.tag == .nakheel && ($0.utc ?? 0) >= 1_767_225_600 }
    }

    @Test func photosNotCheckedYetAreLeftOutAndCounted() async throws {
        let search = try await search(tagging: PartialAnalyzer(skip: Self.nakheel2026))
        let result = try await search.search("soccer")
        let items = result.items(.best) + result.items(.more)
        #expect(!items.isEmpty)
        #expect(!items.contains(where: Self.nakheel2026), "unknown, never a match nor a no")
        let unchecked = SeedScenario.hero.items.count { Self.nakheel2026($0) || $0.tag == .orphans }
        let total = SeedScenario.hero.items.count
        #expect(result.coverage.visualLine == "Checked \(total - unchecked) of \(total) photos so far")
    }

    @Test func beforeAnyPhotoIsCheckedSearchSaysSo() async throws {
        let search = try await search(tagging: PartialAnalyzer(skip: { _ in true }))
        let result = try await search.search("soccer")
        #expect(result.noMatch?.kind == .notTagged)
        #expect(result.noMatch?.headline == "Lahza is still checking what’s in your photos.")
        #expect(result.noMatch?.detail == "Checked 0 of \(SeedScenario.hero.items.count) photos so far. It looks while Lahza is open.")
        #expect(result.query.slots.map(\.chip) == ["soccer · photo tag"], "the word is searchable; the photos aren't checked yet")
    }

    @Test func aChipListsItsTagsAndTheRelatedOnesCanBeRemovedAndBroughtBack() async throws {
        let search = try await HeroSearch.tagged.value
        let hike = try await search.search("hike")
        let slot = try #require(hike.query.slots.first)
        guard case .visual(let match) = slot.resolution else {
            Issue.record("not a visual slot")
            return
        }
        #expect(match == VisualMatch(concept: "hiking", tags: ["hiking"], related: ["trail", "mountain", "cliff", "canyon", "hill", "forest"]))
        #expect(slot.systemImage == "tag")

        // "mountain" has no photo of its own in the seed, only related ones (cliffs).
        let mountain = try await search.search("mountain")
        #expect(mountain.noMatch == nil && mountain.items(.best).isEmpty && !mountain.items(.more).isEmpty)
        let mountainSlot = try #require(mountain.query.slots.first?.id)
        var overrides = ResolutionOverrides()
        overrides.apply(.setRelatedTags(slot: mountainSlot, false))
        let strict = try await search.search(SearchRequest(text: "mountain", parsed: mountain.query.parsed, overrides: overrides))
        #expect(strict.noMatch?.kind == .notTagged)
        let checked = SeedScenario.hero.items.count { !SeedLabels.analysis(for: $0).inCloud }
        #expect(strict.noMatch?.headline == "No photos tagged mountain among \(checked) checked.")
        let offer = try #require(strict.noMatch?.offers.first)
        #expect(offer.label == "Include related tags" && offer.count == mountain.items(.more).count)
        #expect(offer.edits == [.setRelatedTags(slot: mountainSlot, true)])
        if case .visual(let removed) = strict.query.slots.first?.resolution { #expect(removed.relatedRemoved) } else { Issue.record("not visual") }
    }

    @Test func wordsWithNoTagAreNamed() async throws {
        let search = try await HeroSearch.tagged.value
        let result = try await search.search("soccer party at Al-Nakheel Park")
        #expect(result.unsupportedNotice == "Lahza has no photo tag for that yet, so “party” was left out. Showing all your photos tagged soccer at Al-Nakheel Park.")
        #expect(result.query.slots.filter(\.isSupported).map(\.chip) == ["soccer · photo tag", "Al-Nakheel Park"])
    }

    /// Two words with tags are two slots, both needed (a soft AND): the pitch photos tagged both soccer and grass.
    @Test func twoTaggedWordsAreBothNeeded() async throws {
        let search = try await HeroSearch.tagged.value
        let result = try await search.search("soccer grass")
        #expect(result.query.slots.map(\.chip) == ["soccer · photo tag", "grass · photo tag"])
        let expected = SeedScenario.hero.items.filter { item in
            let tags = SeedLabels.analysis(for: item).labels
            return (tags["soccer"] ?? .candidate) >= .likely && (tags["grass"] ?? .candidate) >= .likely
        }
        #expect(Set(result.items(.best).map(\.number)) == Set(expected.map(\.number)))
    }

    @Test func whatAnIndexCanSearchComesFromIt() {
        let tagged = SearchCapabilities(IndexStatus(phase: .ready, visual: VisualProgress()))
        #expect(tagged.supports(.visual("soccer")) && tagged.supports(.visual("hikes")))
        #expect(!tagged.supports(.visual("party")), "no tag for it")
        let untagged = SearchCapabilities(IndexStatus(phase: .ready))
        #expect(!untagged.supports(.visual("soccer")))
        #expect(!tagged.supports(.people("Ahmed")))
    }

    /// An index without a Vision pass searches as v0 did: words about photos are "not yet".
    @Test func withoutAPassWordsAboutPhotosAreLeftOut() async throws {
        let search = try await HeroSearch.shared.value
        let result = try await search.search("soccer")
        #expect(result.noMatch?.kind == .onlyUnsupported)
        #expect(result.noMatch?.headline == "Lahza can’t search what’s in photos yet. Try a place, a date or a photo type.")
    }

    /// The first time something was in the photos, and every time oldest first.
    @Test func ordersWorkWithTags() async throws {
        let search = try await HeroSearch.tagged.value
        let first = try await search.search("my first sunset")
        #expect(first.sections.first?.title == "First sunset")
        let oldest = try await search.search("soccer oldest first")
        let days = oldest.cards.filter { $0.tier == .best }.map(\.id.day)
        #expect(days == days.sorted() && days.count > 1)
    }
}
