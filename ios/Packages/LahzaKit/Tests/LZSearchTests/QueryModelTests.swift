import Foundation
import LZGeo
import Testing
@testable import LZSearch

/// The query model: spans in UTF-16, unsupported slots, the Codable contract, phrases that parse back, and edits.
@Suite struct QueryModelTests {
    @Test func spansCoverTheWordsInUTF16() {
        let cases: [(String, [String])] = [
            ("videos at Al-Nakheel Park last summer", ["videos", "Al-Nakheel Park", "last summer"]),
            ("in June", ["June"]),
            ("Saturday evening in July 2023", ["Saturday evening in July 2023"]),
            ("between March and May 2024", ["between March and May 2024"]),
            ("the Greece trip", ["Greece", "trip"]),
            ("sunset in Santorini", ["sunset", "Santorini"]),
            ("with Ahmed", ["Ahmed"]),
            ("at the beach", ["beach"]),
            ("3 years ago today", ["3 years ago today"]),
            ("New Year's Eve 2021", ["New Year's Eve 2021"]),
            ("Dubai or Abu Dhabi", ["Dubai or Abu Dhabi"]),
            // Emoji and Arabic before the words move the UTF-16 offsets.
            ("📸 soccer at Al-Nakheel Park", ["soccer", "Al-Nakheel Park"]),
            ("الرياض videos", ["الرياض", "videos"]),
            ("Café de Flore", ["Café de Flore"]),
        ]
        for (text, spans) in cases {
            let query = SearchFixture.parse(text)
            #expect(query.spanTexts == spans, "\(text)")
            for slot in query.slots {
                let span = try? #require(slot.span)
                #expect(span.map { $0.end <= text.utf16.count } == true)
            }
        }
        let emoji = SearchFixture.parse("📸 soccer")
        #expect(emoji.slots.first?.span == TextSpan(location: 3, length: 6), "📸 is two UTF-16 units, then a space")
    }

    /// Any mix of words parses, with spans inside the text, in order and never overlapping.
    @Test func randomQueriesKeepSpansValid() {
        let words = ["in", "at", "near", "the", "a", "last", "this", "every", "between", "and", "or", "since", "before", "from", "to", "on",
                     "Saturday", "sat", "evening", "night", "late", "June", "may", "14th", "2024", "2031", "1445", "'23", "3", "a", "few", "years",
                     "ago", "today", "Ramadan", "Eid", "al", "Fitr", "new", "year's", "eve", "videos", "only", "photos", "selfies", "screen",
                     "shot", "Riyadh", "Dubai", "Al-Nakheel", "Park", "Santorini", "home", "my", "pitch", "beach", "trip", "with", "Ahmed", "me",
                     "soccer", "sunset", "café", ",", "-", "/", "📸", "الرياض", "Ad", "Dir'iyah", "2/3/2024", "2024-03-02", "of", "summer", "fall"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let text = (0..<Int.random(in: 1...9, using: &generator)).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
            let query = SearchFixture.parse(text, ParserTableTests.knownVocabulary)
            #expect(query.slots.map(\.id) == Array(0..<query.slots.count), "\(text)")
            var end = 0
            for slot in query.slots {
                guard let span = slot.span else { Issue.record("no span in “\(text)”"); continue }
                #expect(span.location >= end && span.length > 0 && span.substring(of: text) != nil, "\(text)")
                end = span.end
            }
        }
    }

    @Test func unsupportedSlotsAreKeptAndListed() {
        let query = SearchFixture.parse("soccer at Al-Nakheel Park with Ahmed")
        #expect(query.unsupported().map(\.value) == [.visual("soccer"), .people("Ahmed")])
        #expect(query.supported().map(\.kind) == [.place])
        #expect(query.unsupported(SearchCapabilities(visual: true, people: true)).isEmpty)
    }

    @Test func mediaSlotsMerge() {
        #expect(SearchFixture.parse("favorite videos").mediaFilter == MediaFilter(kinds: [.video], flags: [.favorite]))
        #expect(SearchFixture.parse("Greece").mediaFilter == nil)
        #expect(SearchFixture.parse("videos from Greece, selfies").mediaFilter == MediaFilter(kinds: [.video], flags: [.selfie]))
        #expect(SearchFixture.parse("screenshots").mediaFilter?.asksForScreenCaptures == true)
    }

    @Test func theModelIsCodable() throws {
        let query = SearchFixture.parse("favorite videos at Al-Nakheel Park every Saturday evening during Ramadan 1445 with Ahmed, sunset")
        let data = try JSONEncoder().encode(query)
        #expect(try JSONDecoder().decode(ParsedQuery.self, from: data) == query)
        let request = SearchRequest(text: query.text, parsed: query, overrides: ResolutionOverrides(places: [1: PlaceOverride(placeKey: "mk:x", radius: 250)]))
        #expect(request.scope == .wholeLibrary && !request.showWeaker)
    }

    // MARK: Phrases

    /// Every phrase the model renders parses back to the same value (the rules parser's round trip).
    @Test(arguments: [SearchFixture.uk, SearchFixture.us]) func everyPhraseParsesBack(_ locale: Locale) {
        var failures: [String] = []
        for expression in Self.producibleExpressions() {
            let phrase = expression.phrase(locale: locale)
            let parsed = SearchFixture.parse(phrase, locale: locale)
            if parsed.values != [.time(expression)] { failures.append("\(phrase) → \(parsed.values)") }
        }
        #expect(failures.isEmpty, "\(failures.prefix(10))")
    }

    /// The expressions the rules parser produces.
    static func producibleExpressions() -> [TimeExpression] {
        let qualifiers: [Qualifier] = [.every, .last, .this, .year(2023), .year(2030)]
        var all: [TimeExpression] = [.year(1990), .year(2024), .year(2027), .relativeDay(0), .relativeDay(-1), .workdays,
                                     .ago(.year, count: 0, onThisDay: true)]
        for month in 1...12 {
            all += qualifiers.map { .month(month, $0) }
            all += [.date(day: 4, month: month, year: nil), .date(day: 28, month: month, year: 2025)]
        }
        for unit in [TimeUnit.week, .month, .year] { all += [.calendarUnit(unit, offset: 0), .calendarUnit(unit, offset: -1)] }
        for unit in TimeUnit.allCases {
            all += [1, 2, 3, 12].map { .rolling(unit, count: $0) }
            all += [1, 3, 20].flatMap { [.ago(unit, count: $0, onThisDay: false), .ago(unit, count: $0, onThisDay: true)] }
        }
        for season in Season.allCases { all += qualifiers.map { .season(season, $0) } }
        for weekday in 1...7 { all += [.weekday(weekday, .every), .weekday(weekday, .last), .weekday(weekday, .this)] }
        all += [.weekend(.every), .weekend(.last), .weekend(.this)]
        all += [PartOfDay.morning, .noon, .afternoon, .evening, .night, .lateNight].map { .partOfDay($0) }
        for event in HijriEvent.allCases {
            all += qualifiers.map { .hijri(event, $0, hijriYear: nil) }
            all += [.hijri(event, .every, hijriYear: 1445)]
        }
        for holiday in Holiday.allCases { all += qualifiers.map { .holiday(holiday, $0) } }
        let ends: [TimeExpression] = [.year(2021), .month(6, .year(2023)), .date(day: 14, month: 6, year: 2025), .season(.summer, .year(2022)),
                                      .season(.summer, .last)]
        for from in ends {
            all.append(.range(from: from, to: nil))
            all.append(.range(from: nil, to: from))
            for to in ends where to != from { all.append(.range(from: from, to: to)) }
        }
        all += [.all([.weekday(7, .every), .partOfDay(.evening)]), .all([.weekday(6, .last), .partOfDay(.morning)]),
                .all([.relativeDay(0), .partOfDay(.tonight)]), .all([.relativeDay(-1), .partOfDay(.night)]),
                .all([.relativeDay(0), .partOfDay(.afternoon)]), .all([.weekday(7, .every), .partOfDay(.evening), .month(7, .year(2023))])]
        return all
    }

    // MARK: Edits

    @Test func anEditChangesOneSlotAndRendersTheText() throws {
        let query = SearchFixture.parse("soccer at Al-Nakheel Park last summer", ParserTableTests.knownVocabulary)
        let place = try #require(query.slots.first { $0.kind == .place })
        let time = try #require(query.slots.first { $0.kind == .time })

        let removed = query.applying([.remove(slot: time.id)])
        #expect(removed.text == "soccer Al-Nakheel Park")
        #expect(removed.isEdited)
        #expect(removed.slots.map(\.id) == [0, place.id])
        #expect(removed.spanTexts == ["soccer", "Al-Nakheel Park"])

        let summer = query.applying([.replaceTime(slot: time.id, .season(.summer, .year(2025)))])
        #expect(summer.text == "soccer Al-Nakheel Park summer 2025")
        #expect(summer.slot(place.id)?.value == place.value, "the other slots stay as they were")
        #expect(summer.slot(time.id)?.value == .time(.season(.summer, .year(2025))))
        #expect(summer.spanTexts == ["soccer", "Al-Nakheel Park", "summer 2025"])

        let near = query.applying([.setNear(slot: place.id, true), .add(.media(.videos))])
        #expect(near.text == "soccer near Al-Nakheel Park last summer videos")
        #expect(near.slot(place.id)?.value == .place(.named("Al-Nakheel Park", relation: .near, confidence: .certain)))
        #expect(near.slots.last?.id == 3)

        let picked = query.applying([.replacePlace(slot: place.id, placeKey: "mk:seed.salam-park-dubai", name: "Salam Park")])
        #expect(picked.text == "soccer Salam Park last summer")
        #expect(picked.slot(place.id)?.value == .place(.picked(placeKey: "mk:seed.salam-park-dubai", name: "Salam Park", relation: .at)))

        var overrides = ResolutionOverrides()
        overrides.apply(.replacePlace(slot: place.id, placeKey: "mk:seed.salam-park-dubai", name: "Salam Park"))
        overrides.apply(.setRadius(slot: place.id, metres: 1_000))
        #expect(overrides.places[place.id] == PlaceOverride(placeKey: "mk:seed.salam-park-dubai", radius: 1_000))
        overrides.apply(.remove(slot: place.id))
        #expect(overrides.places.isEmpty)
    }
}
