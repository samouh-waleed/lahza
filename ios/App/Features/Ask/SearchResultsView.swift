import LZDesign
import LZIndex
import LZSearch
import SwiftUI

/// Ask's results (search spec §7.1): what the query was understood as (each chip opens its editor), the picker for an
/// ambiguous place, the counts and what was searched, then moment cards in sections (trips under their headers) or a
/// grid of every photo, or why nothing matched with taps that widen the search. A free search ends with how many older
/// photos also match and the unlock. While it runs, skeleton cards; when it fails, a notice to try again. A grid tile
/// opens the viewer.
struct SearchResultsView: View {
    /// Searches typed words (an example search).
    let search: (String) -> Void
    /// Scrolls the screen to a row or tile (switching layouts keeps the place).
    let scrollTo: (String) -> Void
    @Environment(AppModel.self) private var model
    /// The chip whose editor is open (the sheet lives here, so it stays while an edit searches again).
    @State private var editing: EditedSlot?
    /// The viewer, opened from a grid tile.
    @State private var viewing: ViewerSession?

    var body: some View {
        Group { content }
            // Cards and moment detail name the country away from home, and trips by their rows.
            .task(id: model.index.version) { await model.moments.load() }
            .sheet(item: $editing) { ChipEditorSheet(slotID: $0.id) }
            .fullScreenCover(item: $viewing) { AssetViewer(session: $0) }
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
            ResultsList(result: result, showsWeaker: store.request?.showWeaker ?? false, edit: edit, scrollTo: scrollTo) { viewing = $0 }
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
        case .card(let card): Self.cardID(card.id)
        }
    }

    /// A card's row id.
    static func cardID(_ key: MomentKey) -> String { "c-\(key.day)-\(key.startUTC)" }

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

/// The chips, notices and picker, the header, Moments | Grid (it stays at the top while the results scroll), the
/// sections as cards or a grid, Show weaker, the older matches a free search leaves out and the coverage notes.
/// Switching layouts keeps the result; scrolled into the results, the other layout opens at the same photos. While the
/// grid scrolls, the next 60 thumbnails are prepared.
private struct ResultsList: View {
    let result: SearchResult
    let showsWeaker: Bool
    let edit: (Int) -> Void
    let scrollTo: (String) -> Void
    let view: (ViewerSession) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @State private var showsUnknown = false
    @State private var anchor = ResultsAnchor()
    @State private var width: CGFloat = 0
    @State private var prefetch = GridPrefetch()

    var body: some View {
        let grid = ResultGrid(result, showsUnknown: showsUnknown)
        let columns = GridRow.columns(width: width)
        // At accessibility sizes the switch is a tall list: it scrolls away with the header.
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: dynamicTypeSize.isAccessibilitySize ? [] : [.sectionHeaders]) {
            QueryTop(result: result, edit: edit)
                .padding(.bottom, LZSpace.sm + LZSpace.md)
            ResultsHeader(result: result)
                .padding(.bottom, LZSpace.xs)
                .onScrollVisibilityChange(threshold: 0.05) { anchor.isHeaderVisible = $0 }
            Section {
                switch model.search.layout {
                case .moments:
                    ForEach(ResultRow.rows(result.sections, showsUnknown: showsUnknown)) { row in
                        ResultRowView(row: row, result: result, showsUnknown: $showsUnknown)
                            .padding(.top, LZSpace.md)
                            .onScrollVisibilityChange(threshold: 0.3) { visible in
                                if case .card(let card) = row { anchor.card(card.id, isVisible: visible) }
                            }
                            // A row dropped after a jump never says it left the screen.
                            .onDisappear { if case .card(let card) = row { anchor.card(card.id, isVisible: false) } }
                    }
                case .grid:
                    ForEach(GridRow.rows(grid, columns: columns)) { row in
                        GridRowView(row: row, columns: columns, showsUnknown: $showsUnknown) { tile in
                            view(ViewerSession(items: ViewerItem.items(grid, result: result), start: tile.position))
                        }
                        .onScrollVisibilityChange(threshold: 0.5) { visible in
                            if case .tiles(let tiles) = row, let first = tiles.first { anchor.tile(first.position, isVisible: visible) }
                        }
                        .onAppear {
                            if case .tiles(let tiles) = row, let last = tiles.last { cacheAhead(of: last.position, in: grid) }
                        }
                        .onDisappear { if case .tiles(let tiles) = row, let first = tiles.first { anchor.tile(first.position, isVisible: false) } }
                    }
                }
                if result.weakerCount > 0 {
                    ShowWeakerButton(count: result.weakerCount, isShown: showsWeaker)
                        .padding(.top, LZSpace.md)
                }
                LockedResultsRow(count: result.lockedCount)
                    .padding(.top, LZSpace.sm + LZSpace.md)
                if !result.coverage.notes.isEmpty {
                    VStack(alignment: .leading, spacing: LZSpace.xs) {
                        ForEach(result.coverage.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .lzText(.caption)
                                .foregroundStyle(.lz(.muted))
                        }
                    }
                    .padding(.top, LZSpace.md + LZSpace.md)
                }
            } header: {
                LZSegmented(AskCopy.layoutLabel, options: SearchStore.ResultsLayout.allCases.map { LZChipOption($0, title: AskCopy.layoutName($0)) },
                            selection: layoutBinding(grid, columns: columns))
                    .padding(.vertical, LZSpace.sm)
                    .background(.lz(.bg))
                    .accessibilityIdentifier("ask-layout")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: model.search.layout) { stopCaching() }
        .onChange(of: result.id) { stopCaching() }
        .onDisappear { stopCaching() }
        .lzPage()
        .padding(.vertical, LZSpace.lg)
        .accessibilityIdentifier("ask-results")
    }

    /// Moments | Grid: remembers the choice; scrolled into the results, the new layout opens at the photos on screen.
    private func layoutBinding(_ grid: ResultGrid, columns: Int) -> Binding<SearchStore.ResultsLayout> {
        Binding(get: { model.search.layout }, set: { layout in
            guard layout != model.search.layout else { return }
            let target = anchor.target(for: layout, result: result, grid: grid, columns: columns, showsUnknown: showsUnknown)
            anchor.reset()
            model.search.setLayout(layout)
            guard let target else { return }
            Task {
                // Once the new layout is laid out; then again, once the rows around the target are measured (rows not
                // laid out yet are estimated, so the first scroll can land short).
                try? await Task.sleep(for: .milliseconds(60))
                scrollTo(target)
                try? await Task.sleep(for: .milliseconds(150))
                scrollTo(target)
            }
        })
    }

    // MARK: Thumbnails ahead

    /// A tile's side in pixels (what each thumbnail asks for, so the prepared ones are used).
    private var tilePixels: Int { Int((GridRow.side(width: width) * displayScale).rounded(.up)) }

    private func cacheAhead(of position: Int, in grid: ResultGrid) {
        guard width > 0 else { return }
        let change = prefetch.appeared(position, total: grid.tiles.count)
        let ids = { (range: Range<Int>) in grid.tiles[range].map(\.hit.localID) }
        for range in change.stop { model.images.stopCaching(ids(range), side: tilePixels) }
        for range in change.start { model.images.startCaching(ids(range), side: tilePixels) }
    }

    /// The grid left the screen, or its result changed: nothing is prepared any more (only the grid prepares).
    private func stopCaching() {
        if prefetch.reset() != nil { model.images.stopAll() }
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
