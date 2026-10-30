import Foundation
import LZGeo
import Testing
@testable import LZSearch

/// The rules parser's table (search spec §9.1): slots and values for English queries, typos and mixed slots, with the
/// unsupported words kept as their own slots.
@Suite struct ParserTableTests {
    struct Case: Sendable, CustomTestStringConvertible {
        enum Vocabulary: Sendable { case empty, known }

        var text: String
        var values: [SlotValue]
        var vocabulary: Vocabulary = .empty
        var locale = SearchFixture.uk

        var testDescription: String { "“\(text)”" }
    }

    /// Own place names and a saved place, as an index would give them.
    static let knownVocabulary = PlaceVocabulary(
        savedAliases: ["my pitch": 7, "pitch": 7],
        ownNames: ["al nakheel park", "nakheel park", "ad diriyah", "diriyah", "salam park", "kingdom centre", "mykonos", "riyadh"],
        gazetteer: SearchFixture.gazetteer)

    @Test(arguments: cases) func parses(_ testCase: Case) {
        let vocabulary = testCase.vocabulary == .known ? Self.knownVocabulary : nil
        let query = SearchFixture.parse(testCase.text, vocabulary, locale: testCase.locale)
        #expect(query.values == testCase.values)
        #expect(query.slots.map(\.id) == Array(0..<query.slots.count))
        #expect(query.parser == .rules && !query.isEdited)
    }

    /// A saved name that is also a common word ("My park", so "park") is the saved place only where it starts a name:
    /// never a word inside another place's name.
    @Test func aSavedWordInsideAnotherNameIsNotTheSavedPlace() {
        var vocabulary = Self.knownVocabulary
        vocabulary.savedAliases = ["my park": 9, "park": 9]
        let saved = SlotValue.place(.alias(.saved(9), relation: .at))
        #expect(SearchFixture.parse("Al-Nakheel Park", vocabulary).values == [Self.place("Al-Nakheel Park")])
        #expect(SearchFixture.parse("at Salam Park", vocabulary).values == [Self.place("Salam Park", .at)])
        #expect(SearchFixture.parse("Foo Park", vocabulary).values == [Self.maybe("Foo Park")])
        #expect(SearchFixture.parse("at Foo Park last summer", vocabulary).values == [Self.maybe("Foo Park", .at), Self.time(.season(.summer, .last))])
        #expect(SearchFixture.parse("park", vocabulary).values == [saved])
        #expect(SearchFixture.parse("videos at my park", vocabulary).values == [Self.videos, saved])
        #expect(SearchFixture.parse("the park last summer", vocabulary).values == [saved, Self.time(.season(.summer, .last))])
        #expect(SearchFixture.parse("videos park", vocabulary).values == [Self.videos, saved], "after words another recogniser took")
    }

    @Test func theTableIsLargeEnough() {
        #expect(Self.cases.count >= 150)
    }

    // MARK: Builders

    static func place(_ name: String, _ relation: PlaceRelation = .in) -> SlotValue { .place(.named(name, relation: relation, confidence: .certain)) }
    static func maybe(_ name: String, _ relation: PlaceRelation = .in) -> SlotValue { .place(.named(name, relation: relation, confidence: .maybe)) }
    static func unsaved(_ words: String, _ relation: PlaceRelation = .at) -> SlotValue { .place(.alias(.unsaved(words), relation: relation)) }
    static func time(_ expression: TimeExpression) -> SlotValue { .time(expression) }
    static func media(_ kinds: Set<MediaKind> = [], _ flags: Set<MediaFlag> = []) -> SlotValue { .media(MediaFilter(kinds: kinds, flags: flags)) }
    static func hijri(_ event: HijriEvent, _ qualifier: Qualifier = .every, year: Int? = nil) -> SlotValue {
        .time(.hijri(event, qualifier, hijriYear: year))
    }
    static let videos = media([.video])
    static let photos = media([.photo])
    static let trip = SlotValue.event(.trip)

    static func c(_ text: String, _ values: [SlotValue], _ vocabulary: Case.Vocabulary = .empty, locale: Locale = SearchFixture.uk) -> Case {
        Case(text: text, values: values, vocabulary: vocabulary, locale: locale)
    }

    // MARK: The table

    static let cases: [Case] = mediaCases + hijriCases + holidayCases + rangeCases + timeCases + dateCases + placeCases + eventAndPeopleCases
        + leftoverCases + mixedCases

    static let mediaCases: [Case] = [
        c("videos", [videos]),
        c("video", [videos]),
        c("clips", [videos]),
        c("movies", [videos]),
        c("footage from Dubai", [videos, place("Dubai", .from)]),
        c("only photos", [photos]),
        c("photos only", [photos]),
        c("just pictures", [photos]),
        c("no videos", [photos]),
        c("only videos", [videos]),
        c("photos", []),
        c("pictures", []),
        c("screenshots", [media([], [.screenshot])]),
        c("screen shots", [media([], [.screenshot])]),
        c("screen recordings", [media([], [.screenRecording])]),
        c("selfies", [media([], [.selfie])]),
        c("favorites", [media([], [.favorite])]),
        c("favourites", [media([], [.favorite])]),
        c("starred photos", [media([], [.favorite])]),
        c("favorite videos", [media([.video], [.favorite])]),
        c("live photos", [media([], [.livePhoto])]),
        c("portraits", [media([], [.portrait])]),
        c("panoramas", [media([], [.panorama])]),
        c("slo-mo", [media([], [.sloMo])]),
        c("slow motion videos", [media([.video], [.sloMo])]),
        c("time-lapse", [media([], [.timeLapse])]),
        c("bursts", [media([], [.burst])]),
    ]

    static let hijriCases: [Case] = [
        c("Ramadan", [hijri(.ramadan)]),
        c("Ramadan 2024", [hijri(.ramadan, .year(2024))]),
        c("Ramadan 1445", [hijri(.ramadan, year: 1445)]),
        c("last Ramadan", [hijri(.ramadan, .last)]),
        c("this Ramadan", [hijri(.ramadan, .this)]),
        c("Ramadan in 2030", [hijri(.ramadan, .year(2030))]),
        c("every Ramadan", [hijri(.ramadan)]),
        c("Ramadhan", [hijri(.ramadan)]),
        c("RAMADAN 2024", [hijri(.ramadan, .year(2024))]),
        c("Eid", [hijri(.eid)]),
        c("Eid al-Fitr", [hijri(.eidAlFitr)]),
        c("eid al fitr", [hijri(.eidAlFitr)]),
        c("Eid ul Fitr 2025", [hijri(.eidAlFitr, .year(2025))]),
        c("small eid", [hijri(.eidAlFitr)]),
        c("Eid al-Adha 2025", [hijri(.eidAlAdha, .year(2025))]),
        c("big eid", [hijri(.eidAlAdha)]),
        c("hajj", [hijri(.hajj)]),
        c("Eid 1446", [hijri(.eid, year: 1446)]),
    ]

    static let holidayCases: [Case] = [
        c("Christmas", [time(.holiday(.christmas, .every))]),
        c("Christmas 2023", [time(.holiday(.christmas, .year(2023)))]),
        c("last Christmas", [time(.holiday(.christmas, .last))]),
        c("New Year's Eve", [time(.holiday(.newYearsEve, .every))]),
        c("new years eve 2021", [time(.holiday(.newYearsEve, .year(2021)))]),
        c("NYE", [time(.holiday(.newYearsEve, .every))]),
        c("New Year’s Day", [time(.holiday(.newYearsDay, .every))]),
        c("new year", [time(.holiday(.newYearsDay, .every))]),
        c("National Day", [time(.holiday(.nationalDay, .every))]),
        c("Founding Day", [time(.holiday(.foundingDay, .every))]),
        c("London new year's eve", [place("London"), time(.holiday(.newYearsEve, .every))]),
    ]

    static let rangeCases: [Case] = [
        c("between March and May 2024", [time(.range(from: .month(3, .year(2024)), to: .month(5, .year(2024))))]),
        c("between 2021 and 2023", [time(.range(from: .year(2021), to: .year(2023)))]),
        c("from June to August 2024", [time(.range(from: .month(6, .year(2024)), to: .month(8, .year(2024))))]),
        c("between November and February 2025", [time(.range(from: .month(11, .year(2024)), to: .month(2, .year(2025))))]),
        c("from 1 June to 3 July 2025", [time(.range(from: .date(day: 1, month: 6, year: 2025), to: .date(day: 3, month: 7, year: 2025)))]),
        c("since 2020", [time(.range(from: .year(2020), to: nil))]),
        c("after June 2024", [time(.range(from: .month(6, .year(2024)), to: nil))]),
        c("since last summer", [time(.range(from: .season(.summer, .last), to: nil))]),
        c("before 2022", [time(.range(from: nil, to: .year(2022)))]),
        c("until March 2023", [time(.range(from: nil, to: .month(3, .year(2023))))]),
    ]

    static let timeCases: [Case] = [
        c("today", [time(.relativeDay(0))]),
        c("yesterday", [time(.relativeDay(-1))]),
        c("tonight", [time(.all([.relativeDay(0), .partOfDay(.tonight)]))]),
        c("recently", [time(.rolling(.day, count: 30))]),
        c("lately", [time(.rolling(.day, count: 30))]),
        c("this week", [time(.calendarUnit(.week, offset: 0))]),
        c("last week", [time(.calendarUnit(.week, offset: -1))]),
        c("last month", [time(.calendarUnit(.month, offset: -1))]),
        c("previous year", [time(.calendarUnit(.year, offset: -1))]),
        c("this year", [time(.calendarUnit(.year, offset: 0))]),
        c("past week", [time(.rolling(.week, count: 1))]),
        c("the past 3 months", [time(.rolling(.month, count: 3))]),
        c("last two weeks", [time(.rolling(.week, count: 2))]),
        c("3 years ago", [time(.ago(.year, count: 3, onThisDay: false))]),
        c("three years ago", [time(.ago(.year, count: 3, onThisDay: false))]),
        c("a year ago", [time(.ago(.year, count: 1, onThisDay: false))]),
        c("a couple of years ago", [time(.ago(.year, count: 2, onThisDay: false))]),
        c("a few months ago", [time(.ago(.month, count: 3, onThisDay: false))]),
        c("2 weeks ago", [time(.ago(.week, count: 2, onThisDay: false))]),
        c("5 days ago", [time(.ago(.day, count: 5, onThisDay: false))]),
        c("3 years ago today", [time(.ago(.year, count: 3, onThisDay: true))]),
        c("on this day", [time(.ago(.year, count: 0, onThisDay: true))]),
        c("on this day 2 years ago", [time(.ago(.year, count: 2, onThisDay: true))]),
        c("last summer", [time(.season(.summer, .last))]),
        c("this summer", [time(.season(.summer, .this))]),
        c("summer", [time(.season(.summer, .every))]),
        c("summers", [time(.season(.summer, .every))]),
        c("summer 2023", [time(.season(.summer, .year(2023)))]),
        c("summer of 2023", [time(.season(.summer, .year(2023)))]),
        c("every winter", [time(.season(.winter, .every))]),
        c("in the fall", [time(.season(.autumn, .every))]),
        c("fall 2022", [time(.season(.autumn, .year(2022)))]),
        c("autumn", [time(.season(.autumn, .every))]),
        c("last spring", [time(.season(.spring, .last))]),
        c("Saturday", [time(.weekday(7, .every))]),
        c("Saturdays", [time(.weekday(7, .every))]),
        c("on Saturday", [time(.weekday(7, .every))]),
        c("every Saturday", [time(.weekday(7, .every))]),
        c("last Saturday", [time(.weekday(7, .last))]),
        c("this Friday", [time(.weekday(6, .this))]),
        c("Fridays", [time(.weekday(6, .every))]),
        c("Saturday evening", [time(.all([.weekday(7, .every), .partOfDay(.evening)]))]),
        c("on sat", [time(.weekday(7, .every))]),
        c("sat evening", [time(.all([.weekday(7, .every), .partOfDay(.evening)]))]),
        c("weekends", [time(.weekend(.every))]),
        c("on weekends", [time(.weekend(.every))]),
        c("last weekend", [time(.weekend(.last))]),
        c("this weekend", [time(.weekend(.this))]),
        c("weekdays", [time(.workdays)]),
        c("morning", [time(.partOfDay(.morning))]),
        c("in the morning", [time(.partOfDay(.morning))]),
        c("afternoons", [time(.partOfDay(.afternoon))]),
        c("evening", [time(.partOfDay(.evening))]),
        c("at night", [time(.partOfDay(.night))]),
        c("late at night", [time(.partOfDay(.lateNight))]),
        c("late night", [time(.partOfDay(.lateNight))]),
        c("at noon", [time(.partOfDay(.noon))]),
        c("this morning", [time(.all([.relativeDay(0), .partOfDay(.morning)]))]),
        c("last night", [time(.all([.relativeDay(-1), .partOfDay(.night)]))]),
        c("yesterday evening", [time(.all([.relativeDay(-1), .partOfDay(.evening)]))]),
        c("2023", [time(.year(2023))]),
        c("in 2023", [time(.year(2023))]),
        c("photos from 2020", [time(.year(2020))]),
        c("2031", [.visual("2031")]),
    ]

    static let dateCases: [Case] = [
        c("June", [time(.month(6, .every))]),
        c("in June", [time(.month(6, .every))]),
        c("June 2023", [time(.month(6, .year(2023)))]),
        c("June of 2023", [time(.month(6, .year(2023)))]),
        c("June '23", [time(.month(6, .year(2023)))]),
        c("last June", [time(.month(6, .last))]),
        c("this June", [time(.month(6, .this))]),
        c("every June", [time(.month(6, .every))]),
        c("in May", [time(.month(5, .every))]),
        c("May 2024", [time(.month(5, .year(2024)))]),
        c("4 May", [time(.date(day: 4, month: 5, year: nil))]),
        c("may", []),
        c("14 June 2025", [time(.date(day: 14, month: 6, year: 2025))]),
        c("14th of June", [time(.date(day: 14, month: 6, year: nil))]),
        c("June 14, 2025", [time(.date(day: 14, month: 6, year: 2025))]),
        c("June 14", [time(.date(day: 14, month: 6, year: nil))]),
        c("on 2 March 2024", [time(.date(day: 2, month: 3, year: 2024))]),
        c("2024-03-02", [time(.date(day: 2, month: 3, year: 2024))]),
        c("2/3/2024", [time(.date(day: 2, month: 3, year: 2024))]),
        c("2/3/2024", [time(.date(day: 3, month: 2, year: 2024))], locale: SearchFixture.us),
        c("25/12/2023", [time(.date(day: 25, month: 12, year: 2023))], locale: SearchFixture.us),
        c("Saturday evening in July 2023", [time(.all([.weekday(7, .every), .partOfDay(.evening), .month(7, .year(2023))]))]),
    ]

    static let placeCases: [Case] = [
        c("in Jeddah", [place("Jeddah")]),
        c("in jeddah", [place("jeddah")]),
        c("Riyadh", [place("Riyadh")]),
        c("Dubai", [place("Dubai")]),
        c("Greece", [place("Greece")]),
        c("photos from Greece", [place("Greece", .from)]),
        c("nice photos", [.visual("nice")]),
        c("in Nice", [place("Nice")]),
        c("mykonos", [maybe("mykonos")]),
        c("mykonos", [place("mykonos")], .known),
        c("Santorini", [maybe("Santorini")]),
        c("sunset in Santorini", [.visual("sunset"), maybe("Santorini")]),
        c("Ad Diriyah", [maybe("Ad Diriyah")]),
        c("Diriyah", [maybe("Diriyah")]),
        c("Diriyah", [place("Diriyah")], .known),
        c("Ad Diriyah", [place("Ad Diriyah")], .known),
        c("Al-Nakheel Park", [maybe("Al-Nakheel Park")]),
        c("Al-Nakheel Park", [place("Al-Nakheel Park")], .known),
        c("at Al-Nakheel Park", [maybe("Al-Nakheel Park", .at)]),
        c("near Kingdom Centre", [maybe("Kingdom Centre", .near)]),
        c("near Kingdom Centre", [place("Kingdom Centre", .near)], .known),
        c("around Dubai Marina", [place("Dubai Marina", .near)]),
        c("UAE", [place("UAE")]),
        c("KSA", [place("KSA")]),
        c("the Netherlands", [place("the Netherlands")]),
        c("Dubai or Abu Dhabi", [.place(.anyOf([.named("Dubai", relation: .in, confidence: .certain), .named("Abu Dhabi", relation: .in, confidence: .certain)]))]),
        c("in Dubai or Abu Dhabi", [.place(.anyOf([.named("Dubai", relation: .in, confidence: .certain), .named("Abu Dhabi", relation: .in, confidence: .certain)]))]),
        c("Sufra Grill", [maybe("Sufra Grill")]),
        c("Salam Park", [maybe("Salam Park")]),
        c("Salam Park", [place("Salam Park")], .known),
        c("nakhel prk", [maybe("nakhel prk")]),
        c("Dubai Mall", [maybe("Dubai Mall")]),
        c("at the beach", [.place(.category(.beach, relation: .at))]),
        c("the beach", [.place(.category(.beach, relation: .at))]),
        c("in a park", [.place(.category(.park, relation: .in))]),
        c("near the airport", [.place(.category(.airport, relation: .near))]),
        c("beach", [.visual("beach")]),
        c("at home", [.place(.alias(.home, relation: .at))]),
        c("home", [.place(.alias(.home, relation: .at))]),
        c("near home", [.place(.alias(.home, relation: .near))]),
        c("my pitch", [.visual("pitch")]),
        c("my pitch", [.place(.alias(.saved(7), relation: .at))], .known),
        c("at my pitch", [.place(.alias(.saved(7), relation: .at))], .known),
        c("pitch", [.place(.alias(.saved(7), relation: .at))], .known),
        // E22: "my …" after a place preposition with no saved place of that name is a place that isn't saved.
        c("at my pitch", [unsaved("my pitch")]),
        c("near our cabin", [unsaved("our cabin", .near)]),
        c("from my office", [unsaved("my office", .from)]),
        c("At My Pitch last summer", [unsaved("My Pitch"), time(.season(.summer, .last))]),
        c("at my soccer pitch", [unsaved("my soccer pitch")]),
        c("at my pitch playing soccer", [unsaved("my pitch"), .visual("playing soccer")]),
        c("videos at my mom's", [videos, unsaved("my mom's")]),
        c("near our pitch", [.place(.alias(.saved(7), relation: .near))], .known),
        c("in our Diriyah", [place("Diriyah")], .known),
        c("at my home", [.place(.alias(.home, relation: .at))]),
        c("photos of my dog", [.visual("dog")]),
        c("my dog", [.visual("dog")]),
        c("near my dog", [.visual("dog")]),
        c("from my sister", [.visual("sister")]),
        c("near my family", [.people("my family")]),
        c("photos of us", [.people("us")]),
    ]

    static let eventAndPeopleCases: [Case] = [
        c("trips", [trip]),
        c("vacation", [trip]),
        c("abroad", [.event(.abroad)]),
        c("the Greece trip", [place("Greece"), trip]),
        c("Greece trip", [place("Greece"), trip]),
        c("trip to Greece", [trip, place("Greece", .to)]),
        c("holidays in Dubai", [trip, place("Dubai")]),
        c("with Ahmed", [.people("Ahmed")]),
        c("with my family", [.people("my family")]),
        c("with my kids", [.people("my kids")]),
        c("photos of me", [.people("me")]),
        c("show me videos", [videos]),
        c("with mom and dad", [.people("mom and dad")]),
    ]

    static let leftoverCases: [Case] = [
        c("soccer", [.visual("soccer")]),
        c("sunset", [.visual("sunset")]),
        c("birthday cake", [.visual("birthday cake")]),
        c("ice cream", [.visual("ice cream")]),
        c("dog park", [.visual("dog park")]),
        c("kids playing football at the park", [.visual("kids playing football"), .place(.category(.park, relation: .at))]),
        c("sunset santorini", [.visual("sunset"), maybe("santorini")]),
        c("shawarma", [.visual("shawarma")]),
        c("", []),
        c("show me all my photos", []),
    ]

    static let mixedCases: [Case] = [
        c("videos at Al-Nakheel Park last summer", [videos, maybe("Al-Nakheel Park", .at), time(.season(.summer, .last))]),
        c("soccer at Al-Nakheel Park", [.visual("soccer"), maybe("Al-Nakheel Park", .at)]),
        c("soccer at Al-Nakheel Park", [.visual("soccer"), place("Al-Nakheel Park", .at)], .known),
        c("Saturday evening at Al-Nakheel Park", [time(.all([.weekday(7, .every), .partOfDay(.evening)])), maybe("Al-Nakheel Park", .at)]),
        c("al nakheel park 2025", [maybe("al nakheel park"), time(.year(2025))]),
        c("al nakheel park 2025", [place("al nakheel park"), time(.year(2025))], .known),
        c("Dubai December 2024", [place("Dubai"), time(.month(12, .year(2024)))]),
        c("Dubai last December", [place("Dubai"), time(.month(12, .last))]),
        c("Dubai, last December", [place("Dubai"), time(.month(12, .last))]),
        c("Riyadh 2025", [place("Riyadh"), time(.year(2025))]),
        c("weekends in Riyadh", [time(.weekend(.every)), place("Riyadh")]),
        c("Sydney in summer", [place("Sydney"), time(.season(.summer, .every))]),
        c("Al-Nakheel Park during Ramadan 2024", [maybe("Al-Nakheel Park"), hijri(.ramadan, .year(2024))]),
        c("videos from Eid", [videos, hijri(.eid)]),
        c("selfies from Eid", [media([], [.selfie]), hijri(.eid)]),
        c("favorite selfies in London last year", [media([], [.favorite, .selfie]), place("London"), time(.calendarUnit(.year, offset: -1))]),
        c("screenshots from last week", [media([], [.screenshot]), time(.calendarUnit(.week, offset: -1))]),
        c("photos in June in Jeddah", [time(.month(6, .every)), place("Jeddah")]),
        c("in Jeddah, June", [place("Jeddah"), time(.month(6, .every))]),
        c("at night at home", [time(.partOfDay(.night)), .place(.alias(.home, relation: .at))]),
        c("Dubai 2024 videos", [place("Dubai"), time(.year(2024)), videos]),
        c("Saturday  evening", [time(.all([.weekday(7, .every), .partOfDay(.evening)]))]),
        c("trips abroad", [trip, .event(.abroad)]),
        c("sunset at the beach with Ahmed", [.visual("sunset"), .place(.category(.beach, relation: .at)), .people("Ahmed")]),
        c("Greece 2023 trip videos", [place("Greece"), time(.year(2023)), trip, videos]),
    ]
}
