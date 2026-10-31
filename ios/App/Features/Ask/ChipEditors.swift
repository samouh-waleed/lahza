import LZDesign
import LZGeo
import LZIndex
import LZSearch
import SwiftUI

/// The slot whose chip editor is open.
nonisolated struct EditedSlot: Identifiable, Hashable {
    let id: Int
}

/// What a chip's editor edits (search spec §7.1, chip editors).
nonisolated enum ChipEditorKind: Equatable {
    /// The candidates, Apple Maps on request, an area's radius and "near".
    case place(PlaceResolution)
    /// Presets, the part of the day and custom dates.
    case time(TimeExpression, TimeConstraint)
    /// Photos, videos or both, favorites and screenshots.
    case media(MediaFilter)
    case event(EventKind)
    /// First time, last time or all times; oldest or newest first.
    case order(SearchOrder)
    /// The photo tags the words searched, and their related tags on or off.
    case visual(VisualMatch)
    /// Words Lahza can't search yet, a second place or dates it couldn't use: why, and Remove.
    case unsupported(String)

    init(_ slot: ResolvedSlot) {
        self.init(slot, tags: false)
    }

    /// `tags`: the index has a Vision pass (words with no tag say so).
    init(_ slot: ResolvedSlot, tags: Bool) {
        switch (slot.resolution, slot.slot.value) {
        case (.place(let resolution), _): self = .place(resolution)
        case (.time(.constraint(let constraint)), .time(let expression)): self = .time(expression, constraint)
        case (.media(let filter), _): self = .media(filter)
        case (.event(let event), _): self = .event(event)
        case (.order(let order), _): self = .order(order)
        case (.visual(let match), _): self = .visual(match)
        default: self = .unsupported(AskCopy.unsupportedExplanation(slot.slot.kind, tags: tags))
        }
    }
}

/// A chip's editor: a sheet over the results for one slot of the shown search. Every change applies a ``SlotEdit``
/// (the field's words are rendered from the slots again) and searches at once; the sheet stays on the slot and follows
/// the new result. Remove closes it.
struct ChipEditorSheet: View {
    let slotID: Int
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let query = model.search.result?.query
        ScrollView {
            if let query, let slot = query.slots.first(where: { $0.id == slotID }) {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(slot.isSupported ? ChipEditorCopy.title(slot.chip) : AskCopy.notYet(slot.chip, kind: slot.slot.kind),
                                eyebrow: AskCopy.slotName(slot.slot.kind).uppercased())
                    VStack(alignment: .leading, spacing: LZSpace.xl) {
                        editor(slot, query: query)
                    }
                    .padding(.horizontal, LZLayout.gutter)
                    .padding(.bottom, LZSpace.xl)
                }
                .accessibilityIdentifier("chip-editor-\(slot.slot.kind.rawValue)")
            }
        }
        .lzSheetPresentation([.medium, .large])
    }

    @ViewBuilder
    private func editor(_ slot: ResolvedSlot, query: ResolvedQuery) -> some View {
        switch ChipEditorKind(slot, tags: model.index.status.visual != nil) {
        case .place(let resolution):
            PlaceEditor(slot: slot, query: query, resolution: resolution, remove: remove)
        case .time(let expression, let constraint):
            let today = MomentCopy.today(now: model.dependencies.clock.now, zone: model.dependencies.deviceTimeZone())
            TimeEditor(slot: slot, expression: expression, days: constraint.days ?? (today - 29)...today, remove: remove)
                .id(slot.chip)
        case .media(let filter):
            MediaEditor(slot: slot, filter: filter, remove: remove)
        case .event(let event):
            EditorExplanation(text: ChipEditorCopy.explanation(event))
            RemoveButton(title: ChipEditorCopy.remove(event), action: remove)
        case .order(let order):
            OrderEditor(slot: slot, order: order, remove: remove)
        case .visual(let match):
            VisualEditor(slot: slot, match: match, remove: remove)
        case .unsupported(let explanation):
            EditorExplanation(text: explanation)
            RemoveButton(title: ChipEditorCopy.removeWords, action: remove)
        }
    }

    private func remove() {
        model.search.apply([.remove(slot: slotID)])
        dismiss()
    }
}

// MARK: Place

/// The places the words may mean (the one searched ticked), "Search Apple Maps for “X”" while the search hasn't asked,
/// and for an area its radius and "near". A name no saved place goes by, or a home there isn't, says why.
private struct PlaceEditor: View {
    let slot: ResolvedSlot
    let query: ResolvedQuery
    let resolution: PlaceResolution
    let remove: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let candidates = Array(resolution.candidates.prefix(ChipEditorCopy.maxCandidates))
        if case .notFound(let reason) = resolution, let explanation = ChipEditorCopy.notFound(reason) {
            EditorExplanation(text: explanation)
        }
        if !candidates.isEmpty {
            EditorSection(ChipEditorCopy.places) {
                LZRowGroup {
                    ForEach(candidates) { candidate in
                        let chosen = candidate.id == resolution.chosen?.id
                        ListRow(candidate.name, subtitle: candidate.subtitle.isEmpty ? nil : candidate.subtitle,
                                value: MomentCopy.count(candidate.photoCount, "photo"), accessory: chosen ? .checkmark : .none) {
                            if !chosen { model.search.choose(candidate, forSlot: slot.id) }
                        }
                        .accessibilityIdentifier("chip-editor-candidate")
                    }
                }
            }
        }
        if let words = appleMapsWords {
            let asked = model.search.request?.overrides.places[slot.id]?.searchesAppleMaps == true
            // Asked but not made (offline, busy): the row stays, says why and tries again.
            let missed = isSearching ? nil : query.appleMapsMissed
            if !asked || isSearching || missed != nil {
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    LZRowGroup {
                        ListRow(ChipEditorCopy.searchAppleMaps(words), systemImage: "magnifyingglass", isLoading: asked && isSearching) {
                            model.search.apply([.searchAppleMaps(slot: slot.id)])
                        }
                        .accessibilityIdentifier("chip-editor-apple-maps")
                    }
                    if let missed {
                        Text(ChipEditorCopy.appleMapsMissed(missed))
                            .lzText(.caption)
                            .foregroundStyle(.lz(.muted))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chip-editor-apple-maps-missed")
                    }
                }
            }
        }
        if let radius = slot.radius {
            EditorSection(ChipEditorCopy.area) {
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    LZSegmented(ChipEditorCopy.areaLabel, options: PlaceRadius.Choice.allCases.map { LZChipOption($0, title: ChipEditorCopy.radius($0, radius)) },
                                selection: Binding<PlaceRadius.Choice?>(get: { radius.choice }, set: { choice in
                                    guard let choice, choice != radius.choice else { return }
                                    model.search.apply([.setRadius(slot: slot.id, metres: radius.metres(choice))])
                                }))
                    Text(ChipEditorCopy.within(radius))
                        .lzText(.caption)
                        .foregroundStyle(.lz(.muted))
                }
                LZRowGroup {
                    LZToggleRow(ChipEditorCopy.near, subtitle: ChipEditorCopy.nearDetail, isOn: Binding(get: { radius.near }, set: { near in
                        model.search.apply([.setNear(slot: slot.id, near)])
                    }))
                }
            }
        }
        RemoveButton(title: ChipEditorCopy.remove(.place), action: remove)
    }

    /// The words to look up on Apple Maps, while this search hasn't asked it and place names are on: those typed for
    /// the slot, never a picked place's own name (a saved place's is the person's own).
    private var appleMapsWords: String? {
        guard model.index.appleMapsNames, !query.searchedAppleMaps, case .place(let place) = slot.slot.value, place.words != nil else { return nil }
        if case .picked = place, model.search.request?.overrides.places[slot.id]?.typedWords == nil { return nil }
        return model.search.typedWords(slot: slot.id)
    }

    private var isSearching: Bool {
        switch model.search.state {
        case .understanding, .searching, .lookingUpPlace: true
        default: false
        }
    }
}

// MARK: Time

/// The chip's presets ("Summer 2025 · Every summer · Any time"), the part of the day, and custom dates.
private struct TimeEditor: View {
    let slot: ResolvedSlot
    let expression: TimeExpression
    let remove: () -> Void
    @State private var from: Date
    @State private var to: Date
    @Environment(AppModel.self) private var model

    init(slot: ResolvedSlot, expression: TimeExpression, days: ClosedRange<Int32>, remove: @escaping () -> Void) {
        self.slot = slot
        self.expression = expression
        self.remove = remove
        _from = State(initialValue: ChipEditorCopy.date(days.lowerBound))
        _to = State(initialValue: ChipEditorCopy.date(days.upperBound))
    }

    var body: some View {
        if !slot.timePresets.isEmpty {
            EditorSection(ChipEditorCopy.presets) {
                LZChipGroup(ChipEditorCopy.presetsLabel, options: slot.timePresets.map { LZChipOption(Optional($0.label), title: $0.label) },
                            selection: Binding<String?>(get: { nil }, set: { label in
                                guard let preset = slot.timePresets.first(where: { $0.label == label }) else { return }
                                if let replacement = preset.expression {
                                    model.search.apply([.replaceTime(slot: slot.id, replacement)])
                                } else {
                                    remove()
                                }
                            }))
                .accessibilityIdentifier("chip-editor-presets")
            }
        }
        EditorSection(ChipEditorCopy.partOfDay) {
            LZSegmented(ChipEditorCopy.partOfDayLabel, options: ChipEditorCopy.PartOfDayChoice.allCases.map { LZChipOption(Optional($0), title: $0.title) },
                        selection: Binding<ChipEditorCopy.PartOfDayChoice?>(get: { ChipEditorCopy.PartOfDayChoice(expression.partOfDay) }, set: { choice in
                            guard let choice, choice != ChipEditorCopy.PartOfDayChoice(expression.partOfDay) else { return }
                            if let replacement = expression.with(partOfDay: choice.part) {
                                model.search.apply([.replaceTime(slot: slot.id, replacement)])
                            } else {
                                remove()
                            }
                        }))
        }
        EditorSection(ChipEditorCopy.customDates) {
            VStack(alignment: .leading, spacing: LZSpace.sm) {
                DateRow(title: ChipEditorCopy.from) {
                    DatePicker(ChipEditorCopy.from, selection: $from, displayedComponents: .date)
                }
                DateRow(title: ChipEditorCopy.to) {
                    DatePicker(ChipEditorCopy.to, selection: $to, in: from..., displayedComponents: .date)
                }
            }
            .environment(\.calendar, ChipEditorCopy.calendar)
            LZButton(ChipEditorCopy.searchDates, role: .secondary, size: .small) {
                // The part of the day stays, as with the presets.
                let range = ChipEditorCopy.range(from: from, to: max(from, to))
                model.search.apply([.replaceTime(slot: slot.id, range.with(partOfDay: expression.partOfDay) ?? range)])
            }
            .accessibilityIdentifier("chip-editor-search-dates")
        }
        RemoveButton(title: ChipEditorCopy.remove(.time), action: remove)
    }
}

/// "From" and its date, side by side; the label goes above the date at accessibility text sizes.
private struct DateRow<Picker: View>: View {
    let title: String
    @ViewBuilder let picker: Picker

    var body: some View {
        LZAdaptiveStack(spacing: LZSpace.xs) {
            Text(title)
                .lzText(.body)
                .foregroundStyle(.lz(.ink))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            picker
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(Color.lz(.accent))
        }
        .frame(minHeight: LZHitTarget.comfortable)
    }
}

// MARK: Media

/// Photos & videos, photos or videos, then favorites only and screenshots. Photos & videos with neither is no photo
/// type at all: the chip goes.
private struct MediaEditor: View {
    let slot: ResolvedSlot
    let filter: MediaFilter
    let remove: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        EditorSection(ChipEditorCopy.show) {
            LZChipGroup(ChipEditorCopy.showLabel, options: ChipEditorCopy.MediaChoice.allCases.map { LZChipOption($0, title: $0.title) },
                        selection: Binding(get: { ChipEditorCopy.MediaChoice(filter.kinds) }, set: { choice in
                            var changed = filter
                            changed.kinds = choice.kinds
                            change(to: changed)
                        }))
            LZRowGroup {
                LZToggleRow(ChipEditorCopy.favoritesOnly, isOn: flag(.favorite))
                LZToggleRow(ChipEditorCopy.screenshots, isOn: flag(.screenshot))
            }
        }
        RemoveButton(title: ChipEditorCopy.remove(.media), action: remove)
    }

    private func flag(_ flag: MediaFlag) -> Binding<Bool> {
        Binding(get: { filter.flags.contains(flag) }, set: { on in
            var changed = filter
            if on { changed.flags.insert(flag) } else { changed.flags.remove(flag) }
            change(to: changed)
        })
    }

    private func change(to changed: MediaFilter) {
        guard changed != filter else { return }
        if changed.isEmpty { remove() } else { model.search.apply([.replaceMedia(slot: slot.id, changed)]) }
    }
}

// MARK: Order

/// The first or last time, or every time (after the first time oldest first, as its "Show all" lists them); for an
/// order, oldest or newest first.
private struct OrderEditor: View {
    let slot: ResolvedSlot
    let order: SearchOrder
    let remove: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        EditorExplanation(text: ChipEditorCopy.explanation(order))
        EditorSection(ChipEditorCopy.show) {
            if order.isOccasion {
                LZChipGroup(ChipEditorCopy.occasionLabel, options: ChipEditorCopy.OccasionChoice.allCases.map { LZChipOption($0, title: $0.title) },
                            selection: Binding(get: { ChipEditorCopy.OccasionChoice(order) }, set: { choose($0) }))
                .accessibilityIdentifier("chip-editor-occasion")
            } else {
                LZSegmented(ChipEditorCopy.orderLabel, options: [SearchOrder.oldestFirst, .newestFirst].map { LZChipOption($0, title: ChipEditorCopy.title($0)) },
                            selection: Binding(get: { order }, set: { changed in
                                if changed != order { model.search.apply([.replaceOrder(slot: slot.id, changed)]) }
                            }))
                .accessibilityIdentifier("chip-editor-order")
            }
        }
        RemoveButton(title: ChipEditorCopy.remove(order), action: remove)
    }

    /// All times lists every time as the result's "Show all" does: oldest first after the first time, newest first
    /// (the chip goes) after the last.
    private func choose(_ choice: ChipEditorCopy.OccasionChoice) {
        guard choice != ChipEditorCopy.OccasionChoice(order) else { return }
        switch choice {
        case .first: model.search.apply([.replaceOrder(slot: slot.id, .first)])
        case .last: model.search.apply([.replaceOrder(slot: slot.id, .last)])
        case .all where order == .first: model.search.apply([.replaceOrder(slot: slot.id, .oldestFirst)])
        case .all: remove()
        }
    }
}

// MARK: Photo tags

/// What a photo-tag chip searches: the tags your iPhone gives photos for these words (they can be Best), and the
/// related tags, which only reach Less sure and can be turned off (E24); while photos are still being checked, how far
/// it has got (E25).
private struct VisualEditor: View {
    let slot: ResolvedSlot
    let match: VisualMatch
    let remove: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        EditorExplanation(text: ChipEditorCopy.explanation(match))
        EditorSection(ChipEditorCopy.photoTags) {
            LZRowGroup {
                ForEach(match.tags, id: \.self) { tag in
                    ListRow(tag, systemImage: "tag")
                }
            }
        }
        .accessibilityIdentifier("chip-editor-tags")
        if !match.related.isEmpty {
            EditorSection(ChipEditorCopy.relatedTags) {
                LZRowGroup {
                    LZToggleRow(ChipEditorCopy.includeRelated, subtitle: match.related.joined(separator: ", "),
                                isOn: Binding(get: { !match.relatedRemoved }, set: { on in
                                    if on == match.relatedRemoved { model.search.apply([.setRelatedTags(slot: slot.id, on)]) }
                                }))
                    .accessibilityIdentifier("chip-editor-related")
                }
            }
        }
        if let line = model.search.result?.coverage.visualLine {
            Label(line, systemImage: "hourglass")
                .lzText(.caption)
                .foregroundStyle(.lz(.muted))
        }
        RemoveButton(title: ChipEditorCopy.removeWords, action: remove)
    }
}

// MARK: Parts

/// A labelled group of an editor ("PLACES", "PART OF DAY").
private struct EditorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.sm) {
            Text(title)
                .lzText(.label)
                .foregroundStyle(.lz(.muted))
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct EditorExplanation: View {
    let text: String

    var body: some View {
        Text(text)
            .lzText(.body)
            .foregroundStyle(.lz(.ink))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RemoveButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        LZButton(title, systemImage: "minus.circle", role: .quiet, size: .small, action: action)
            .accessibilityIdentifier("chip-editor-remove")
    }
}

// MARK: Copy

nonisolated enum ChipEditorCopy {
    static let maxCandidates = 8
    static let places = "PLACES"
    static let area = "AREA"
    static let areaLabel = "How far around the place"
    static let near = "Near"
    static let nearDetail = "Doubles the area, for photos taken around it"
    static let presets = "CHANGE TO"
    static let presetsLabel = "Change the dates"
    static let partOfDay = "PART OF DAY"
    static let partOfDayLabel = "Part of day"
    static let customDates = "CUSTOM DATES"
    static let from = "From"
    static let to = "To"
    static let searchDates = "Search these dates"
    static let show = "SHOW"
    static let showLabel = "Photo type"
    static let favoritesOnly = "Favorites only"
    static let screenshots = "Screenshots"
    static let removeWords = "Remove these words"
    static let occasionLabel = "Which time"
    static let orderLabel = "Order"
    static let photoTags = "PHOTO TAGS"
    static let relatedTags = "RELATED TAGS"
    static let includeRelated = "Include related tags"

    /// What a photo-tag chip keeps.
    static func explanation(_ match: VisualMatch) -> String {
        let related = match.related.isEmpty ? "" : " Photos with only a related tag show under Less sure."
        return "Photos your iPhone tagged \(match.tags.first ?? match.concept), on the iPhone. Nothing leaves it.\(related)"
    }

    /// The sheet's title: the chip, its dates kept on one line ("Last summer · Jun – Aug 2026" never breaks at the
    /// dash): spaces become no-break ones (the thin spaces around the dash narrow no-break ones).
    static func title(_ chip: String) -> String {
        guard let separator = chip.range(of: " · ", options: .backwards) else { return chip }
        let dates = chip[separator.upperBound...].replacingOccurrences(of: " ", with: "\u{00A0}")
            .replacingOccurrences(of: "\u{2009}", with: "\u{202F}").replacingOccurrences(of: "–", with: "\u{2060}–\u{2060}")
        return String(chip[..<separator.upperBound]) + dates
    }

    /// What a Trips or Abroad chip keeps.
    static func explanation(_ event: EventKind) -> String {
        switch event {
        case .trip: "Photos from your trips: two or more days in a row away from home."
        case .abroad: "Photos from your trips outside your home country."
        }
    }

    /// What an order chip keeps.
    static func explanation(_ order: SearchOrder) -> String {
        switch order {
        case .first: "The earliest time that matches: the whole trip for a city or country away from home, otherwise that outing."
        case .last: "The most recent time that matches: the whole trip for a city or country away from home, otherwise that outing."
        case .oldestFirst: "Every time that matches, from oldest to newest."
        case .newestFirst: "Every time that matches, from newest to oldest."
        }
    }

    /// "Oldest first", "Newest first".
    static func title(_ order: SearchOrder) -> String {
        switch order {
        case .first: "First time"
        case .last: "Last time"
        case .oldestFirst: "Oldest first"
        case .newestFirst: "Newest first"
        }
    }

    static func remove(_ order: SearchOrder) -> String {
        switch order {
        case .first: "Remove first time"
        case .last: "Remove last time"
        case .oldestFirst, .newestFirst: "Remove order"
        }
    }

    /// The first or last time's choices.
    enum OccasionChoice: String, CaseIterable, Sendable {
        case first, last, all

        init(_ order: SearchOrder) {
            self = order == .first ? .first : order == .last ? .last : .all
        }

        var title: String {
            switch self {
            case .first: "First time"
            case .last: "Last time"
            case .all: "All times"
            }
        }
    }

    /// Why a place chip found no place, where nothing can be looked up instead (a name no saved place goes by, home).
    static func notFound(_ reason: PlaceNotFound) -> String? {
        switch reason {
        case .notSaved: "None of your saved places goes by this name. Save one from a moment to search it by name."
        case .choseNoHome: "You chose No home. Choose one in Settings › Saved places."
        case .noHome: "Lahza hasn’t worked out your home yet. Save it from a photo."
        default: nil
        }
    }

    static func remove(_ event: EventKind) -> String {
        switch event {
        case .trip: "Remove trips"
        case .abroad: "Remove trips abroad"
        }
    }

    /// "Search Apple Maps for “Al-Nakheel Park”".
    static func searchAppleMaps(_ words: String) -> String { "Search Apple Maps for “\(words)”" }

    /// Why the Apple Maps search asked for wasn't made.
    static func appleMapsMissed(_ reason: PlaceNotFound) -> String {
        switch reason {
        case .offline: "Couldn’t reach Apple Maps offline. Try again when you’re online."
        case .mapsBusy: "Apple Maps is busy. Try again in a few minutes."
        case .appleMapsOff: "Apple Maps place names are off in Settings › Search index."
        default: "Couldn’t reach Apple Maps. Try again in a few minutes."
        }
    }

    /// "Tight · 200 m".
    static func radius(_ choice: PlaceRadius.Choice, _ radius: PlaceRadius) -> String {
        let name = switch choice {
        case .tight: "Tight"
        case .normal: "Normal"
        case .wide: "Wide"
        }
        return "\(name) · \(SearchFormat.distance(radius.metres(choice)))"
    }

    /// "Photos within 400 m", doubled when near.
    static func within(_ radius: PlaceRadius) -> String {
        "Photos within \(SearchFormat.distance((radius.chosen ?? radius.natural) * (radius.near ? 2 : 1)))"
    }

    static func remove(_ kind: SlotKind) -> String {
        switch kind {
        case .place: "Remove place"
        case .time: "Remove dates"
        case .media: "Remove photo type"
        case .event: remove(.trip)
        default: removeWords
        }
    }

    /// The part-of-day choices; noon, late night and tonight show none of them.
    enum PartOfDayChoice: String, CaseIterable, Sendable {
        case any, morning, afternoon, evening, night

        init?(_ part: PartOfDay?) {
            switch part {
            case nil: self = .any
            case .morning: self = .morning
            case .afternoon: self = .afternoon
            case .evening: self = .evening
            case .night: self = .night
            case .noon, .lateNight, .tonight: return nil
            }
        }

        var part: PartOfDay? {
            switch self {
            case .any: nil
            case .morning: .morning
            case .afternoon: .afternoon
            case .evening: .evening
            case .night: .night
            }
        }

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    enum MediaChoice: String, CaseIterable, Sendable {
        case all, photos, videos

        init(_ kinds: Set<MediaKind>) {
            self = kinds == [.photo] ? .photos : kinds == [.video] ? .videos : .all
        }

        var kinds: Set<MediaKind> {
            switch self {
            case .all: []
            case .photos: [.photo]
            case .videos: [.video]
            }
        }

        var title: String {
            switch self {
            case .all: "Photos & videos"
            case .photos: "Photos"
            case .videos: "Videos"
            }
        }
    }

    // MARK: Custom dates

    /// Gregorian whatever the iPhone's calendar (dates follow its region, decision E9).
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .current
        return calendar
    }()

    /// Noon of a moment day, for a date picker.
    static func date(_ day: Int32) -> Date {
        let civil = LocalTime.civil(day: day)
        return calendar.date(from: DateComponents(year: civil.year, month: civil.month, day: civil.day, hour: 12)) ?? Date()
    }

    /// The days the pickers show, as a range the rules parser reads back ("between 1 June 2025 and 30 June 2025").
    static func range(from: Date, to: Date) -> TimeExpression {
        func civil(_ date: Date) -> TimeExpression {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return .date(day: parts.day ?? 1, month: parts.month ?? 1, year: parts.year)
        }
        return .range(from: civil(from), to: civil(to))
    }
}
