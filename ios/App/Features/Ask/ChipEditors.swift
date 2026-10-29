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
    /// Words Lahza can't search yet, a second place or dates it couldn't use: why, and Remove.
    case unsupported(String)

    init(_ slot: ResolvedSlot) {
        switch (slot.resolution, slot.slot.value) {
        case (.place(let resolution), _): self = .place(resolution)
        case (.time(.constraint(let constraint)), .time(let expression)): self = .time(expression, constraint)
        case (.media(let filter), _): self = .media(filter)
        case (.event(let event), _): self = .event(event)
        default: self = .unsupported(AskCopy.unsupportedExplanation(slot.slot.kind))
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
                    SheetHeader(slot.isSupported ? slot.chip : AskCopy.notYet(slot.chip, kind: slot.slot.kind),
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
        switch ChipEditorKind(slot) {
        case .place(let resolution):
            PlaceEditor(slot: slot, query: query, resolution: resolution, remove: remove)
        case .time(let expression, let constraint):
            let today = MomentCopy.today(now: model.dependencies.clock.now, zone: model.dependencies.deviceTimeZone())
            TimeEditor(slot: slot, expression: expression, days: constraint.days ?? (today - 29)...today, remove: remove)
                .id(slot.chip)
        case .media(let filter):
            MediaEditor(slot: slot, filter: filter, remove: remove)
        case .event:
            EditorExplanation(text: ChipEditorCopy.tripsExplanation)
            RemoveButton(title: ChipEditorCopy.remove(.event), action: remove)
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
/// and for an area its radius and "near".
private struct PlaceEditor: View {
    let slot: ResolvedSlot
    let query: ResolvedQuery
    let resolution: PlaceResolution
    let remove: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let candidates = Array(resolution.candidates.prefix(ChipEditorCopy.maxCandidates))
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
            if !asked || isSearching {
                LZRowGroup {
                    ListRow(ChipEditorCopy.searchAppleMaps(words), systemImage: "magnifyingglass", isLoading: asked) {
                        model.search.apply([.searchAppleMaps(slot: slot.id)])
                    }
                    .accessibilityIdentifier("chip-editor-apple-maps")
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

    /// The words to look up on Apple Maps, while this search hasn't asked it and place names are on.
    private var appleMapsWords: String? {
        guard model.index.appleMapsNames, !query.searchedAppleMaps, case .place(let place) = slot.slot.value, place.words != nil else { return nil }
        return query.typedWords(slot: slot.id)
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
                model.search.apply([.replaceTime(slot: slot.id, ChipEditorCopy.range(from: from, to: max(from, to)))])
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
    static let tripsExplanation = "Photos from your trips: two or more days in a row away from home."
    static let removeWords = "Remove these words"

    /// "Search Apple Maps for “Al-Nakheel Park”".
    static func searchAppleMaps(_ words: String) -> String { "Search Apple Maps for “\(words)”" }

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
        case .event: "Remove trips"
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
