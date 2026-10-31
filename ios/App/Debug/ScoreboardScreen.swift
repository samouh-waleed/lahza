#if DEBUG
import LZIndex
import LZLibrary
import LZSearch
import Observation
import SwiftUI

/// DEBUG: Settings › Developer › Scoreboard (content search 5a, E32). The person labels in Photos ("LZ 07" the right
/// photos, "LZ 07 ?" the unsure ones, "AP 07" Apple's answer), types each search once here with its kind, freezes the
/// held-out third, and runs the searches through Lahza in a mode. The searches and photos shown here are private: this
/// screen is never in screenshots or review pages, the console gets numbers only, and exports go to `Documents/Scoreboard`
/// for copying into plan-docs.
struct ScoreboardScreen: View {
    @Environment(AppModel.self) private var model
    @State private var board = ScoreboardModel()
    @State private var editing: EditedEntry?
    @State private var mode = ScoreboardModel.Mode.full
    @State private var showsHeldOut = false

    struct EditedEntry: Identifiable {
        var number: Int
        var id: Int { number }
    }

    var body: some View {
        Form {
            albums
            searches
            if !board.untyped.isEmpty || !board.withoutAlbum.isEmpty { missing }
            split
            run
            if let report = board.report { results(report) }
            Section {
                Button("Export to Documents/Scoreboard") { board.export() }
                    .disabled(board.report == nil)
                Button("Print summary") { if let report = board.report { print(report.summary) } }
                    .disabled(board.report == nil)
                if let message = board.message { Text(message).lzText(.caption).foregroundStyle(.lz(.muted)) }
            }
        }
        .navigationTitle("Scoreboard")
        .task { await board.load(albums: model.dependencies.albums, reader: model.index.reader) }
        .sheet(item: $editing) { edited in
            ScoreboardEntryEditor(number: edited.number, entry: board.book.entries[edited.number]) { text, kind in
                board.set(edited.number, text: text, kind: kind)
            } remove: {
                board.remove(edited.number)
            }
        }
        .accessibilityIdentifier("scoreboard")
    }

    private var albums: some View {
        Section("Albums") {
            if board.labels.numbers.isEmpty && board.labels.apple.isEmpty {
                Text(ScoreboardCopy.noAlbums).lzText(.subheadline)
                    .accessibilityIdentifier("scoreboard-no-albums")
            } else {
                LabeledContent("Numbered albums", value: "\(board.labels.right.count)")
                LabeledContent("Unsure albums", value: "\(board.labels.unsure.count)")
                LabeledContent("Apple's answers (AP)", value: "\(board.labels.apple.count)")
                LabeledContent("Labelled, not in Lahza's index", value: "\(board.notIndexed)")
            }
            Button("Read the albums again") { Task { await board.load(albums: model.dependencies.albums, reader: model.index.reader) } }
        }
    }

    private var searches: some View {
        Section("Searches") {
            ForEach(board.numbers, id: \.self) { number in
                Button { editing = EditedEntry(number: number) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(board.title(number)).lzText(.subheadline).foregroundStyle(.lz(.ink))
                        Text(board.book.entries[number]?.text ?? "No search typed yet").lzText(.caption).foregroundStyle(.lz(.muted))
                    }
                }
            }
            Button("Add a search") { editing = EditedEntry(number: (board.numbers.last ?? 0) + 1) }
        }
    }

    private var missing: some View {
        Section("Missing") {
            if !board.untyped.isEmpty { Text("Type the search for \(ScoreboardCopy.numbers(board.untyped)).").lzText(.subheadline) }
            if !board.withoutAlbum.isEmpty { Text("No “LZ” album yet for \(ScoreboardCopy.numbers(board.withoutAlbum)).").lzText(.subheadline) }
        }
    }

    private var split: some View {
        Section("Held-out split") {
            if board.book.frozen {
                LabeledContent("Frozen", value: "\(board.book.entries.values.count { $0.split == .heldOut }) of \(board.book.entries.count) held out")
            } else {
                Text("Freeze once every search is typed with its kind and has its album, before any tuning. A third of each kind is held out and never tuned on.")
                    .lzText(.caption).foregroundStyle(.lz(.muted))
                Button("Freeze the held-out third") { board.freeze() }
                    .disabled(board.book.entries.isEmpty || board.book.entries.values.contains { $0.kind == nil } || !board.withoutAlbum.isEmpty
                              || !board.untyped.isEmpty)
            }
        }
    }

    private var run: some View {
        Section("Run") {
            Picker("Mode", selection: $mode) {
                ForEach(ScoreboardModel.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button(board.running ? "Running \(board.book.entries.count) searches…" : "Run the searches") {
                Task { await board.run(mode, search: model.search) }
            }
            .disabled(board.running || board.book.entries.isEmpty)
        }
    }

    private func results(_ report: Scoreboard.Report) -> some View {
        Section("Results · \(report.mode)") {
            row("Dev", report.devTotal)
            ForEach(Scoreboard.Kind.allCases, id: \.self) { kind in
                if let line = report.dev[kind] { row("  \(kind.rawValue)", line) }
            }
            Toggle("Show held-out totals", isOn: $showsHeldOut)
            if showsHeldOut { row("Held-out", report.heldOut) }
        }
    }

    private func row(_ title: String, _ line: Scoreboard.Line) -> some View {
        LabeledContent(title, value: ScoreboardCopy.line(line))
    }
}

/// One search's words and kind.
private struct ScoreboardEntryEditor: View {
    let number: Int
    let entry: Scoreboard.Entry?
    let save: (String, Scoreboard.Kind?) -> Void
    let remove: () -> Void
    @State private var text = ""
    @State private var kind: Scoreboard.Kind?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Search \(ScoreboardCopy.number(number))") {
                    TextField("As you would type it", text: $text, axis: .vertical)
                }
                Section("Kind") {
                    Picker("Kind", selection: $kind) {
                        Text("Not set").tag(Scoreboard.Kind?.none)
                        ForEach(Scoreboard.Kind.allCases, id: \.self) { Text($0.rawValue).tag(Scoreboard.Kind?.some($0)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if entry != nil {
                    Section {
                        Button("Remove this search", role: .destructive) {
                            remove()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(ScoreboardCopy.number(number))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(text.trimmingCharacters(in: .whitespacesAndNewlines), kind)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                text = entry?.text ?? ""
                kind = entry?.kind
            }
        }
    }
}

/// The scoreboard's state: the book (its own file), the albums read, and the latest run.
@MainActor @Observable final class ScoreboardModel {
    /// The ablation ladder (E30): each layer must raise the dev split and lose nothing on the held-out third.
    enum Mode: String, CaseIterable, Hashable {
        case full, calibrated, fused, model, tags, v0, apple

        var title: String {
            switch self {
            case .full: "Lahza, everything (with whole outings)"
            case .calibrated: "Tags + model, calibrated"
            case .fused: "Tags + model, uncalibrated"
            case .model: "Model only"
            case .tags: "Tags only (Milestone A)"
            case .v0: "No content (search v0)"
            case .apple: "Apple Photos (AP albums)"
            }
        }

        var signals: ContentSignals {
            switch self {
            case .full, .apple: .all
            case .calibrated: [.tags, .model, .calibration]
            case .fused: [.tags, .model]
            case .model: [.model, .calibration]
            case .tags: [.tags]
            case .v0: .none
            }
        }
    }

    private(set) var book = Scoreboard.Book()
    private(set) var labels = Scoreboard.Labels()
    private(set) var indexed = Set<String>()
    private(set) var report: Scoreboard.Report?
    private(set) var running = false
    private(set) var message: String?

    /// The book, next to the index (excluded from backups).
    private let bookURL: URL?
    /// Where exports go (the app container's Documents, which `devicectl device copy from` reads).
    private let exportFolder: URL?

    init() {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Scoreboard", isDirectory: true)
        bookURL = support?.appendingPathComponent("book.json")
        exportFolder = files.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Scoreboard", isDirectory: true)
        if let bookURL, let data = try? Data(contentsOf: bookURL), let saved = try? JSONDecoder().decode(Scoreboard.Book.self, from: data) {
            book = saved
        }
    }

    /// Every number with an album or typed words, in order.
    var numbers: [Int] { Array(labels.numbers.union(book.entries.keys)).sorted() }
    /// Numbers with an album and no words.
    var untyped: [Int] { labels.numbers.subtracting(book.entries.keys).sorted() }
    /// Numbers with words and no "LZ" album.
    var withoutAlbum: [Int] { Set(book.entries.keys).subtracting(labels.right.keys).sorted() }
    var notIndexed: Int { Set(labels.allLocalIDs).subtracting(indexed).count }

    /// "07 · what · 12 photos · 2 unsure · held-out".
    func title(_ number: Int) -> String {
        var parts = [ScoreboardCopy.number(number)]
        if let kind = book.entries[number]?.kind { parts.append(kind.rawValue) }
        if let right = labels.right[number] { parts.append(right.isEmpty ? "answer: nothing" : "\(right.count) photos") } else { parts.append("no album") }
        if let unsure = labels.unsure[number], !unsure.isEmpty { parts.append("\(unsure.count) unsure") }
        if let split = book.entries[number]?.split { parts.append(split.rawValue) }
        return parts.joined(separator: " · ")
    }

    func load(albums: any AlbumSource, reader: IndexReader?) async {
        labels = Scoreboard.Labels(await albums.albums { Scoreboard.album($0) != nil })
        indexed = (try? await reader?.indexed(localIDs: labels.allLocalIDs)) ?? []
    }

    func set(_ number: Int, text: String, kind: Scoreboard.Kind?) {
        book.set(number, text: text, kind: kind)
        save()
    }

    func remove(_ number: Int) {
        book.remove(number)
        save()
    }

    func freeze() {
        book.freeze(nothing: Set(labels.right.filter(\.value.isEmpty).keys))
        save()
    }

    func run(_ mode: Mode, search: SearchStore) async {
        running = true
        defer { running = false }
        let entries = book.sorted, labels = labels, indexed = indexed
        var outcomes: [Scoreboard.Outcome] = []
        if mode == .apple {
            outcomes = entries.compactMap { Scoreboard.scoreApple($0, labels: labels, indexed: indexed) }
        } else {
            do {
                let signals = mode.signals
                outcomes = try await Scoreboard.run(entries, labels: labels, indexed: indexed) { entry in
                    try await search.scoreboardSearch(SearchRequest(text: entry.text, scope: .wholeLibrary, content: signals))
                }
            } catch {
                message = "The run stopped: \(error.localizedDescription)"
                return
            }
        }
        report = Scoreboard.Report(mode: mode.rawValue, date: Date(), outcomes: outcomes)
        message = nil
    }

    func export() {
        guard let report, let exportFolder else { return }
        do {
            try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let stamp = report.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard))
                .replacingOccurrences(of: ":", with: "")
            let url = exportFolder.appendingPathComponent("\(stamp)-\(report.mode).json")
            try encoder.encode(ScoreboardExport(report: report, book: book)).write(to: url, options: .atomic)
            message = "Saved Documents/Scoreboard/\(url.lastPathComponent)"
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let bookURL else { return }
        do {
            var folder = bookURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            try JSONEncoder().encode(book).write(to: bookURL, options: [.atomic, .completeFileProtection])
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// What an export holds: the run and the book it ran.
struct ScoreboardExport: Encodable {
    var report: Scoreboard.Report
    var book: Scoreboard.Book
}

nonisolated enum ScoreboardCopy {
    static let noAlbums = """
        No scoreboard albums yet. In Photos, make one album per search: “LZ 01” to “LZ 30” for H1–H30, and “LZ 31” and up for \
        searches with no right answer (leave those empty). Put photos you're unsure of in “LZ 07 ?”, and Apple's answer in “AP 07”. \
        Album titles never hold the search: type it here.
        """

    static func number(_ number: Int) -> String { String(format: "%02d", number) }

    static func numbers(_ numbers: [Int]) -> String { numbers.map(number).joined(separator: ", ") }

    /// "n 5 · F1 0.41 · P 0.50 · R 0.38 · Hit@3 0.60 · declined 1 of 2".
    static func line(_ line: Scoreboard.Line) -> String {
        func value(_ number: Double?) -> String { number.map { String(format: "%.2f", $0) } ?? "–" }
        var parts = ["n \(line.searches)", "F1 \(value(line.f1))", "P \(value(line.precision))", "R \(value(line.recall))", "Hit@3 \(value(line.hitAt3))"]
        if line.nothing > 0 { parts.append("declined \(line.declined) of \(line.nothing)") }
        return parts.joined(separator: " · ")
    }
}
#endif
