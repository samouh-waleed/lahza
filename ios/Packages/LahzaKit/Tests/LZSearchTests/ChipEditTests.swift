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

    private func edited(_ result: SearchResult, _ edits: [SlotEdit], overrides: ResolutionOverrides = ResolutionOverrides()) -> SearchRequest {
        let query = result.query.parsed.applying(edits, locale: SearchFixture.uk)
        var overrides = overrides
        for edit in edits { overrides.apply(edit) }
        return SearchRequest(text: query.text, parsed: query, overrides: overrides)
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
        #expect(photos.text == "only photos Al-Nakheel Park")
        let result = try await search.search(photos)
        #expect(Set(result.items(.best).map(\.number)) == Set(Self.hero.items(.nakheel).filter { !$0.isVideo }.map(\.number)))

        let evening = edited(park, [.remove(slot: media.id), .add(.time(.all([.weekday(7, .every), .partOfDay(.evening)])))])
        #expect(evening.text == "Al-Nakheel Park every Saturday evening")
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
