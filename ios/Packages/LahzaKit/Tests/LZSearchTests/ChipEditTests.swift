import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// Chip editing (search spec §6.2, §7.1, PR 4): the time editor's presets and part of the day, edits that re-render the
/// text and search again on the hero library, the place editor's radius, "near", Apple Maps on request and the other
/// places a picked one may be.
@Suite struct ChipEditTests {
    static let hero = SeedScenario.hero

    // MARK: Time presets

    private func labels(_ text: String, _ resolver: TimeResolver = SearchFixture.saudi()) throws -> [String] {
        guard case .time(let time) = try #require(SearchFixture.parse(text).slots.first).value else {
            Issue.record("“\(text)” has no date")
            return []
        }
        return resolver.presets(for: time).map(\.label)
    }

    @Test func presetsFollowTheSpec() throws {
        #expect(try labels("last summer") == ["Summer 2025", "Every summer", "Any time"])
        #expect(try labels("Ramadan 2025") == ["Ramadan 2024", "Ramadan 2026", "Every Ramadan"], "a later Ramadan once it has begun")
        #expect(try labels("3 years ago") == ["On this day in 2023", "2 years ago"])
        #expect(try labels("last Saturday") == ["Every Saturday"])
        #expect(try labels("Saturday") == ["Last Saturday"])
        #expect(try labels("summer") == ["Last summer", "Any time"])
        #expect(try labels("last December") == ["December 2024", "Every December", "Any time"])
        #expect(try labels("June 2025") == ["June 2024", "June 2026", "Every June", "Any time"])
        #expect(try labels("2024") == ["2023", "2025"])
        #expect(try labels("Ramadan 1445") == ["Ramadan 1444", "Every Ramadan"])
        #expect(try labels("Ramadan") == ["Last Ramadan"])
        #expect(try labels("3 years ago today") == ["All of 2023", "2 years ago today"])
        #expect(try labels("yesterday") == ["Today"])
        #expect(try labels("last month") == ["This month"])
        #expect(try labels("14 June 2025") == ["June 2025"])
        #expect(try labels("between March and May 2024").isEmpty, "custom dates edit a range")
        // In the south "last summer" is the one that ended in February.
        #expect(try labels("last summer", SearchFixture.sydneyHome()) == ["Summer 2025", "Every summer", "Any time"])
    }

    @Test func aPresetKeepsThePartOfTheDay() throws {
        let resolver = SearchFixture.saudi()
        let presets = resolver.presets(for: .all([.weekday(7, .every), .partOfDay(.evening)]))
        #expect(presets.map(\.label) == ["Last Saturday"])
        #expect(presets.first?.expression == .all([.weekday(7, .last), .partOfDay(.evening)]))
        #expect(resolver.presets(for: .season(.summer, .last)).last?.expression == nil, "Any time removes the dates")
        #expect(resolver.presets(for: .all([.weekday(7, .every), .partOfDay(.evening), .month(7, .year(2023))])).isEmpty)
    }

    /// Every preset renders text that reads back as the same dates.
    @Test func presetPhrasesParseBack() {
        let resolver = SearchFixture.saudi()
        for expression in QueryModelTests.producibleExpressions() {
            for case let preset? in resolver.presets(for: expression).map(\.expression) {
                let phrase = preset.phrase(locale: SearchFixture.uk)
                #expect(SearchFixture.parse(phrase).values == [.time(preset)], "\(expression) → \(phrase)")
            }
        }
    }

    /// "Any time" removes the dates and keeps the part of the day ("last summer at night" → "at night").
    @Test func anyTimeKeepsThePartOfTheDay() throws {
        guard case .time(let night) = try #require(SearchFixture.parse("last summer at night").slots.first).value else {
            Issue.record("no date")
            return
        }
        #expect(night == .all([.season(.summer, .last), .partOfDay(.night)]))
        let presets = SearchFixture.saudi().presets(for: night)
        #expect(presets.map(\.label) == ["Summer 2025", "Every summer", "Any time"])
        #expect(presets.first?.expression == .all([.season(.summer, .year(2025)), .partOfDay(.night)]))
        #expect(presets.last?.expression == .partOfDay(.night))
    }

    @Test func thePartOfTheDayIsReadAndReplaced() {
        let evening = TimeExpression.all([.weekday(7, .every), .partOfDay(.evening)])
        #expect(evening.partOfDay == .evening)
        #expect(evening.with(partOfDay: .morning) == .all([.weekday(7, .every), .partOfDay(.morning)]))
        #expect(evening.with(partOfDay: nil) == .weekday(7, .every))
        #expect(TimeExpression.season(.summer, .last).with(partOfDay: .night) == .all([.season(.summer, .last), .partOfDay(.night)]))
        #expect(TimeExpression.partOfDay(.night).with(partOfDay: nil) == nil, "nothing left: the dates go")
        #expect(TimeExpression.year(2024).partOfDay == nil)
    }

    @Test func customDatesStartFromTheChipsDays() throws {
        let constraint = try #require(SearchFixture.saudi().resolve(.season(.summer, .last)).constraint)
        #expect(constraint.days == LocalTime.day(year: 2026, month: 6, day: 1)...LocalTime.day(year: 2026, month: 8, day: 31))
        #expect(SearchFixture.saudi().resolve(.weekday(7, .every)).constraint?.days == nil, "recurring dates have no range")
        let custom = TimeExpression.range(from: .date(day: 1, month: 6, year: 2025), to: .date(day: 30, month: 6, year: 2025))
        #expect(SearchFixture.saudi().resolve(custom).constraint?.days == LocalTime.day(year: 2025, month: 6, day: 1)...LocalTime.day(year: 2025, month: 6, day: 30))
    }

    // MARK: Edits on the hero library

    /// The request after `edits`, as the store makes it.
    private func edited(_ result: SearchResult, _ edits: [SlotEdit], overrides: ResolutionOverrides = ResolutionOverrides()) -> SearchRequest {
        let query = result.query.parsed.applying(edits, locale: SearchFixture.uk)
        var overrides = overrides
        overrides.apply(edits, to: result.query.parsed)
        return SearchRequest(text: query.text, parsed: query, overrides: overrides)
    }

    /// Edits one after another render the same words: "near" and "with" are never doubled, Near off leaves no "near",
    /// a typed preposition and article stay, and the text reads back as the same slots.
    @Test func chainedEditsKeepTheWordsAsTyped() throws {
        let vocabulary = ParserTableTests.knownVocabulary
        func apply(_ query: ParsedQuery, _ edits: [SlotEdit]) -> ParsedQuery {
            let edited = query.applying(edits, locale: SearchFixture.uk)
            #expect(SearchFixture.parse(edited.text, vocabulary).values == edited.values, "“\(edited.text)” reads back")
            return edited
        }

        let centre = SearchFixture.parse("near Kingdom Centre", vocabulary)
        let slot = try #require(centre.slots.first).id
        let tight = apply(centre, [.setRadius(slot: slot, metres: 100)])
        let wide = apply(tight, [.setRadius(slot: slot, metres: 800)])
        #expect([tight.text, wide.text] == ["near Kingdom Centre", "near Kingdom Centre"])
        #expect(wide.spanTexts == ["Kingdom Centre"], "the span is the name, as the parser's")

        let park = SearchFixture.parse("soccer videos at Al-Nakheel Park last summer", vocabulary)
        let place = try #require(park.slots.first { $0.kind == .place }).id
        let media = try #require(park.slots.first { $0.kind == .media }).id
        let photos = apply(park, [.replaceMedia(slot: media, .photos)])
        #expect(photos.text == "soccer only photos at Al-Nakheel Park last summer")
        let near = apply(photos, [.setNear(slot: place, true)])
        #expect(near.text == "soccer only photos near Al-Nakheel Park last summer")
        let again = apply(near, [.remove(slot: 0)])
        #expect(again.text == "only photos near Al-Nakheel Park last summer")
        let notNear = apply(again, [.setNear(slot: place, false)])
        #expect(notNear.text == "only photos Al-Nakheel Park last summer")

        let beach = SearchFixture.parse("with Ahmed at the beach", vocabulary)
        let shore = try #require(beach.slots.first { $0.kind == .place }).id
        let nearBeach = apply(beach, [.setNear(slot: shore, true)])
        #expect(nearBeach.text == "with Ahmed near the beach")
        #expect(apply(nearBeach, [.add(.media(.videos))]).text == "with Ahmed near the beach videos")

        // A pick keeps the preposition, and the words typed for the slot.
        let salam = SearchFixture.parse("soccer at Salam Park", vocabulary)
        let salamSlot = try #require(salam.slots.first { $0.kind == .place }).id
        let pick = SlotEdit.replacePlace(slot: salamSlot, placeKey: "mk:seed.salam-park-dubai", name: "Salam Park")
        #expect(salam.applying([pick]).text == "soccer at Salam Park")
        var overrides = ResolutionOverrides()
        overrides.apply([pick], to: salam)
        let picked = salam.applying([pick])
        overrides.apply([.replacePlace(slot: salamSlot, placeKey: "mk:seed.salam-park", name: "Salam Park, Riyadh")], to: picked)
        #expect(overrides.places[salamSlot]?.typedWords == "Salam Park", "the first pick's words stay")
        #expect(overrides.places[salamSlot]?.placeKey == "mk:seed.salam-park")
    }

    private func slot(_ result: SearchResult, _ kind: SlotKind) throws -> ResolvedSlot {
        try #require(result.query.slots.first { $0.slot.kind == kind })
    }

    /// Acceptance 1: on #4, removing the dates shows #1; Summer 2025 shows the 14 Jun 2025 session; the text follows.
    @Test func editsOnTheParkLastSummer() async throws {
        let search = try await HeroSearch.shared.value
        let nakheel = Self.hero.items(.nakheel)
        let lastSummer = try await search.search("Al-Nakheel Park last summer")
        let time = try slot(lastSummer, .time)
        #expect(time.timePresets.map(\.label) == ["Summer 2025", "Every summer", "Any time"])

        let removed = edited(lastSummer, [.remove(slot: time.id)])
        #expect(removed.text == "Al-Nakheel Park")
        let anyTime = try await search.search(removed)
        #expect(Set(anyTime.items(.best).map(\.number)) == Set(nakheel.map(\.number)))

        let summer2025 = try #require(time.timePresets.first?.expression)
        let changed = edited(lastSummer, [.replaceTime(slot: time.id, summer2025)])
        #expect(changed.text == "Al-Nakheel Park summer 2025")
        let june = try await search.search(changed)
        let session = nakheel.filter { $0.momentDay == LocalTime.day(year: 2025, month: 6, day: 14) }
        #expect(!session.isEmpty)
        #expect(Set(june.items(.best).map(\.number)) == Set(session.map(\.number)))
        #expect(try slot(june, .time).chip.hasPrefix("Summer 2025"))
    }

    @Test func thePartOfTheDayAndMediaEditsSearchAgain() async throws {
        let search = try await HeroSearch.shared.value
        let park = try await search.search("videos at Al-Nakheel Park")
        let media = try slot(park, .media)
        let photos = edited(park, [.replaceMedia(slot: media.id, .photos)])
        #expect(photos.text == "only photos at Al-Nakheel Park")
        let result = try await search.search(photos)
        #expect(Set(result.items(.best).map(\.number)) == Set(Self.hero.items(.nakheel).filter { !$0.isVideo }.map(\.number)))

        let evening = edited(park, [.remove(slot: media.id), .add(.time(.all([.weekday(7, .every), .partOfDay(.evening)])))])
        #expect(evening.text == "at Al-Nakheel Park every Saturday evening")
        #expect(try await search.search(evening).totals.items > 0)
    }

    @Test func thePlaceEditorsRadiusAndNear() async throws {
        let search = try await HeroSearch.shared.value
        let park = try await search.search("Al-Nakheel Park")
        let place = try slot(park, .place)
        let radius = try #require(place.radius)
        #expect(radius == PlaceRadius(natural: 400))
        #expect(radius.choice == .normal && radius.metres(.tight) == 200 && radius.metres(.wide) == 800)

        let tight = try await search.search(edited(park, [.setRadius(slot: place.id, metres: radius.metres(.tight))]))
        #expect(try slot(tight, .place).radius == PlaceRadius(natural: 400, chosen: 200))
        #expect(try slot(tight, .place).radius?.choice == .tight)

        let near = try await search.search(edited(park, [.setNear(slot: place.id, true)]))
        #expect(near.query.parsed.text == "near Al-Nakheel Park")
        #expect(try slot(near, .place).chip == "Near Al-Nakheel Park")
        #expect(try slot(near, .place).radius == PlaceRadius(natural: 400, near: true))

        // A "Widen to 2 km" tap is none of the three.
        #expect(PlaceRadius(natural: 400, chosen: 2_000).choice == nil)
        // Countries have no radius.
        #expect(try slot(try await search.search("Greece"), .place).radius == nil)
    }

    /// "Search Apple Maps for “X”": one search even when the library has the place, its places become candidates, and a
    /// later edit reads the cached answer.
    @Test func appleMapsOnRequest() async throws {
        let search = try await HeroSearch()
        let park = try await search.search("Al-Nakheel Park")
        #expect(search.mapsSearches == 0 && !park.query.searchedAppleMaps)
        let place = try slot(park, .place)
        let request = edited(park, [.searchAppleMaps(slot: place.id)])
        #expect(request.overrides.places[place.id]?.searchesAppleMaps == true)
        #expect(request.parsed?.slots.map(\.value) == park.query.parsed.slots.map(\.value), "the slots stay")
        let looked = try await search.search(request)
        #expect(search.mapsSearches == 1 && looked.query.searchedAppleMaps)
        guard case .place(let resolution) = try slot(looked, .place).resolution else { Issue.record("no place"); return }
        #expect(resolution.chosen?.name == "Al-Nakheel Park" && resolution.chosen?.photoCount == Self.hero.items(.nakheel).count)
        #expect(resolution.candidates.contains { $0.subtitle == "Park · Dammam" }, "Apple Maps' other park is offered")

        var again = request
        again.overrides.places[place.id]?.radius = 200
        _ = try await search.search(again)
        #expect(search.mapsSearches == 1, "the answer is cached")
    }

    /// After "Search Apple Maps for “Salam Park”", picking a place Apple Maps named otherwise never asks Apple Maps
    /// about that name: the editor lists what the typed words may mean from the cached answer.
    @Test func aPickAfterAskingAppleMapsAsksNothingMore() async throws {
        var table = SeedMaps.hero
        let garden = MapPlace(appleID: "test.salam-garden", name: "Salam Garden", category: .park, coordinate: Coordinate(latitude: 21.54, longitude: 39.17),
                              cityName: "Jeddah", countryCode: "SA")
        table.searches["salam park", default: []].append(garden)
        let search = try await HeroSearch(table: table)
        let salam = try await search.search("Salam Park")
        let place = try slot(salam, .place)
        let asked = edited(salam, [.searchAppleMaps(slot: place.id)])
        let looked = try await search.search(asked)
        #expect(search.mapsSearches == 1)
        guard case .place(let resolution) = try slot(looked, .place).resolution,
              let candidate = resolution.candidates.first(where: { $0.name == "Salam Garden" }) else { Issue.record("no Salam Garden"); return }

        var request = edited(looked, [.replacePlace(slot: place.id, placeKey: candidate.id, name: candidate.name)], overrides: asked.overrides)
        #expect(request.overrides.places[place.id]?.typedWords == "Salam Park")
        let picked = try await search.search(request)
        #expect(search.mapsSearches == 1, "“Salam Garden” isn't sent")
        guard case .place(let after) = try slot(picked, .place).resolution else { Issue.record("no place"); return }
        #expect(after.chosen?.name == "Salam Garden")
        #expect(after.candidates.filter { $0.name == "Salam Park" }.count == 2, "both parks are still listed")

        request.overrides.places[place.id]?.radius = 1_000
        _ = try await search.search(request)
        #expect(search.mapsSearches == 1)
    }

    /// Offline, the Apple Maps search asked for isn't made, and the result says why (the editor keeps its row).
    @Test func anAppleMapsSearchAskedForOfflineSaysWhy() async throws {
        let search = try await HeroSearch(reachable: false)
        let park = try await search.search("Al-Nakheel Park")
        #expect(park.query.appleMapsMissed == nil)
        let looked = try await search.search(edited(park, [.searchAppleMaps(slot: try slot(park, .place).id)]))
        #expect(search.mapsSearches == 0 && !looked.query.searchedAppleMaps)
        #expect(looked.query.appleMapsMissed == .offline)
        #expect(looked.totals.items == park.totals.items, "the library's park is still searched")
    }

    /// The place editor lists the other places a picked one's words may mean.
    @Test func aPickedPlaceKeepsItsAlternatives() async throws {
        let search = try await HeroSearch()
        let salam = try await search.search("Salam Park")
        let picker = try #require(salam.query.picker)
        let dubai = try #require(picker.choices.first { $0.candidate.context == "Dubai" })
        let picked = try await search.search(edited(salam, [.replacePlace(slot: picker.slot, placeKey: dubai.id, name: dubai.candidate.name)]))
        guard case .place(let resolution) = try slot(picked, .place).resolution else { Issue.record("no place"); return }
        #expect(resolution.chosen?.id == dubai.id)
        #expect(resolution.candidates.map(\.id).contains("mk:seed.salam-park"))
        #expect(search.mapsSearches == 0)
    }
}
