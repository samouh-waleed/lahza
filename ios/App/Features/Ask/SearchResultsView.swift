import LZDesign
import LZIndex
import LZSearch
import SwiftUI

/// Ask's results (search spec §7.1): what the query was understood as (each chip opens its editor), the picker for an
/// ambiguous place, the counts and what was searched, then moment cards in sections (trips under their headers), or
/// why nothing matched with taps that widen the search. A free search ends with how many older photos also match and
/// the unlock. While it runs, skeleton cards; when it fails, a notice to try again.
struct SearchResultsView: View {
    /// Searches typed words (an example search).
    let search: (String) -> Void
    @Environment(AppModel.self) private var model
    /// The chip whose editor is open (the sheet lives here, so it stays while an edit searches again).
    @State private var editing: EditedSlot?

    var body: some View {
        Group { content }
            // Cards and moment detail name the country away from home, and trips by their rows.
            .task(id: model.index.version) { await model.moments.load() }
            .sheet(item: $editing) { ChipEditorSheet(slotID: $0.id) }
    }

    private func edit(_ slot: Int) {
        editing = EditedSlot(id: slot)
    }

    @ViewBuilder private var content: some View {
        let store = model.search
        switch store.state {
        case .idle:
            EmptyView()
        case .understanding, .searching, .lookingUpPlace:
            SearchLoadingView(state: store.state, parsed: store.parsed)
                .lzPage()
                .padding(.vertical, LZSpace.lg)
        case .results(let result):
            ResultsList(result: result, showsWeaker: store.request?.showWeaker ?? false, edit: edit)
        case .noMatch(let result):
            NoMatchView(result: result, showsWeaker: store.request?.showWeaker ?? false, search: search, edit: edit)
                .lzPage()
                .padding(.vertical, LZSpace.lg)
        case .failed(let message):
            Notice(.warn, message: message, actionTitle: AskCopy.tryAgain) { store.submit(store.text) }
                .lzPage()
                .padding(.vertical, LZSpace.lg)
                .accessibilityIdentifier("ask-search-failed")
        }
    }
}

// MARK: Results

/// One row of the results list: rows load lazily, so a search with thousands of moments stays smooth.
nonisolated enum ResultRow: Identifiable, Hashable {
    case section(ResultSection)
    case trip(TripGroup, tier: Tier)
    case card(MomentCard)

    var id: String {
        switch self {
        case .section(let section): "s-\(section.tier)"
        case .trip(let group, let tier): "t-\(tier)-\(group.trip.startDay)"
        case .card(let card): "c-\(card.id.day)-\(card.id.startUTC)"
        }
    }

    /// The result's sections as rows: each section's header, then its trips' headers and cards in order. Location
    /// unknown lists its cards only when opened.
    static func rows(_ sections: [ResultSection], showsUnknown: Bool) -> [ResultRow] {
        var rows: [ResultRow] = []
        for section in sections {
            rows.append(.section(section))
            guard section.tier != .locationUnknown || showsUnknown else { continue }
            for group in section.groups {
                switch group {
                case .moment(let card):
                    rows.append(.card(card))
                case .trip(let trip):
                    rows.append(.trip(trip, tier: section.tier))
                    rows += trip.cards.map(ResultRow.card)
                }
            }
        }
        return rows
    }
}

/// The chips, notices and picker, the header, the sections, Show weaker, the older matches a free search leaves out
/// and the coverage notes.
private struct ResultsList: View {
    let result: SearchResult
    let showsWeaker: Bool
    let edit: (Int) -> Void
    @State private var showsUnknown = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: LZSpace.md) {
            QueryTop(result: result, edit: edit)
                .padding(.bottom, LZSpace.sm)
            ResultsHeader(result: result)
            ForEach(ResultRow.rows(result.sections, showsUnknown: showsUnknown)) { row in
                ResultRowView(row: row, result: result, showsUnknown: $showsUnknown)
            }
            if result.weakerCount > 0 {
                ShowWeakerButton(count: result.weakerCount, isShown: showsWeaker)
            }
            LockedResultsRow(count: result.lockedCount)
                .padding(.top, LZSpace.sm)
            if !result.coverage.notes.isEmpty {
                VStack(alignment: .leading, spacing: LZSpace.xs) {
                    ForEach(result.coverage.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .lzText(.caption)
                            .foregroundStyle(.lz(.muted))
                    }
                }
                .padding(.top, LZSpace.md)
            }
        }
        .lzPage()
        .padding(.vertical, LZSpace.lg)
        .accessibilityIdentifier("ask-results")
    }
}

/// One row of a result: a section's header (Location unknown opens and closes), a trip's header, or a moment card.
private struct ResultRowView: View {
    let row: ResultRow
    let result: SearchResult
    @Binding var showsUnknown: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        switch row {
        case .section(let section):
            Group {
                if section.tier == .locationUnknown {
                    SectionHeader(section.title, caption: section.caption, actionTitle: showsUnknown ? AskCopy.hide : AskCopy.show) {
                        showsUnknown.toggle()
                    }
                } else {
                    SectionHeader(section.title, caption: section.caption)
                }
            }
            .accessibilityIdentifier("result-section-\(section.tier)")
            .padding(.top, LZSpace.lg)
        case .trip(let group, _):
            SectionHeader(group.title, eyebrow: AskCopy.tripEyebrow, caption: MomentCopy.tripCaption(group.trip), actionTitle: AskCopy.seeTrip) {
                model.open(.trip(TripRef(startDay: group.trip.startDay, origin: .ask)))
            }
            .padding(.top, LZSpace.sm)
            .accessibilityIdentifier("result-trip-\(group.trip.startDay)")
        case .card(let card):
            let zone = model.dependencies.deviceTimeZone()
            MomentCardView(card: card, today: MomentCopy.today(now: model.dependencies.clock.now, zone: zone), homeCountry: model.moments.homeCountryCode,
                           deviceZone: zone) {
                model.open(.moment(MomentRef(key: card.id, origin: .ask, searchID: result.id)))
            }
        }
    }
}

/// "Show 12 weaker matches" / "Hide weaker matches".
private struct ShowWeakerButton: View {
    let count: Int
    let isShown: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        LZButton(isShown ? AskCopy.hideWeaker : AskCopy.showWeaker(count), role: .quiet) {
            model.search.setShowWeaker(!isShown)
        }
        .padding(.top, LZSpace.sm)
        .accessibilityIdentifier("ask-show-weaker")
    }
}

/// What the query was understood as (a chip opens its editor), the notice about words left out, and the picker for an
/// ambiguous place.
private struct QueryTop: View {
    let result: SearchResult
    let edit: (Int) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.lg) {
            let chips = QueryChipModel.chips(result.query)
            if !chips.isEmpty { UnderstoodAsRow(chips: chips, edit: edit) }
            if let notice = result.unsupportedNotice {
                Notice(.info, message: notice)
                    .accessibilityIdentifier("ask-unsupported-notice")
            }
            if let picker = result.query.picker {
                PlacePickerRow(picker: picker) { model.search.choose($0) }
            }
        }
    }
}

/// "10 moments", "82 photos · 3 videos", what was searched, and while the first build runs, how far it has read.
private struct ResultsHeader: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.xs) {
            VStack(alignment: .leading, spacing: LZSpace.xs) {
                // The noun goes under the number at accessibility text sizes.
                LZAdaptiveStack(spacing: LZSpace.sm, verticalAlignment: .firstTextBaseline) {
                    LZNumeral(result.totals.moments.formatted(), role: .numeral)
                        .foregroundStyle(.lz(.ink))
                    Text(AskCopy.momentsNoun(result.totals.moments))
                        .lzText(.body)
                        .foregroundStyle(.lz(.muted))
                }
                Text(MomentCopy.counts(photos: result.totals.photos, videos: result.totals.videos))
                    .lzText(.subheadline)
                    .foregroundStyle(.lz(.ink))
                CoverageLines(coverage: result.coverage)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ask-results-header")
            if result.coverage.isLimited { ChooseMoreButton() }
        }
    }
}

/// What was searched ("Searching the 40 photos you’ve shared"), and while the first build runs, how far it has read.
private struct CoverageLines: View {
    let coverage: Coverage

    var body: some View {
        Text(coverage.caption)
            .lzText(.caption)
            .foregroundStyle(.lz(.muted))
            .accessibilityIdentifier("ask-coverage")
        if let header = coverage.header {
            Label(header, systemImage: "hourglass")
                .lzText(.caption)
                .foregroundStyle(.lz(.muted))
                .accessibilityIdentifier("ask-partial")
        }
    }
}

/// Under limited access: shares more photos with Lahza (the system's picker), as the library card does.
private struct ChooseMoreButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LZButton(AskCopy.chooseMore, role: .quiet, size: .small) {
            Task { await model.chooseLimitedPhotos() }
        }
        .accessibilityIdentifier("ask-choose-more")
    }
}

// MARK: No match

/// Why nothing matched (the slot that found nothing), with taps that widen the search and their counts. When no tap is
/// left, the library's example searches follow, so there is always a next tap. A free search whose matches are all
/// older says so and puts the unlock right under it. While the first build reads, or under limited access, it says
/// what was searched, so "No photos" isn't taken as final. Photos without a location that match everything else still
/// show under Location unknown, and weaker matches behind Show weaker.
private struct NoMatchView: View {
    let result: SearchResult
    let showsWeaker: Bool
    let search: (String) -> Void
    let edit: (Int) -> Void
    @Environment(AppModel.self) private var model
    @State private var showsUnknown = false

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.lg) {
            QueryTop(result: result, edit: edit)
            if let noMatch = result.noMatch, noMatch.kind == .onlyEarlier {
                // Not "nothing": the photos are there, older than a free search covers.
                EmptyState(noMatch.headline, message: AskCopy.onlyEarlierDetail, systemImage: AskCopy.noMatchSymbol(noMatch.kind), tone: .neutral)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ask-no-match")
                LockedResultsRow(count: result.lockedCount)
            } else if let noMatch = result.noMatch {
                EmptyState(noMatch.headline, message: noMatch.detail ?? "", systemImage: AskCopy.noMatchSymbol(noMatch.kind), tone: .neutral)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ask-no-match")
                if noMatch.kind == .placeEmpty, !noMatch.offers.isEmpty {
                    // The library's countries, as chips: there can be several.
                    GlassEffectContainer(spacing: LZSpace.sm) {
                        LZFlowLayout(spacing: LZSpace.sm, lineSpacing: 0) {
                            ForEach(noMatch.offers) { offer in
                                LZChip(AskCopy.offer(offer), systemImage: "mappin", isSelected: false) { model.search.widen(offer) }
                                    .accessibilityLabel(AskCopy.spokenOffer(offer))
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ask-offers")
                } else if !noMatch.offers.isEmpty {
                    VStack(spacing: LZSpace.sm) {
                        ForEach(noMatch.offers) { offer in
                            LZButton(AskCopy.offer(offer), role: .secondary) { model.search.widen(offer) }
                                .accessibilityLabel(AskCopy.spokenOffer(offer))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ask-offers")
                }
                if !noMatch.examples.isEmpty {
                    ExampleSearchesRow(examples: noMatch.examples, search: search)
                        .padding(.top, LZSpace.sm)
                }
            }
            if result.coverage.isPartial || result.coverage.isLimited {
                VStack(alignment: .leading, spacing: LZSpace.xs) {
                    CoverageLines(coverage: result.coverage)
                    if result.coverage.isLimited { ChooseMoreButton() }
                }
            }
            if !result.sections.isEmpty || result.weakerCount > 0 {
                VStack(alignment: .leading, spacing: LZSpace.md) {
                    ForEach(ResultRow.rows(result.sections, showsUnknown: showsUnknown)) { row in
                        ResultRowView(row: row, result: result, showsUnknown: $showsUnknown)
                    }
                    if result.weakerCount > 0 {
                        ShowWeakerButton(count: result.weakerCount, isShown: showsWeaker)
                    }
                }
            }
            if result.noMatch?.kind != .onlyEarlier {
                LockedResultsRow(count: result.lockedCount)
            }
        }
    }
}

// MARK: Loading

/// While a search runs: the chips as typed (the place spins while it is looked up), then, if it takes more than a
/// moment, what it is doing and skeleton cards.
private struct SearchLoadingView: View {
    let state: SearchStore.State
    let parsed: ParsedQuery?
    @State private var showsSkeleton = false

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.lg) {
            let lookingUp: String? = if case .lookingUpPlace(let name) = state { name } else { nil }
            if let parsed, !parsed.slots.isEmpty {
                UnderstoodAsRow(chips: QueryChipModel.chips(parsed, lookingUpPlace: lookingUp != nil))
            }
            if showsSkeleton {
                Text(lookingUp.map(AskCopy.lookingUp) ?? AskCopy.searching)
                    .lzText(.subheadline)
                    .foregroundStyle(.lz(.muted))
                ForEach(0..<3, id: \.self) { _ in
                    PaperCard(style: .raised, padding: LZSpace.md) {
                        VStack(alignment: .leading, spacing: LZSpace.md) {
                            HStack(spacing: 3) {
                                ForEach(0..<MomentCardView.tiles, id: \.self) { _ in
                                    SkeletonBlock(radius: LZRadius.xs).aspectRatio(1, contentMode: .fit)
                                }
                            }
                            SkeletonText(lines: 2)
                                .padding(.horizontal, LZSpace.xs)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .accessibilityIdentifier("ask-searching")
        .task {
            // A search from the index takes a fraction of a second: no skeleton flashes for it.
            try? await Task.sleep(for: .milliseconds(300))
            showsSkeleton = true
        }
    }
}
