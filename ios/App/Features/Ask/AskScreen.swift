import LZBilling
import LZCore
import LZDesign
import LZIndex
import LZLibrary
import LZSearch
import SwiftUI

/// Ask: describe a moment and get back the matching photos. The field searches the index (places, dates, photo
/// types); before a search, the library's example searches, the index's progress, the library at a glance once it is
/// built, the library card when photo access is missing or limited, and the privacy promise. A search replaces them
/// with its results. It never fakes results.
struct AskScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var submitted: String?

    private static let top = "ask-top"

    var body: some View {
        let access = model.photoAccess.access
        let status = model.index.status
        let state = AskState(access: access, status: status)
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id(Self.top)
                if state == .deleted {
                    VStack(alignment: .leading, spacing: LZSpace.lg) {
                        // The field stays, so a search typed here says why nothing happens.
                        if submitted != nil { Notice(.info, message: AskCopy.needsIndex) }
                        EmptyState(AskCopy.deletedTitle, message: AskCopy.deletedBody, systemImage: "magnifyingglass",
                                   actionTitle: IndexCopy.buildIndex) { model.index.buildAgain() }
                    }
                    .lzPage()
                    .accessibilityIdentifier("ask-deleted")
                } else if submitted != nil, state != .noAccess, model.search.state != .idle {
                    SearchResultsView(search: { search($0, proxy: proxy) }, scrollTo: { proxy.scrollTo($0, anchor: .top) })
                } else {
                    home(state, status: status, access: access, proxy: proxy)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(.lz(.bg))
            .navigationTitle(AskCopy.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: AskCopy.prompt)
            .onSubmit(of: .search) { search(query, proxy: proxy) }
            .onChange(of: query) { _, value in
                if value.isEmpty {
                    submitted = nil
                    model.search.clear()
                } else if submitted == nil {
                    model.search.preview(value)
                }
            }
            // A search started elsewhere (-LZQuery), or the words of edited chips, show in the field; removing the last
            // chip empties it.
            .onChange(of: model.search.text) { _, text in
                guard !text.isEmpty else {
                    if model.search.state == .idle { query = "" }
                    return
                }
                if text != query { query = text }
                submitted = text
                proxy.scrollTo(Self.top, anchor: .top)
            }
            // A search typed before Lahza could read the library runs once it can.
            .onChange(of: access.canRead) { _, canRead in
                if canRead, let submitted, model.search.state == .idle { model.search.submit(submitted) }
            }
            .task(id: model.index.version) {
                if model.search.examples.isEmpty { model.search.refreshExamples(after: .zero) }
            }
        }
        .accessibilityIdentifier("ask")
    }

    /// Before a search: the title, the chips of what is being typed, the examples and the library's cards.
    private func home(_ state: AskState, status: IndexStatus, access: PhotoAccess, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: LZSpace.xl) {
            VStack(alignment: .leading, spacing: LZSpace.sm) {
                Text(AskCopy.title).lzText(.displayLarge).foregroundStyle(.lz(.ink))
                Text(AskCopy.subtitle).lzText(.body).foregroundStyle(.lz(.muted))
            }
            if submitted != nil, !access.canRead {
                Notice(.info, message: AskCopy.needsAccess)
            } else if !query.isEmpty, let parsed = model.search.parsed, !parsed.slots.isEmpty {
                UnderstoodAsRow(chips: QueryChipModel.chips(parsed))
            }
            if case .ready = state, !model.search.examples.isEmpty {
                ExampleSearchesRow(examples: model.search.examples) { search($0, proxy: proxy) }
            }
            content(state, status: status, access: access)
            Label(AskCopy.privacy, systemImage: "lock.shield")
                .lzText(.caption)
                .foregroundStyle(.lz(.muted))
        }
        .lzPage()
        .padding(.vertical, LZSpace.lg)
    }

    private func search(_ text: String, proxy: ScrollViewProxy) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != query { query = trimmed }
        submitted = trimmed.isEmpty ? nil : trimmed
        proxy.scrollTo(Self.top, anchor: .top)
        guard !trimmed.isEmpty, model.photoAccess.access.canRead else { return }
        model.search.submit(trimmed)
    }

    @ViewBuilder
    private func content(_ state: AskState, status: IndexStatus, access: PhotoAccess) -> some View {
        switch state {
        case .noAccess:
            LibraryStatusCard()
        case .indexing(let phase):
            IndexingCard(phase: phase)
            if access == .limited { LibraryStatusCard() }
        case .ready(let summary):
            VStack(alignment: .leading, spacing: LZSpace.md) {
                LibrarySummaryCard(summary: summary, isLimited: status.isLimited)
                if let footnote = AskCopy.placeNamesFootnote(status.placeNames) {
                    Label(footnote, systemImage: "mappin.and.ellipse")
                        .lzText(.caption)
                        .foregroundStyle(.lz(.muted))
                        .accessibilityIdentifier("ask-place-names")
                }
            }
            if access == .limited { LibraryStatusCard() }
        case .unavailable(let message):
            Notice(.warn, title: message, message: IndexCopy.unavailableDetail)
        case .deleted:
            EmptyView()
        }
    }
}

/// What Ask shows for the photo access and the index status (search spec §7.1).
nonisolated enum AskState: Equatable {
    /// No readable access: the library card, and a notice on submit.
    case noAccess
    /// The first build: reading (with progress), preparing or organizing.
    case indexing(IndexStatus.Phase)
    /// Built (or updating in the background): the summary.
    case ready(LibrarySummary)
    case deleted
    case unavailable(String)

    init(access: PhotoAccess, status: IndexStatus) {
        switch status.phase {
        case .off(.deletedByUser):
            self = .deleted
        case .off(.noAccess):
            self = .noAccess
        case .off(.protectedDataUnavailable):
            self = .unavailable(IndexCopy.headline(status))
        case _ where !access.canRead:
            self = .noAccess
        case .failed(let message):
            self = status.summary.map { .ready($0) } ?? .unavailable(message)
        case .preparing, .reading, .organizing:
            // Later syncs read and organize too; only the first build shows the card.
            if status.isPartial || status.summary == nil {
                self = .indexing(status.phase)
            } else {
                self = .ready(status.summary ?? LibrarySummary())
            }
        case .ready, .paused:
            self = status.summary.map { .ready($0) } ?? .indexing(.preparing)
        }
    }
}

nonisolated enum AskCopy {
    static let navigationTitle = "Ask Lahza"
    static let title = "What do you remember?"
    static let subtitle = "Search by place, date or photo type, like “Dubai last December” or “videos from Eid”."
    static let prompt = "Dubai last December…"
    static let privacy = "Your photos stay on this iPhone."
    static let searching = "Searching your photos…"
    static let needsAccess = "Lahza needs photo access to search."
    static let needsIndex = "Build the search index to search your photos."
    static let deletedTitle = "Search index deleted"
    static let deletedBody = "Build it again to search."

    /// While a typed place is looked up: "Looking up “Sufra Grill”…".
    static func lookingUp(_ place: String) -> String {
        "Looking up “\(place)”…"
    }

    // MARK: Chips and examples

    static let understoodAs = "UNDERSTOOD AS"
    static let tryLabel = "TRY"
    static let notYetSuffix = " · not yet"
    static let notSearchableYet = "not searchable yet"
    static let lookingUpValue = "Looking up"
    static let unsupportedHint = "Explains why it was left out"
    /// On a searched query the pill opens its editor: why, and Remove.
    static let unsupportedEditHint = "Explains why it was left out, and lets you remove it"
    static let editHint = "Edit"
    static let exampleHint = "Searches for it"

    /// "soccer · not yet"; a date Lahza couldn't use keeps its own words ("National day of which country?").
    static func notYet(_ chip: String, kind: SlotKind) -> String {
        kind == .time ? chip : chip + notYetSuffix
    }

    /// What an unsupported chip's tap explains.
    static func unsupportedExplanation(_ kind: SlotKind) -> String {
        switch kind {
        case .people: "Searching for people arrives in a later version."
        case .place: "Lahza searches one place at a time for now."
        case .time: "Lahza couldn’t use these dates. Try one like “last summer” or “Ramadan 2024”."
        default: "Searching what’s in photos, like “soccer” or “sunset”, arrives in a later version."
        }
    }

    /// The slot a chip stands for, for VoiceOver.
    static func slotName(_ kind: SlotKind) -> String {
        switch kind {
        case .place: "Place"
        case .time: "Dates"
        case .media: "Photo type"
        case .event: "Trips"
        case .people: "People"
        case .visual, .text: "What’s in photos"
        }
    }

    /// "Last summer" from "last summer".
    static func capitalized(_ words: String) -> String {
        words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "Al-Nakheel Park · 85".
    static func example(_ example: ExampleSearch) -> String { "\(example.text) · \(example.count.formatted())" }

    /// "Al-Nakheel Park, 85 results".
    static func spokenExample(_ example: ExampleSearch) -> String { "\(example.text), \(MomentCopy.count(example.count, "result"))" }

    /// "Riyadh, 10 photos" for the picker's "Riyadh · 10".
    static func spokenChoice(_ choice: PlacePicker.Choice) -> String {
        "\(choice.candidate.context ?? choice.candidate.subtitle), \(MomentCopy.count(choice.candidate.photoCount, "photo"))"
    }

    // MARK: Results

    static let tryAgain = "Try again"
    /// Under "No matches in the last 12 months.", above the unlock row.
    static let onlyEarlierDetail = BillingCopy.freeDetail
    static let chooseMore = "Choose more"
    static let show = "Show"
    static let hide = "Hide"
    static let tripEyebrow = "TRIP"
    static let seeTrip = "See trip"
    static let hideWeaker = "Hide weaker matches"
    static let noDate = "No date"
    static let layoutLabel = "Show results as"

    /// "Moments" or "Grid".
    static func layoutName(_ layout: SearchStore.ResultsLayout) -> String {
        switch layout {
        case .moments: "Moments"
        case .grid: "Grid"
        }
    }

    /// "moment" or "moments" after the header's number.
    static func momentsNoun(_ count: Int) -> String { count == 1 ? "moment" : "moments" }

    /// "Show 12 weaker matches".
    static func showWeaker(_ count: Int) -> String {
        count == 1 ? "Show 1 weaker match" : "Show \(count.formatted()) weaker matches"
    }

    /// "Dubai, any time · 57".
    static func offer(_ offer: WideningOffer) -> String { "\(offer.label) · \(offer.count.formatted())" }

    /// "Dubai, any time, 57 results".
    static func spokenOffer(_ offer: WideningOffer) -> String { "\(offer.label), \(MomentCopy.count(offer.count, "result"))" }

    static func noMatchSymbol(_ kind: NoMatch.Kind) -> String {
        switch kind {
        case .onlyUnsupported: "eye.slash"
        case .future: "calendar.badge.exclamationmark"
        case .stillReading: "hourglass"
        case .onlyEarlier: "clock.arrow.circlepath"
        case .placeNotFound, .placeEmpty, .onlyBeyondRadius: "mappin.slash"
        default: "magnifyingglass"
        }
    }

    /// A card's day: "Yesterday", "Saturday", "Sat 22 Aug" this year, the full day before; "No date" for undated
    /// photos.
    static func cardTitle(_ card: MomentCard, today: Int32) -> String {
        card.id == MomentCard.noDateKey ? noDate : MomentCopy.recentDay(card.id.day, today: today)
    }

    /// "Al-Nakheel Park · Riyadh · 5:00 – 6:40 PM", with the country away from home and "Athens time" when the zone
    /// isn't this iPhone's; nil without a moment.
    static func cardPlaceAndTime(_ card: MomentCard, homeCountry: String?, deviceZone: TimeZone) -> String? {
        guard let moment = card.moment else { return nil }
        return [MomentCopy.placeLine(moment, homeCountry: homeCountry), MomentCopy.timeSpan(moment), MomentCopy.zoneNote(moment, deviceZone: deviceZone)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A reason pill's tone: caution gold, no evidence neutral, otherwise sage.
    static func tone(_ reason: Reason) -> LZTone {
        switch reason.kind {
        case .caution: .gold
        case .neutral: .neutral
        default: .sage
        }
    }

    /// "Saturday, 22 August 2026, Al-Nakheel Park · Riyadh · 5:00 – 6:40 PM, 8 photos, In Al-Nakheel Park".
    static func spokenCard(_ card: MomentCard, today: Int32, homeCountry: String?, deviceZone: TimeZone) -> String {
        let recent = (0...6).contains(today - card.id.day)
        let day = card.id == MomentCard.noDateKey ? noDate : recent ? cardTitle(card, today: today) : MomentCopy.spokenDay(card.id.day)
        var parts = [day]
        if let line = cardPlaceAndTime(card, homeCountry: homeCountry, deviceZone: deviceZone) { parts.append(line) }
        parts.append(MomentCopy.counts(photos: card.photoCount, videos: card.videoCount))
        parts += card.reasons.map(\.text)
        return parts.joined(separator: ", ")
    }

    // MARK: Indexing card

    static func indexingTitle(_ phase: IndexStatus.Phase) -> String {
        switch phase {
        case .organizing: "Grouping your photos into moments and trips…"
        default: "Getting to know your library"
        }
    }

    /// "12,400 of 31,204".
    static func readProgress(done: Int, total: Int) -> String {
        "\(min(done, total).formatted()) of \(total.formatted())"
    }

    static func indexingCaption(_ phase: IndexStatus.Phase) -> String {
        switch phase {
        case .organizing: "You can search now. Trips appear when Lahza finishes."
        default: "You can search now. Newest photos come first; trips appear when Lahza finishes."
        }
    }

    // MARK: Summary card

    static let summaryEyebrow = "YOUR LIBRARY"
    static let capability = "Searches places, dates and photo types. Searching what’s in photos comes later."

    /// "photos & videos" after the count ("shared" under limited access).
    static func assetsNoun(_ count: Int, isLimited: Bool) -> String {
        let noun = count == 1 ? "photo or video" : "photos & videos"
        return isLimited ? "\(noun) shared" : noun
    }

    /// "225 moments · 6 trips · 5 countries · 2021–2026", or nil before there is a moment.
    static func structure(_ summary: LibrarySummary) -> String? {
        guard summary.moments > 0 else { return nil }
        var parts = [MomentCopy.count(summary.moments, "moment")]
        if summary.trips > 0 { parts.append(MomentCopy.count(summary.trips, "trip")) }
        if summary.countries > 0 { parts.append(summary.countries == 1 ? "1 country" : "\(summary.countries.formatted()) countries") }
        switch (summary.firstYear, summary.lastYear) {
        case let (first?, last?) where first != last: parts.append("\(first)–\(last)")
        case let (year?, _), let (nil, year?): parts.append("\(year)")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    /// "93% have a location", or nil for an empty library.
    static func located(_ summary: LibrarySummary) -> String? {
        guard summary.assets > 0 else { return nil }
        if summary.located == summary.assets { return summary.assets == 1 ? "It has a location" : "All have a location" }
        return "\(IndexCopy.percent(summary.located, of: summary.assets)) have a location"
    }

    /// The Apple Maps line under the card while naming runs or waits; nil once it is done, idle or off. It says
    /// what waits for the internet, since only place names do.
    static func placeNamesFootnote(_ progress: PlaceNameProgress) -> String? {
        switch progress.state {
        case .waitingForNetwork: "Apple Maps place names are waiting for internet"
        case .running, .throttled: IndexCopy.placeNames(progress)
        case .idle, .done, .off, .backgrounded: nil
        }
    }
}
