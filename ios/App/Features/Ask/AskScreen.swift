import LZCore
import LZDesign
import LZIndex
import LZLibrary
import LZSearch
import SwiftUI

/// Ask: describe a moment and get back the matching photos. The field searches the index (places, dates, photo
/// types); around it, the index's progress, the library at a glance once it is built, the library card when photo
/// access is missing or limited, and the privacy promise. It never fakes results.
struct AskScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var submitted: String?

    var body: some View {
        let access = model.photoAccess.access
        let status = model.index.status
        let state = AskState(access: access, status: status)
        ScrollView {
            if state == .deleted {
                VStack(alignment: .leading, spacing: LZSpace.lg) {
                    // The field stays, so a search typed here says why nothing happens.
                    if submitted != nil { Notice(.info, message: AskCopy.needsIndex) }
                    EmptyState(AskCopy.deletedTitle, message: AskCopy.deletedBody, systemImage: "magnifyingglass",
                               actionTitle: IndexCopy.buildIndex) { model.index.buildAgain() }
                }
                .lzPage()
                .accessibilityIdentifier("ask-deleted")
            } else {
                VStack(alignment: .leading, spacing: LZSpace.xl) {
                    VStack(alignment: .leading, spacing: LZSpace.sm) {
                        Text(AskCopy.title).lzText(.displayLarge).foregroundStyle(.lz(.ink))
                        Text(AskCopy.subtitle).lzText(.body).foregroundStyle(.lz(.muted))
                    }
                    if submitted != nil {
                        if state == .noAccess {
                            Notice(.info, message: AskCopy.needsAccess)
                        } else {
                            SearchStatusCard(state: model.search.state)
                        }
                    }
                    content(state, status: status, access: access)
                    Label(AskCopy.privacy, systemImage: "lock.shield")
                        .lzText(.caption)
                        .foregroundStyle(.lz(.muted))
                }
                .lzPage()
                .padding(.vertical, LZSpace.lg)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(.lz(.bg))
        .navigationTitle(AskCopy.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: AskCopy.prompt)
        .onSubmit(of: .search) { submit(query) }
        .onChange(of: query) { _, value in
            if value.isEmpty {
                submitted = nil
                model.search.clear()
            }
        }
        // A search started elsewhere (-LZQuery) shows its words in the field.
        .onChange(of: model.search.text) { _, text in
            guard !text.isEmpty, text != query else { return }
            query = text
            submitted = text
        }
        .accessibilityIdentifier("ask")
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = trimmed.isEmpty ? nil : trimmed
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
    static let subtitle = "Describe a moment the way you'd tell a friend. Lahza finds the photos."
    static let prompt = "Soccer at the park last summer…"
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
        case .organizing: "Trips appear when Lahza finishes."
        default: "Newest photos come first; trips appear when Lahza finishes."
        }
    }

    // MARK: Summary card

    static let summaryEyebrow = "YOUR LIBRARY"
    /// Future tense until search ships (PR 3), where it becomes "Searches places, dates and photo types…".
    static let capability = "Search will cover places, dates and photo types. Searching what’s in photos comes later."

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
