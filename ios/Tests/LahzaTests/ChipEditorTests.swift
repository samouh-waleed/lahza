import Foundation
import LZCore
import LZGeo
import LZIndex
import LZLibrary
import LZSearch
import Testing
@testable import Lahza

/// The chip editors on Ask (search spec §7.1, PR 4) over the fake hero library, unlocked: chips that open their
/// editor, what each editor edits, acceptance 1 (edits on #4 re-render the field and search again) and 2 (a pick is
/// remembered on a re-search), the radius and part-of-day choices, the photo-type choices and custom dates.
@MainActor @Suite struct ChipEditorTests {
    static let hero = SeedScenario.hero

    private func slot(_ app: AppModel, _ kind: SlotKind) throws -> ResolvedSlot {
        try #require(app.search.result?.query.slots.first { $0.slot.kind == kind })
    }

    private func bestNumbers(_ app: AppModel) -> Set<Int> {
        Set(app.search.result?.hits.filter { $0.tier == .best }.compactMap { $0.utc.flatMap { Self.hero.item(matchingUTC: $0)?.number } } ?? [])
    }

    @Test func eachChipOpensTheEditorOfItsSlot() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let result = try #require(await SearchTestApp.search(app, "soccer videos at Al-Nakheel Park last summer"))
        let kinds = result.query.slots.map { ($0.slot.kind, ChipEditorKind($0)) }
        #expect(kinds.contains { if case (.place, .place) = $0 { true } else { false } })
        #expect(kinds.contains { if case (.time, .time(.season(.summer, .last), _)) = $0 { true } else { false } })
        #expect(kinds.contains { if case (.media, .media(.videos)) = $0 { true } else { false } })
        #expect(kinds.contains { $0.1 == .unsupported(AskCopy.unsupportedExplanation(.visual)) })
        let trips = try #require(await SearchTestApp.search(app, "trips"))
        #expect(trips.query.slots.map(ChipEditorKind.init) == [.event(.trip)])

        // VoiceOver: "Place, Al-Nakheel Park, button, Edit".
        let chips = QueryChipModel.chips(result.query)
        #expect(chips.first { $0.kind == .place }?.accessibilityLabel == "Place, Al-Nakheel Park")
        #expect(AskCopy.editHint == "Edit")
    }

    /// Acceptance 1: on #4, remove the dates → #1's result; last summer → Summer 2025 → the 14 Jun 2025 session; the field's
    /// words follow each time.
    @Test func editsOnTheParkLastSummer() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        _ = try #require(await SearchTestApp.search(app, "Al-Nakheel Park last summer"))
        let time = try slot(app, .time)
        guard case .time(let expression, _) = ChipEditorKind(time) else { Issue.record("not a date chip"); return }
        #expect(expression == .season(.summer, .last))
        #expect(time.timePresets.map(\.label) == ["Summer 2025", "Every summer", "Any time"])

        app.search.apply([.remove(slot: time.id)])
        #expect(await SearchTestApp.eventually(app) { app.search.text == "Al-Nakheel Park" && app.search.result?.query.slots.count == 1 })
        #expect(bestNumbers(app) == Set(Self.hero.items(.nakheel).map(\.number)))

        _ = try #require(await SearchTestApp.search(app, "Al-Nakheel Park last summer"))
        let summer = try #require(try slot(app, .time).timePresets.first)
        app.search.apply([.replaceTime(slot: time.id, try #require(summer.expression))])
        #expect(await SearchTestApp.eventually(app) { app.search.text == "Al-Nakheel Park summer 2025" && app.search.result?.query.parsed.isEdited == true })
        let june14 = Self.hero.items(.nakheel).filter { $0.momentDay == LocalTime.day(year: 2025, month: 6, day: 14) }
        #expect(!june14.isEmpty && bestNumbers(app) == Set(june14.map(\.number)))
    }

    /// The first time's chip opens the order editor; Last time searches the latest visit, and the result's Show all
    /// (like the editor's All times after the first time) lists every visit oldest first, in moments and in the grid.
    @Test func theFirstTimeChipAndShowAll() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        let nakheel = Self.hero.items(.nakheel)
        let first = try #require(await SearchTestApp.search(app, "the first time at Al-Nakheel Park"))
        let order = try slot(app, .order)
        #expect(ChipEditorKind(order) == .order(.first))
        #expect(order.chip == "First time" && order.systemImage == AskCopy.orderSymbol(.first))
        #expect(QueryChipModel.chips(first.query).map(\.title) == ["First time", "Al-Nakheel Park"])
        #expect(QueryChipModel.chips(first.query).first?.accessibilityLabel == "Order, First time")
        #expect(bestNumbers(app) == Set(nakheel.filter { $0.momentDay == LocalTime.day(year: 2024, month: 3, day: 2) }.map(\.number)))
        let occasion = try #require(first.occasion)
        #expect(occasion.othersLabel == "9 later times" && first.sections.first?.title == "First time at Al-Nakheel Park")

        app.search.apply([.replaceOrder(slot: order.id, .last)])
        #expect(await SearchTestApp.eventually(app) { app.search.text == "the last time at Al-Nakheel Park" && app.search.result?.occasion?.order == .last })
        #expect(bestNumbers(app) == Set(nakheel.filter { $0.momentDay == LocalTime.day(year: 2026, month: 8, day: 22) }.map(\.number)))
        #expect(app.search.result?.occasion?.othersLabel == "9 earlier times")

        app.search.apply([.replaceOrder(slot: order.id, .first)])
        #expect(await SearchTestApp.eventually(app) { app.search.result?.occasion?.order == .first })
        app.search.apply(try #require(app.search.result?.occasion?.showAll))
        #expect(await SearchTestApp.eventually(app) { app.search.text == "at Al-Nakheel Park oldest first" && app.search.result?.occasion == nil })
        let all = try #require(app.search.result)
        let oldest = try slot(app, .order)
        #expect(oldest.chip == "Oldest first" && ChipEditorKind(oldest) == .order(.oldestFirst))
        #expect(bestNumbers(app) == Set(nakheel.map(\.number)))
        let days = all.cards.filter { $0.tier == .best }.map(\.id.day)
        #expect(days == days.sorted() && days.count == 10, "moments oldest first")
        // The grid lists the same photos in the same order, so switching keeps it.
        app.search.setLayout(.grid)
        let tiles = ResultGrid(all, showsUnknown: false).tiles.map(\.hit.id)
        #expect(tiles == all.cards.filter { $0.tier != .locationUnknown }.flatMap(\.hits).map(\.id))
        let utcs = ResultGrid(all, showsUnknown: false).tiles.filter { $0.hit.tier == .best }.compactMap(\.hit.utc)
        #expect(utcs == utcs.sorted(), "the grid oldest first")
        app.search.setLayout(.moments)

        // Newest first from the order editor.
        app.search.apply([.replaceOrder(slot: order.id, .newestFirst)])
        #expect(await SearchTestApp.eventually(app) { app.search.text == "at Al-Nakheel Park newest first" })
        let newest = app.search.result?.cards.filter { $0.tier == .best }.map(\.id.day) ?? []
        #expect(newest == newest.sorted(by: >) && newest.count == 10)
    }

    /// The editors' words: an order chip's explanation, choices and Remove.
    @Test func theOrderEditorsWords() {
        #expect(ChipEditorCopy.OccasionChoice.allCases.map(\.title) == ["First time", "Last time", "All times"])
        #expect(ChipEditorCopy.OccasionChoice(.oldestFirst) == .all)
        #expect([SearchOrder.oldestFirst, .newestFirst].map(ChipEditorCopy.title) == ["Oldest first", "Newest first"])
        #expect(ChipEditorCopy.remove(SearchOrder.first) == "Remove first time" && ChipEditorCopy.remove(SearchOrder.oldestFirst) == "Remove order")
        #expect(AskCopy.slotName(.order) == "Order" && AskCopy.showAll == "Show all")
    }

    /// Acceptance 2: the place picked (picker or editor) is searched when the words are typed again, without a picker.
    @Test func aPickIsRememberedOnAReSearch() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        _ = try #require(await SearchTestApp.search(app, "Salam Park"))
        let place = try slot(app, .place)
        guard case .place(let resolution) = ChipEditorKind(place) else { Issue.record("not a place chip"); return }
        #expect(resolution.candidates.map { $0.context ?? "" } == ["Riyadh", "Dubai"], "the editor lists both parks, the searched one first")
        let dubai = try #require(resolution.candidates.last)
        app.search.choose(dubai, forSlot: place.id)
        let twin = Self.hero.items(.dubai1).filter { $0.title == SeedPlace.salamParkDubai.name && $0.isLocated }
        #expect(await SearchTestApp.eventually(app) { bestNumbers(app) == Set(twin.map(\.number)) })
        for _ in 0..<100 where try await app.index.reader?.placeChoice(for: "salam park") == nil { try await Task.sleep(for: .milliseconds(10)) }

        _ = try #require(await SearchTestApp.search(app, "Salam Park"))
        #expect(bestNumbers(app) == Set(twin.map(\.number)))
        #expect(app.search.result?.query.picker == nil)
    }

    @Test func theAreaChoicesShowTheirMetres() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        _ = try #require(await SearchTestApp.search(app, "Al-Nakheel Park"))
        let radius = try #require(try slot(app, .place).radius)
        #expect(PlaceRadius.Choice.allCases.map { ChipEditorCopy.radius($0, radius) } == ["Tight · 200 m", "Normal · 400 m", "Wide · 800 m"])
        #expect(ChipEditorCopy.within(radius) == "Photos within 400 m")

        app.search.apply([.setRadius(slot: try slot(app, .place).id, metres: radius.metres(.wide)), .setNear(slot: try slot(app, .place).id, true)])
        #expect(await SearchTestApp.eventually(app) { (try? slot(app, .place).radius) == PlaceRadius(natural: 400, chosen: 800, near: true) })
        let wide = try #require(try slot(app, .place).radius)
        #expect(wide.choice == .wide && ChipEditorCopy.within(wide) == "Photos within 1.6 km")
        #expect(try slot(app, .place).chip == "Near Al-Nakheel Park" && app.search.text == "near Al-Nakheel Park")
    }

    @Test func partOfDayAndPhotoTypeChoices() {
        typealias Part = ChipEditorCopy.PartOfDayChoice
        #expect(Part.allCases.map(\.title) == ["Any", "Morning", "Afternoon", "Evening", "Night"])
        #expect(Part(nil) == .any && Part(.evening) == .evening && Part(.noon) == nil && Part(.tonight) == nil)
        let saturdayEvening = TimeExpression.all([.weekday(7, .every), .partOfDay(.evening)])
        #expect(saturdayEvening.with(partOfDay: Part.morning.part) == .all([.weekday(7, .every), .partOfDay(.morning)]))
        #expect(saturdayEvening.with(partOfDay: Part.any.part) == .weekday(7, .every))

        typealias Media = ChipEditorCopy.MediaChoice
        #expect(Media.allCases.map(\.title) == ["Photos & videos", "Photos", "Videos"])
        #expect(Media([.video]) == .videos && Media([]) == .all && Media([.photo, .video]) == .all)
        #expect(MediaFilter(kinds: Media.all.kinds).isEmpty, "photos & videos without a flag is no photo type: the chip goes")
    }

    @Test func customDatesAreAnEditableRange() throws {
        let from = ChipEditorCopy.date(LocalTime.day(year: 2025, month: 6, day: 1))
        let to = ChipEditorCopy.date(LocalTime.day(year: 2025, month: 6, day: 30))
        let range = ChipEditorCopy.range(from: from, to: to)
        #expect(range == .range(from: .date(day: 1, month: 6, year: 2025), to: .date(day: 30, month: 6, year: 2025)))
        #expect(ChipEditorCopy.remove(.time) == "Remove dates" && ChipEditorCopy.remove(.place) == "Remove place")
        #expect(ChipEditorCopy.searchAppleMaps("Al-Nakheel Park") == "Search Apple Maps for “Al-Nakheel Park”")
    }

    /// The sheet's title keeps a chip's dates on one line; Abroad explains itself, not Trips; an Apple Maps search that
    /// couldn't be made says why.
    @Test func editorWords() {
        let chip = "Last summer · Jun\u{2009}–\u{2009}Aug 2026"
        let title = ChipEditorCopy.title(chip)
        #expect(title.hasPrefix("Last summer · ") && !title.dropFirst("Last summer · ".count).contains { $0 == " " || $0 == "\u{2009}" })
        #expect(title.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: "\u{2009}") == chip)
        #expect(ChipEditorCopy.title("Al-Nakheel Park") == "Al-Nakheel Park")
        #expect(ChipEditorCopy.explanation(.abroad) == "Photos from your trips outside your home country.")
        #expect(ChipEditorCopy.remove(EventKind.abroad) == "Remove trips abroad" && ChipEditorCopy.remove(.event) == "Remove trips")
        #expect(ChipEditorCopy.appleMapsMissed(.offline) == "Couldn’t reach Apple Maps offline. Try again when you’re online.")
        #expect(AskCopy.unsupportedEditHint != AskCopy.unsupportedHint)
    }

    /// Custom dates keep the part of the day, as the presets do.
    @Test func customDatesKeepThePartOfTheDay() {
        let range = ChipEditorCopy.range(from: ChipEditorCopy.date(LocalTime.day(year: 2025, month: 6, day: 1)),
                                         to: ChipEditorCopy.date(LocalTime.day(year: 2025, month: 6, day: 30)))
        let night = TimeExpression.all([.season(.summer, .last), .partOfDay(.night)])
        #expect(range.with(partOfDay: night.partOfDay) == .all([range, .partOfDay(.night)]))
    }

    @Test func aCustomRangeSearchesItsDays() async throws {
        let app = await SearchTestApp.ready(.unlocked)
        _ = try #require(await SearchTestApp.search(app, "Al-Nakheel Park last summer"))
        let time = try slot(app, .time)
        let june = ChipEditorCopy.range(from: ChipEditorCopy.date(LocalTime.day(year: 2025, month: 6, day: 1)),
                                        to: ChipEditorCopy.date(LocalTime.day(year: 2025, month: 6, day: 30)))
        app.search.apply([.replaceTime(slot: time.id, june)])
        #expect(await SearchTestApp.eventually(app) { app.search.result?.query.parsed.slot(time.id)?.value == .time(june) && app.search.state != .searching })
        let june14 = Self.hero.items(.nakheel).filter { $0.momentDay == LocalTime.day(year: 2025, month: 6, day: 14) }
        #expect(bestNumbers(app) == Set(june14.map(\.number)))
        #expect(app.search.text.hasPrefix("Al-Nakheel Park between "))
    }
}
