import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// Ask's search store (search spec §7.1) over the hero library through an index store: submit → results, a picker
/// choice remembered, a widening tap, chip edits re-rendering the text, re-runs when the index changes, the layout
/// preference, and no index.
@MainActor @Suite struct SearchStoreTests {
    static let hero = SeedScenario.hero

    private func stores(kv: any KeyValueStore = InMemoryKeyValueStore(), start: Bool = true,
                        scope: @escaping @MainActor () -> SearchScope = { .wholeLibrary }) async -> (IndexStore, SearchStore) {
        let clock = OffsetClock(pinnedNow: SearchFixture.now)
        let index = IndexStore(IndexDependencies(
            location: .inMemory, reader: FakeLibraryReader(.seed(.hero)), gazetteer: SearchFixture.gazetteer, maps: SeedMaps.client(),
            budget: MapsBudget(perMinute: 60_000, capacity: 10_000, clock: clock), clock: clock, network: FakeNetworkStatus(reachable: true), kv: kv,
            deviceTimeZone: { SearchFixture.riyadh }, changes: { AsyncStream { $0.finish() } }))
        let engine = SearchEngine(gazetteer: SearchFixture.gazetteer, maps: SeedMaps.client(), budget: MapsBudget(clock: clock), clock: clock,
                                  network: FakeNetworkStatus(reachable: true), locale: SearchFixture.uk, deviceTimeZone: { SearchFixture.riyadh })
        let search = SearchStore(engine: engine, index: index, kv: kv, clock: clock, scope: scope, rerunDelay: .milliseconds(20),
                                 examplesDelay: .milliseconds(20), previewDelay: .milliseconds(10))
        if start {
            index.start()
            await index.placeNamesSettled()
        }
        return (index, search)
    }

    private func best(_ result: SearchResult?) -> Set<String> {
        Set(result?.hits.filter { $0.tier == .best }.map(\.localID) ?? [])
    }

    @Test func submittingSearchesAndPreviewingParses() async throws {
        let (_, search) = await stores()
        search.preview("videos at Al-Nakheel Park")
        await search.settled()
        #expect(search.parsed?.slots.map(\.kind) == [.media, .place])
        #expect(search.state == .idle, "a preview doesn't search")

        search.submit("  Al-Nakheel Park ")
        #expect(search.state == .understanding)
        await search.settled()
        guard case .results(let result) = search.state else { Issue.record("state \(search.state)"); return }
        #expect(search.text == "Al-Nakheel Park")
        #expect(best(result) == Set(Self.hero.items(.nakheel).map(\.id)))
        #expect(search.currentSearchID == result.id)
        search.clear()
        #expect(search.state == .idle && search.result == nil && search.parsed == nil)
    }

    @Test func aPickerChoiceIsRememberedForTheseWords() async throws {
        let (index, search) = await stores()
        search.submit("Salam Park")
        await search.settled()
        let picker = try #require(search.result?.query.picker)
        let dubai = try #require(picker.choices.filter { $0.candidate.context == "Dubai" }.first)
        search.choose(dubai)
        await search.settled()
        let twin = Self.hero.items(.dubai1).filter { $0.title == SeedPlace.salamParkDubai.name }
        #expect(best(search.result) == Set(twin.map(\.id)))
        #expect(search.text == "Salam Park")
        #expect(search.result?.query.picker?.chosen == dubai.candidate.id, "the picker stays, the choice ticked")
        #expect(search.result?.query.picker?.choices.map(\.id) == picker.choices.map(\.id))
        for _ in 0..<50 where try await index.reader?.placeChoice(for: "salam park") == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await index.reader?.placeChoice(for: "salam park")?.placeKey == dubai.candidate.id)

        search.submit("Salam Park")
        await search.settled()
        #expect(best(search.result) == Set(twin.map(\.id)), "typed again, the remembered pick wins")
        #expect(search.result?.query.picker == nil)
    }

    @Test func aWideningTapEditsTheSlotsAndSearchesAgain() async throws {
        let (_, search) = await stores()
        search.submit("Al-Nakheel Park during Ramadan 2024")
        await search.settled()
        guard case .noMatch(let result) = search.state, let offer = result.noMatch?.offers.first else { Issue.record("state \(search.state)"); return }
        search.widen(offer)
        await search.settled()
        #expect(search.text == "Al-Nakheel Park")
        #expect(search.parsed?.isEdited == true)
        #expect(best(search.result) == Set(Self.hero.items(.nakheel).map(\.id)))

        search.apply([.add(.media(.videos))])
        await search.settled()
        #expect(search.text == "Al-Nakheel Park videos")
        #expect(best(search.result) == Set(Self.hero.items(.nakheel).filter(\.isVideo).map(\.id)))
    }

    @Test func anIndexChangeRunsTheSearchAgainKeepingItsCards() async throws {
        let (_, search) = await stores()
        search.submit("Greece")
        await search.settled()
        let first = try #require(search.result)
        search.indexChanged()
        await search.settled()
        let second = try #require(search.result)
        #expect(second.id != first.id)
        #expect(second.cards.map(\.id) == first.cards.map(\.id))
        #expect(search.examples.map(\.text).first == "Dubai trip")
    }

    @Test func aNewSearchSupersedesAPendingReRun() async throws {
        let (_, search) = await stores()
        search.submit("Greece")
        await search.settled()
        search.indexChanged()
        search.submit("Salam Park")
        await search.settled()
        #expect(search.request?.text == "Salam Park")
        #expect(search.result?.query.parsed.text == "Salam Park", "the re-run of “Greece” doesn't come back")
        // A later change re-runs the search on screen, not the one the change interrupted.
        search.indexChanged()
        await search.settled()
        #expect(search.result?.query.parsed.text == "Salam Park")
    }

    @Test func aSearchThatHadNoIndexRunsOnceThereIsOne() async throws {
        let (index, search) = await stores(start: false)
        search.submit("Greece")
        #expect(search.state == .failed(SearchStore.unavailableMessage))
        index.start()
        await index.placeNamesSettled()
        search.indexChanged()
        await search.settled()
        guard case .results(let result) = search.state else { Issue.record("state \(search.state)"); return }
        #expect(result.totals.moments > 0)
    }

    /// Chip edits: the text is rendered from the edited slots and the search runs again (acceptance 1 through the store).
    @Test func chipEditsRenderTheTextAndSearchAgain() async throws {
        let (_, search) = await stores()
        search.submit("Al-Nakheel Park last summer")
        await search.settled()
        let time = try #require(search.result?.query.slots.first { $0.slot.kind == .time })
        search.apply([.replaceTime(slot: time.id, try #require(time.timePresets.first?.expression))])
        #expect(search.state == .searching, "an edit searches at once")
        await search.settled()
        #expect(search.text == "Al-Nakheel Park summer 2025")
        #expect(best(search.result) == Set(Self.hero.items(.nakheel).filter { $0.momentDay == LocalTime.day(year: 2025, month: 6, day: 14) }.map(\.id)))
        search.apply([.remove(slot: time.id)])
        await search.settled()
        #expect(search.text == "Al-Nakheel Park")
        #expect(best(search.result) == Set(Self.hero.items(.nakheel).map(\.id)))

        // Removing the last chip goes back to the start.
        let place = try #require(search.result?.query.slots.first)
        search.apply([.remove(slot: place.id)])
        #expect(search.state == .idle && search.text.isEmpty && search.result == nil)
    }

    /// A place picked in the place editor is remembered for the words typed, like the picker's.
    @Test func aPlaceEditorPickIsRemembered() async throws {
        let (index, search) = await stores()
        search.submit("Salam Park")
        await search.settled()
        let place = try #require(search.result?.query.slots.first { $0.slot.kind == .place })
        guard case .place(let resolution) = place.resolution, let dubai = resolution.candidates.first(where: { $0.context == "Dubai" }) else {
            Issue.record("no Dubai candidate")
            return
        }
        search.choose(dubai, forSlot: place.id)
        await search.settled()
        #expect(search.result?.query.picker?.chosen == dubai.id, "the picker row ticks the editor's choice")
        for _ in 0..<50 where try await index.reader?.placeChoice(for: "salam park") == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await index.reader?.placeChoice(for: "salam park")?.placeKey == dubai.id)
    }

    /// The scope is read at every search; an unlock runs the shown search again at once and recounts the examples.
    @Test func anUnlockRunsTheShownSearchAgain() async throws {
        final class Box { var scope = SearchScope.since(Date(timeIntervalSince1970: 1_761_642_000)) }
        let box = Box()
        let (_, search) = await stores(scope: { box.scope })
        search.refreshExamples(after: .zero)
        search.submit("Greece")
        await search.settled()
        #expect(search.request?.scope == box.scope)
        guard case .noMatch(let free) = search.state else { Issue.record("state \(search.state)"); return }
        #expect(free.noMatch?.kind == .onlyEarlier && free.lockedCount == Self.hero.items(.greece).count)
        #expect(!search.examples.isEmpty && !search.examples.map(\.text).contains("Dubai trip"))

        box.scope = .wholeLibrary
        search.scopeChanged()
        #expect(search.state == .noMatch(free), "the result stays on screen while it runs again")
        await search.settled()
        guard case .results(let unlocked) = search.state else { Issue.record("state \(search.state)"); return }
        #expect(unlocked.lockedCount == 0)
        #expect(best(unlocked) == Set(Self.hero.items(.greece).filter(\.isLocated).map(\.id)))
        #expect(search.examples.first?.text == "Dubai trip")
    }

    @Test func theLayoutIsRemembered() async {
        let kv = InMemoryKeyValueStore()
        let (index, search) = await stores(kv: kv, start: false)
        #expect(search.layout == .moments)
        search.setLayout(.grid)
        #expect(SearchStore(engine: nil, index: index, kv: kv, clock: SystemClock()).layout == .grid)
        // A starting layout (-LZResultsLayout) wins over the remembered one and isn't remembered.
        #expect(SearchStore(engine: nil, index: index, kv: kv, clock: SystemClock(), initialLayout: .moments).layout == .moments)
        #expect(SearchStore(engine: nil, index: index, kv: kv, clock: SystemClock()).layout == .grid)
    }

    @Test func withoutAnIndexSearchSaysSo() async {
        let (_, search) = await stores(start: false)
        search.submit("Greece")
        #expect(search.state == .failed(SearchStore.unavailableMessage))
    }
}
