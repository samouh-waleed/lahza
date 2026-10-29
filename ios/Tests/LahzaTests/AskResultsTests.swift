import Foundation
import LZCore
import LZGeo
import LZIndex
import LZLibrary
import LZSearch
import Testing
@testable import Lahza

/// Ask's results over the fake hero library (search spec §7.1, §9.2): the chips, the rows of sections, trips and
/// cards, the no-match taps, the only-unsupported answer, the picker, Show weaker, the partial-build header and a
/// moment opened from a search.
@MainActor @Suite struct AskResultsTests {
    private let riyadh = TimeZone(identifier: "Asia/Riyadh")!

    private func cardCount(_ rows: [ResultRow]) -> Int {
        rows.count { if case .card = $0 { true } else { false } }
    }

    @Test func askSpeaksInThePresentTense() {
        #expect(AskCopy.capability == "Searches places, dates and photo types. Searching what’s in photos comes later.")
        #expect(AskCopy.subtitle == "Search by place, date or photo type, like “Dubai last December” or “videos from Eid”.")
        #expect(AskCopy.indexingCaption(.reading(done: 1, total: 2)) == "You can search now. Newest photos come first; trips appear when Lahza finishes.")
        #expect(AskCopy.indexingCaption(.organizing).hasPrefix("You can search now."))
        #expect(AskCopy.momentsNoun(1) == "moment" && AskCopy.momentsNoun(16) == "moments")
        #expect(AskCopy.showWeaker(1) == "Show 1 weaker match" && AskCopy.showWeaker(12) == "Show 12 weaker matches")
        #expect(AskCopy.notYet("soccer", kind: .visual) == "soccer · not yet")
        #expect(AskCopy.notYet("National day of which country?", kind: .time) == "National day of which country?", "a date keeps its own words")
        #expect(AskCopy.capitalized("last summer") == "Last summer")
    }

    @Test func chipsSayWhatWasUnderstoodAndWhatWasLeftOut() async throws {
        let app = await SearchTestApp.ready()
        let result = try #require(await SearchTestApp.search(app, "soccer at Al-Nakheel Park"))
        let chips = QueryChipModel.chips(result.query)
        #expect(chips.map(\.title) == ["soccer · not yet", "Al-Nakheel Park"])
        #expect(chips.map(\.isSupported) == [false, true])
        #expect(chips.map(\.accessibilityLabel) == ["soccer, not searchable yet", "Place, Al-Nakheel Park"])
        #expect(result.unsupportedNotice == "Lahza can’t see what’s in photos yet, so “soccer” was left out. Showing all your photos at Al-Nakheel Park.")
        #expect(SearchTestApp.bestCount(app) == SeedScenario.hero.items(.nakheel).count)

        // Typed but not searched: the chips come from the words, and the place spins while it is looked up.
        app.search.clear()
        app.search.preview("videos at Al-Nakheel Park")
        #expect(await SearchTestApp.eventually(app) { app.search.parsed != nil })
        let typed = QueryChipModel.chips(try #require(app.search.parsed), lookingUpPlace: true)
        #expect(typed.map(\.title) == ["Videos", "Al-Nakheel Park"])
        #expect(typed.map(\.systemImage) == ["film", "mappin"])
        #expect(typed.map(\.isLoading) == [false, true])
    }

    @Test func resultsListSectionsThenTripsThenCards() async throws {
        let app = await SearchTestApp.ready()
        let greece = try #require(await SearchTestApp.search(app, "Greece"))
        let rows = ResultRow.rows(greece.sections, showsUnknown: false)
        #expect(Set(rows.map(\.id)).count == rows.count, "row ids are unique")
        guard case .section(let best)? = rows.first, case .trip(let trip, let tier) = rows[1] else {
            Issue.record("expected the Best section, then the Greece trip")
            return
        }
        #expect(best.tier == .best && best.title == "Matches")
        #expect(tier == .best && trip.trip.label == "Greece")
        #expect(trip.title == MomentCopy.tripTitle(trip.trip), "the trip header's dates follow the iPhone like the Moments tab")
        #expect(cardCount(rows) == greece.cards.count)

        // Location unknown lists its cards only when opened.
        let riyadh2025 = try #require(await SearchTestApp.search(app, "Riyadh 2025"))
        let unknown = try #require(riyadh2025.sections.first { $0.tier == .locationUnknown })
        let unknownCards = unknown.groups.flatMap(\.cards).count
        #expect(unknownCards > 0)
        #expect(cardCount(ResultRow.rows(riyadh2025.sections, showsUnknown: false)) == riyadh2025.cards.count - unknownCards)
        #expect(cardCount(ResultRow.rows(riyadh2025.sections, showsUnknown: true)) == riyadh2025.cards.count)
    }

    @Test func cardsNameTheDayThePlaceAndWhy() async throws {
        let app = await SearchTestApp.ready()
        let result = try #require(await SearchTestApp.search(app, "Al-Nakheel Park"))
        let card = try #require(result.cards.first)
        let today = MomentCopy.today(now: HeroSuite.now, zone: riyadh)
        #expect(today == LocalTime.day(year: 2026, month: 10, day: 28))
        #expect(card.id.day == LocalTime.day(year: 2026, month: 8, day: 22), "the newest session first")
        #expect(AskCopy.cardTitle(card, today: today) == MomentCopy.shortDay(card.id.day), "this year's day has no year")
        let line = try #require(AskCopy.cardPlaceAndTime(card, homeCountry: "SA", deviceZone: riyadh))
        #expect(line.hasPrefix("Al-Nakheel Park · Riyadh · "))
        #expect(!line.hasSuffix(" time"), "no zone note in this iPhone's zone")
        #expect(card.reasons.first?.text == "In Al-Nakheel Park")
        #expect(AskCopy.tone(card.reasons[0]) == .sage)
        let spoken = AskCopy.spokenCard(card, today: today, homeCountry: "SA", deviceZone: riyadh)
        #expect(spoken.hasPrefix("\(MomentCopy.spokenDay(card.id.day)), Al-Nakheel Park · Riyadh"))
        #expect(spoken.hasSuffix(([MomentCopy.counts(photos: card.photoCount, videos: card.videoCount)] + card.reasons.map(\.text)).joined(separator: ", ")))
        #expect(MomentCardView.tileIDs(card).count == min(MomentCardView.tiles, card.hits.count))

        app.search.refreshExamples(after: .zero)
        #expect(await SearchTestApp.eventually(app) { !app.search.examples.isEmpty })
        #expect(app.search.examples.map(AskCopy.example).contains("Al-Nakheel Park · \(SeedScenario.hero.items(.nakheel).count)"))
    }

    @Test func noMatchNamesTheSlotAndWidensWithATap() async throws {
        let app = await SearchTestApp.ready()
        let result = try #require(await SearchTestApp.search(app, "Dubai last December"))
        let noMatch = try #require(result.noMatch)
        #expect(noMatch.kind == .combination)
        #expect(noMatch.headline == "57 in Dubai, none in December 2025.")
        let anyTime = try #require(noMatch.offers.first)
        #expect(AskCopy.offer(anyTime) == "Dubai, any time · 57")
        #expect(AskCopy.spokenOffer(anyTime) == "Dubai, any time, 57 results")
        app.search.widen(anyTime)
        #expect(await SearchTestApp.eventually(app) { if case .results = app.search.state { true } else { false } })
        #expect(app.search.text == "Dubai")

        let paris = try #require(await SearchTestApp.search(app, "Paris"))
        #expect(paris.noMatch?.kind == .placeEmpty)
        #expect(paris.noMatch?.headline == "No photos in Paris, France.")
        #expect(AskCopy.noMatchSymbol(.placeEmpty) == "mappin.slash")
        #expect((paris.noMatch?.offers.count ?? 0) >= 5, "a chip per country")
    }

    @Test func onlyUnsupportedWordsGetTheLibrarysExamples() async throws {
        let maps = SeedMaps.client()
        let app = await SearchTestApp.ready(maps: maps)
        func searches() -> Int { maps.calls.count { if case .search = $0 { true } else { false } } }
        let before = searches()
        let result = try #require(await SearchTestApp.search(app, "sunset"))
        #expect(result.noMatch?.kind == .onlyUnsupported)
        #expect(result.noMatch?.headline == "Lahza can’t search what’s in photos yet. Try a place, a date or a photo type.")
        #expect(result.noMatch?.examples.isEmpty == false)
        #expect(result.unsupportedNotice == nil)
        #expect(QueryChipModel.chips(result.query).map(\.title) == ["sunset · not yet"])
        #expect(searches() == before, "no Apple Maps search")
    }

    @Test func thePickerSearchesTheOtherPlace() async throws {
        let app = await SearchTestApp.ready()
        let result = try #require(await SearchTestApp.search(app, "Salam Park"))
        let salam = SeedScenario.hero.items(.salam).count
        let salamDubai = SeedScenario.hero.items(.dubai1).count { $0.title == SeedPlace.salamParkDubai.name && $0.isLocated }
        let picker = try #require(result.query.picker)
        #expect(picker.question == "Which Salam Park?")
        #expect(picker.choices.map(\.label) == ["Riyadh · \(salam)", "Dubai · \(salamDubai)"])
        #expect(SearchTestApp.bestCount(app) == salam)
        let dubai = try #require(picker.choices.last)
        #expect(AskCopy.spokenChoice(dubai.label) == "Dubai, \(salamDubai) photos")
        app.search.choose(dubai)
        #expect(await SearchTestApp.eventually(app) { app.search.result?.id != result.id && app.search.result?.noMatch == nil })
        #expect(SearchTestApp.bestCount(app) == salamDubai)
    }

    @Test func showWeakerAddsAndRemovesTheWeakerSection() async throws {
        let app = await SearchTestApp.ready()
        var found: SearchResult?
        for query in ["al nakheel park 2025", "Al-Nakheel Park last summer", "near Kingdom Centre", "Ramadan 2024", "Riyadh 2025"] {
            if let result = await SearchTestApp.search(app, query), result.weakerCount > 0 {
                found = result
                break
            }
        }
        let result = try #require(found, "a hero query with weaker matches")
        #expect(!result.sections.contains { $0.tier == .weaker })
        app.search.setShowWeaker(true)
        #expect(await SearchTestApp.eventually(app) { app.search.result?.sections.contains { $0.tier == .weaker } == true })
        #expect(app.search.request?.showWeaker == true)
        app.search.setShowWeaker(false)
        #expect(await SearchTestApp.eventually(app) { app.search.result?.sections.contains { $0.tier == .weaker } == false })
    }

    @Test func aSearchDuringTheFirstBuildSaysHowFarItHasRead() async throws {
        var dependencies = SearchTestApp.dependencies()
        dependencies.indexSettings.batchSize = 50
        dependencies.indexSettings.pacePerBatch = .milliseconds(400)
        let app = AppModel(dependencies: dependencies)
        // Polls without waiting for the index to settle (that would wait for the build to finish).
        func poll(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
            return condition()
        }
        app.start()
        #expect(await poll {
            guard case .reading(let done, _) = app.index.status.phase else { return false }
            return done >= 50 && app.index.status.isPartial && app.index.reader != nil
        })
        app.search.submit("Al-Nakheel Park")
        #expect(await poll { app.search.result != nil })
        let result = try #require(app.search.result)
        #expect(result.coverage.isPartial)
        #expect(result.coverage.header?.hasPrefix("Searched your photos since ") == true)
        #expect(result.coverage.caption.hasSuffix(" so far"))
    }

    @Test func aMomentOpenedFromASearchShowsItsMatchesFirst() async throws {
        let app = await SearchTestApp.ready()
        let result = try #require(await SearchTestApp.search(app, "videos at Al-Nakheel Park"))
        let card = try #require(result.cards.first)
        let detail = try #require(await app.moments.moment(card.id))
        let split = MomentMatches(members: detail.members, card: card)
        #expect(Set(split.matches.map(\.id)) == Set(card.hits.map(\.id)))
        #expect(split.matches.allSatisfy { $0.isVideo })
        #expect(split.others.count == detail.members.count - card.hits.count)
        #expect(MomentCopy.matchesTitle(split.matches.count) == "Matches · \(split.matches.count)")
        #expect(MomentCopy.alsoTitle(split.others.count) == "Also in this moment · \(split.others.count)")
    }
}
