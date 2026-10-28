import LZDesign
import LZIndex
import SwiftUI

/// Settings › Search index: what the index holds, Apple Maps place names, Rebuild and Delete. The index is a
/// cache of the library on this iPhone, so both are always safe.
struct SearchIndexScreen: View {
    @Environment(AppModel.self) private var model
    @State private var sizeBytes: Int64?
    @State private var confirmRebuild = false
    @State private var confirmDelete = false

    var body: some View {
        let index = model.index
        let status = index.status
        Form {
            Section {
                Label(IndexCopy.headline(status), systemImage: IndexCopy.symbol(status))
                    .font(.headline)
                    .accessibilityIdentifier("search-index-status")
                if let updated = status.lastSync, status.phase == .ready {
                    Text(IndexCopy.updated(updated)).foregroundStyle(.secondary)
                }
                if let detail = IndexCopy.placeNames(status.placeNames) {
                    Text(detail).foregroundStyle(.secondary).accessibilityIdentifier("search-index-place-names")
                }
            }
            if let summary = status.summary, index.reader != nil {
                Section("What's indexed") {
                    LabeledContent("Photos & videos", value: summary.assets.formatted())
                    LabeledContent("With a location", value: IndexCopy.percent(summary.located, of: summary.assets))
                    LabeledContent("Moments", value: summary.moments.formatted())
                    LabeledContent("Trips", value: summary.trips.formatted())
                    LabeledContent("Places named", value: "\(status.placeNames.named.formatted()) of \(status.placeNames.eligible.formatted())")
                    if let sizeBytes {
                        LabeledContent("Index size", value: ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                    }
                }
            }
            Section {
                Toggle("Apple Maps place names", isOn: Binding(get: { index.appleMapsNames }, set: { index.setAppleMapsNames($0) }))
                    .accessibilityIdentifier("search-index-apple-maps")
            } footer: {
                Text(IndexCopy.appleMapsFooter)
            }
            Section {
                if status.phase == .off(.deletedByUser) {
                    Button(IndexCopy.buildIndex) { index.buildAgain() }
                        .accessibilityIdentifier("search-index-build")
                } else if index.reader != nil {
                    Button(IndexCopy.rebuild) { confirmRebuild = true }
                        .accessibilityIdentifier("search-index-rebuild")
                    Button(IndexCopy.delete, role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("search-index-delete")
                }
            } footer: {
                Text(IndexCopy.footer)
            }
        }
        .settingsForm(IndexCopy.screenTitle)
        .accessibilityIdentifier("search-index")
        .task(id: status.version) { sizeBytes = try? await index.reader?.sizeBytes() }
        .confirmationDialog(IndexCopy.rebuildTitle, isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button(IndexCopy.rebuild) { Task { await index.rebuild() } }
        } message: {
            Text(IndexCopy.rebuildMessage)
        }
        .confirmationDialog(IndexCopy.deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(IndexCopy.delete, role: .destructive) { Task { await index.deleteIndex() } }
        } message: {
            Text(IndexCopy.deleteMessage)
        }
    }
}

/// The search index's words (spec §4.6, §7.3).
nonisolated enum IndexCopy {
    static let screenTitle = "Search index"
    static let rebuild = "Rebuild index"
    static let delete = "Delete index"
    static let buildIndex = "Build index"
    static let rebuildTitle = "Rebuild search index?"
    static let rebuildMessage = "Lahza reads your library again. Saved places are kept."
    static let deleteTitle = "Delete search index?"
    static let deleteMessage = "Lahza forgets the dates, places, moments and saved places it learned, and stops searching until you build it again. Your photos aren’t touched."
    static let appleMapsFooter = "Sends the approximate location of photo clusters, and places you type, to Apple Maps to get names like parks. Photos are never sent."
    static let footer = "The index lives only on this iPhone, isn’t backed up, and is rebuilt from your library if deleted."

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

    static func updated(_ date: Date) -> String {
        "Updated \(date.formatted(.relative(presentation: .named)))"
    }

    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        return (Double(part) / Double(whole)).formatted(.percent.precision(.fractionLength(0)))
    }
}
