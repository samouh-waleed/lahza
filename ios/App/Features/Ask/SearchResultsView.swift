import LZDesign
import LZIndex
import LZSearch
import SwiftUI

/// Ask's results (search spec §7.1): what the query was understood as, the picker for an ambiguous place, the counts
/// and what was searched, then moment cards in sections (trips under their headers), or why nothing matched with taps
/// that widen the search. While it runs, skeleton cards; when it fails, a notice to try again.
struct SearchResultsView: View {
    /// Searches typed words (an example search).
    let search: (String) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Group { content }
            // Cards and moment detail name the country away from home, and trips by their rows.
            .task(id: model.index.version) { await model.moments.load() }
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
            ResultsList(result: result, showsWeaker: store.request?.showWeaker ?? false)
        case .noMatch(let result):
            NoMatchView(result: result, search: search)
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

/// The chips, notices and picker, the header, the sections, Show weaker and the coverage notes.
private struct ResultsList: View {
    let result: SearchResult
    let showsWeaker: Bool
    @Environment(AppModel.self) private var model
    @State private var showsUnknown = false

    var body: some View {
        let today = MomentCopy.today(now: model.dependencies.clock.now, zone: model.dependencies.deviceTimeZone())
        let home = model.moments.homeCountryCode
        let zone = model.dependencies.deviceTimeZone()
        LazyVStack(alignment: .leading, spacing: LZSpace.md) {
            QueryTop(result: result)
                .padding(.bottom, LZSpace.sm)
            ResultsHeader(result: result)
            ForEach(ResultRow.rows(result.sections, showsUnknown: showsUnknown)) { row in
                switch row {
                case .section(let section):
                    sectionHeader(section)
                        .padding(.top, LZSpace.lg)
                case .trip(let group, _):
                    SectionHeader(group.title, eyebrow: AskCopy.tripEyebrow, caption: MomentCopy.tripCaption(group.trip),
                                  actionTitle: AskCopy.seeTrip) {
                        model.open(.trip(TripRef(startDay: group.trip.startDay, origin: .ask)))
                    }
                    .padding(.top, LZSpace.sm)
                    .accessibilityIdentifier("result-trip-\(group.trip.startDay)")
                case .card(let card):
                    MomentCardView(card: card, today: today, homeCountry: home, deviceZone: zone) {
                        model.open(.moment(MomentRef(key: card.id, origin: .ask, searchID: result.id)))
                    }
                }
            }
            if result.weakerCount > 0 {
                LZButton(showsWeaker ? AskCopy.hideWeaker : AskCopy.showWeaker(result.weakerCount), role: .quiet) {
                    model.search.setShowWeaker(!showsWeaker)
                }
                .padding(.top, LZSpace.sm)
                .accessibilityIdentifier("ask-show-weaker")
            }
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

    @ViewBuilder
    private func sectionHeader(_ section: ResultSection) -> some View {
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
    }
}

/// What the query was understood as, the notice about words left out, and the picker for an ambiguous place.
private struct QueryTop: View {
    let result: SearchResult
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.lg) {
            let chips = QueryChipModel.chips(result.query)
            if !chips.isEmpty { UnderstoodAsRow(chips: chips) }
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
            Text(result.coverage.caption)
                .lzText(.caption)
                .foregroundStyle(.lz(.muted))
            if let header = result.coverage.header {
                Label(header, systemImage: "hourglass")
                    .lzText(.caption)
                    .foregroundStyle(.lz(.muted))
                    .accessibilityIdentifier("ask-partial")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask-results-header")
    }
}

// MARK: No match

/// Why nothing matched (the slot that found nothing), with taps that widen the search and their counts. Words Lahza
/// can't search yet get the library's example searches instead. Photos without a location that match everything
/// else still show under Location unknown.
private struct NoMatchView: View {
    let result: SearchResult
    let search: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var showsUnknown = false

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.lg) {
            let chips = QueryChipModel.chips(result.query)
            if !chips.isEmpty { UnderstoodAsRow(chips: chips) }
            if let noMatch = result.noMatch {
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
            let unknown = result.sections.filter { $0.tier == .locationUnknown }
            if !unknown.isEmpty {
                let today = MomentCopy.today(now: model.dependencies.clock.now, zone: model.dependencies.deviceTimeZone())
                ForEach(ResultRow.rows(unknown, showsUnknown: showsUnknown)) { row in
                    switch row {
                    case .section(let section):
                        SectionHeader(section.title, caption: section.caption, actionTitle: showsUnknown ? AskCopy.hide : AskCopy.show) {
                            showsUnknown.toggle()
                        }
                        .padding(.top, LZSpace.lg)
                        .accessibilityIdentifier("result-section-\(section.tier)")
                    case .trip(let group, _):
                        SectionHeader(group.title, eyebrow: AskCopy.tripEyebrow, caption: MomentCopy.tripCaption(group.trip))
                    case .card(let card):
                        MomentCardView(card: card, today: today, homeCountry: model.moments.homeCountryCode,
                                       deviceZone: model.dependencies.deviceTimeZone()) {
                            model.open(.moment(MomentRef(key: card.id, origin: .ask, searchID: result.id)))
                        }
                    }
                }
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
