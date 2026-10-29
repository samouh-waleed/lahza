import LZDesign
import LZIndex
import SwiftUI

/// Settings › Search index: what the index is doing and holds, Apple Maps place names, Rebuild and Delete. The
/// index is a cache of the library on this iPhone, so both are always safe.
struct SearchIndexScreen: View {
    @Environment(AppModel.self) private var model
    @State private var sizeBytes: Int64?
    @State private var confirmRebuild = false
    @State private var confirmDelete = false

    var body: some View {
        let index = model.index
        let status = index.status
        ScrollView {
            VStack(alignment: .leading, spacing: LZSpace.xxl) {
                SearchIndexStatusCard(status: status)
                if let summary = status.summary, index.reader != nil {
                    group(IndexCopy.contentsTitle) {
                        ListRow(IndexCopy.assetsRow, value: summary.assets.formatted())
                        ListRow(IndexCopy.locatedRow, value: IndexCopy.percent(summary.located, of: summary.assets))
                        ListRow(IndexCopy.momentsRow, value: summary.moments.formatted())
                        ListRow(IndexCopy.tripsRow, value: summary.trips.formatted())
                        ListRow(IndexCopy.placesRow, value: IndexCopy.namedValue(status.placeNames))
                        if let sizeBytes {
                            ListRow(IndexCopy.sizeRow, value: ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                        }
                    }
                    .accessibilityIdentifier("search-index-contents")
                }
                group(IndexCopy.placeNamesTitle) {
                    LZToggleRow(IndexCopy.appleMapsToggle, subtitle: IndexCopy.appleMapsFooter, systemImage: "map",
                                isOn: Binding(get: { index.appleMapsNames }, set: { index.setAppleMapsNames($0) }))
                        .accessibilityIdentifier("search-index-apple-maps")
                }
                VStack(alignment: .leading, spacing: LZSpace.md) {
                    if status.phase == .off(.deletedByUser) {
                        LZButton(IndexCopy.buildIndex, systemImage: "arrow.clockwise", fullWidth: true) { index.buildAgain() }
                            .accessibilityIdentifier("search-index-build")
                    } else if index.reader != nil {
                        LZButton(IndexCopy.rebuild, systemImage: "arrow.triangle.2.circlepath", role: .secondary, fullWidth: true) {
                            confirmRebuild = true
                        }
                        .accessibilityIdentifier("search-index-rebuild")
                        // Each confirmation hangs off its own button, so its popover points at it.
                        .confirmationDialog(IndexCopy.rebuildTitle, isPresented: $confirmRebuild, titleVisibility: .visible) {
                            Button(IndexCopy.rebuild) { Task { await index.rebuild() } }
                        } message: {
                            Text(IndexCopy.rebuildMessage)
                        }
                        LZButton(IndexCopy.delete, systemImage: "trash", role: .destructive, fullWidth: true) { confirmDelete = true }
                            .accessibilityIdentifier("search-index-delete")
                            .confirmationDialog(IndexCopy.deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
                                Button(IndexCopy.delete, role: .destructive) { Task { await index.deleteIndex() } }
                            } message: {
                                Text(IndexCopy.deleteMessage)
                            }
                    }
                    Text(IndexCopy.footer)
                        .lzText(.caption)
                        .foregroundStyle(.lz(.muted))
                }
            }
            .lzPage()
            .padding(.vertical, LZSpace.xl)
        }
        .background(.lz(.bg))
        .tint(Color.lz(.accent))
        .navigationTitle(IndexCopy.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("search-index")
        .task(id: status.version) { sizeBytes = try? await index.reader?.sizeBytes() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LZSpace.sm) {
            Text(title).lzText(.label).foregroundStyle(.lz(.muted)).accessibilityAddTraits(.isHeader)
            LZRowGroup(content: content)
        }
    }
}

/// The index's phase, when it last caught up, reading progress and the place-name line.
private struct SearchIndexStatusCard: View {
    let status: IndexStatus

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: LZSpace.md) {
                HStack(alignment: .center, spacing: LZSpace.md) {
                    IconBadge(IndexCopy.symbol(status), tone: IndexCopy.tone(status))
                    VStack(alignment: .leading, spacing: LZSpace.xxs) {
                        Text(IndexCopy.headline(status))
                            .lzText(.headline)
                            .foregroundStyle(.lz(.ink))
                            .accessibilityIdentifier("search-index-status")
                        if let updated = status.lastSync, status.phase == .ready {
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                Text(IndexCopy.updated(updated))
                                    .lzText(.subheadline)
                                    .foregroundStyle(.lz(.muted))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if case .reading(let done, let total) = status.phase, total > 0 {
                    ProgressView(value: Double(min(done, total)), total: Double(total))
                        .progressViewStyle(.lz(.bar))
                        .accessibilityLabel(IndexCopy.headline(status))
                }
                if let detail = IndexCopy.placeNames(status.placeNames) {
                    Label(detail, systemImage: IndexCopy.placeNamesSymbol(status.placeNames))
                        .lzText(.subheadline)
                        .foregroundStyle(.lz(.muted))
                        .accessibilityIdentifier("search-index-place-names")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The search index's words (spec §4.6, §7.3).
nonisolated enum IndexCopy {
    static let screenTitle = "Search index"
    static let contentsTitle = "WHAT’S INDEXED"
    static let placeNamesTitle = "PLACE NAMES"
    static let assetsRow = "Photos & videos"
    static let locatedRow = "With a location"
    static let momentsRow = "Moments"
    static let tripsRow = "Trips"
    static let placesRow = "Places named"
    static let sizeRow = "Index size"
    static let appleMapsToggle = "Apple Maps place names"
    static let rebuild = "Rebuild index"
    static let delete = "Delete index"
    static let buildIndex = "Build index"
    static let rebuildTitle = "Rebuild search index?"
    static let rebuildMessage = "Lahza reads your library again. Saved places are kept."
    static let deleteTitle = "Delete search index?"
    static let deleteMessage = "Lahza forgets the dates, places, moments and saved places it learned, and stops searching until you build it again. Your photos aren’t touched."
    static let appleMapsFooter = "Sends the approximate location of photo clusters, and places you type with your rough area, to Apple Maps to get names like parks. Photos are never sent."
    static let footer = "The index lives only on this iPhone, isn’t backed up, and can be rebuilt from your library at any time."
    static let unavailableDetail = "Lahza tries again the next time it opens."

    /// Settings' row value.
    static func value(_ status: IndexStatus) -> String {
        switch status.phase {
        case .off: "Off"
        case .preparing: "Starting"
        case .reading(let done, let total): "Reading \(percent(done, of: total))"
        case .organizing: "Organizing"
        case .ready: "Up to date"
        case .paused: "Paused"
        case .failed: "Problem"
        }
    }

    static func headline(_ status: IndexStatus) -> String {
        switch status.phase {
        case .off(.noAccess): "Off: Lahza needs photo access"
        case .off(.deletedByUser): "Search index deleted"
        case .off(.protectedDataUnavailable): "Waiting for this iPhone to be unlocked"
        case .preparing: "Getting ready"
        case .reading(let done, let total): "Reading your library · \(done.formatted()) of \(total.formatted())"
        case .organizing: "Grouping your photos into moments and trips"
        case .ready: "Up to date"
        case .paused: "Continues when Lahza is open"
        case .failed(let message): message
        }
    }

    static func symbol(_ status: IndexStatus) -> String {
        switch status.phase {
        case .off: "pause.circle"
        case .preparing, .reading, .organizing: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle"
        case .paused: "moon"
        case .failed: "exclamationmark.triangle"
        }
    }

    static func tone(_ status: IndexStatus) -> LZTone {
        switch status.phase {
        case .ready: .sage
        case .preparing, .reading, .organizing: .accent
        case .failed: .gold
        case .off, .paused: .neutral
        }
    }

    /// The place-name line, or nil when there is nothing to say.
    static func placeNames(_ progress: PlaceNameProgress) -> String? {
        switch progress.state {
        case .running: "Naming places with Apple Maps · \(progress.named.formatted()) of \(progress.eligible.formatted())"
        case .waitingForNetwork: "Waiting for internet"
        case .throttled(let until): "Apple Maps is busy · retrying at \(until.formatted(date: .omitted, time: .shortened))"
        case .backgrounded: "Continues when Lahza is open"
        case .off: "Apple Maps place names are off"
        case .idle, .done: nil
        }
    }

    static func placeNamesSymbol(_ progress: PlaceNameProgress) -> String {
        switch progress.state {
        case .waitingForNetwork: "wifi.slash"
        case .throttled: "hourglass"
        case .backgrounded: "moon"
        case .off: "map"
        case .running, .idle, .done: "mappin.and.ellipse"
        }
    }

    /// "18 of 47".
    static func namedValue(_ progress: PlaceNameProgress) -> String {
        "\(progress.named.formatted()) of \(progress.eligible.formatted())"
    }

    static func updated(_ date: Date) -> String {
        "Updated \(date.formatted(.relative(presentation: .named)))"
    }

    /// A whole percentage that reads 100% only when all is done, and 0% only when none is.
    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        var share = (Double(part) / Double(whole) * 100).rounded()
        if part < whole { share = min(share, 99) }
        if part > 0 { share = max(share, 1) }
        return (share / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
