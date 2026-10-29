import Foundation
import LZCore
import LZIndex
import Observation

/// Ask's search, as the screen sees it (search spec §7.1): the chips previewed while typing, the state of the search in
/// flight, its result, and the library's example searches. A new submit cancels the one in flight; a chip edit, a
/// picker choice or a widening tap edits the slots and searches again; when the index changes, the shown search runs
/// again after 2 s (cards keep their moment keys, so the list keeps its place). Every search, and the examples, cover
/// the scope read at that moment (a free search, the last 12 months); when it changes (an unlock), the shown search
/// runs again at once.
@MainActor @Observable public final class SearchStore {
    public enum State: Sendable, Equatable {
        case idle
        case understanding
        case lookingUpPlace(String)
        case searching
        case results(SearchResult)
        case noMatch(SearchResult)
        case failed(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.understanding, .understanding), (.searching, .searching): true
            case (.lookingUpPlace(let a), .lookingUpPlace(let b)), (.failed(let a), .failed(let b)): a == b
            case (.results(let a), .results(let b)), (.noMatch(let a), .noMatch(let b)): a.id == b.id
            default: false
            }
        }
    }

    /// How results are laid out (the `lahza.search.layout` preference; the grid comes with chip editing).
    public enum ResultsLayout: String, Sendable, CaseIterable {
        case moments, grid
    }

    public private(set) var state: State = .idle
    /// The submitted text, or the rendering of edited slots.
    public private(set) var text = ""
    /// The chips: previewed while typing, then the submitted (or edited) query.
    public private(set) var parsed: ParsedQuery?
    public private(set) var examples: [ExampleSearch] = []
    public private(set) var layout: ResultsLayout
    /// The search on screen (moment detail opened from it shows its matches).
    public private(set) var currentSearchID: UUID?
    public private(set) var request: SearchRequest?

    /// The shown result (matches or a no-match).
    public var result: SearchResult? {
        switch state {
        case .results(let result), .noMatch(let result): result
        default: lastResult
        }
    }

    /// Search can run (the gazetteer loaded).
    public var isAvailable: Bool { engine != nil }

    @ObservationIgnored private let engine: SearchEngine?
    @ObservationIgnored private let index: IndexStore
    @ObservationIgnored private let kv: any KeyValueStore
    @ObservationIgnored private let clock: any AppClock
    /// What searches cover now: the whole library, or a free search's months (read at every search).
    @ObservationIgnored private let scope: @MainActor () -> SearchScope
    @ObservationIgnored private let rerunDelay: Duration
    @ObservationIgnored private let examplesDelay: Duration
    @ObservationIgnored private let previewDelay: Duration
    @ObservationIgnored private var lastResult: SearchResult?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var rerunTask: Task<Void, Never>?
    @ObservationIgnored private var examplesTask: Task<Void, Never>?
    /// The picker of the search a choice was made in: it stays, the choice ticked, so the other place is a tap away.
    @ObservationIgnored private var chosenPicker: PlacePicker?
    /// Tells the latest search from older ones still finishing.
    @ObservationIgnored private var runs = 0
    @ObservationIgnored private let log = Log("search")

    static let layoutKey = KVKey.device("search.layout")
    static let unavailableMessage = "Search is unavailable"
    static let failedMessage = "Couldn’t search your photos"

    public init(engine: SearchEngine?, index: IndexStore, kv: any KeyValueStore, clock: any AppClock,
                scope: @escaping @MainActor () -> SearchScope = { .wholeLibrary }, rerunDelay: Duration = .seconds(2),
                examplesDelay: Duration = .seconds(3), previewDelay: Duration = .milliseconds(150)) {
        self.engine = engine
        self.index = index
        self.kv = kv
        self.clock = clock
        self.scope = scope
        self.rerunDelay = rerunDelay
        self.examplesDelay = examplesDelay
        self.previewDelay = previewDelay
        layout = kv.string(forKey: Self.layoutKey).flatMap(ResultsLayout.init(rawValue:)) ?? .moments
    }

    // MARK: Typing and submitting

    /// Previews the chips for `text` after a short pause in typing.
    public func preview(_ text: String) {
        previewTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, !trimmed.isEmpty else {
            if request == nil { parsed = nil }
            return
        }
        let reader = index.reader, clock = clock, delay = previewDelay
        previewTask = Task { [weak self] in
            guard (try? await clock.sleep(for: delay)) != nil else { return }
            let parsed = await engine.parse(trimmed, reader: reader)
            guard !Task.isCancelled else { return }
            self?.parsed = parsed
        }
    }

    /// Searches typed text (parsed from scratch: earlier edits and picks for other words don't carry over).
    public func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        previewTask?.cancel()
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        self.text = trimmed
        chosenPicker = nil
        run(SearchRequest(text: trimmed))
    }

    /// Back to the start: no query, no result.
    public func clear() {
        searchTask?.cancel()
        previewTask?.cancel()
        rerunTask?.cancel()
        runs += 1
        chosenPicker = nil
        text = ""
        parsed = nil
        request = nil
        lastResult = nil
        currentSearchID = nil
        state = .idle
    }

    // MARK: Editing

    /// Applies chip edits to the shown query's slots (the text is rendered from them) and searches again. Removing the
    /// last chip goes back to the start, as clearing the field does.
    public func apply(_ edits: [SlotEdit]) {
        guard !edits.isEmpty, var request, let current = request.parsed ?? result?.query.parsed ?? parsed else { return }
        let edited = current.applying(edits)
        guard !edited.slots.isEmpty else {
            clear()
            return
        }
        for edit in edits { request.overrides.apply(edit) }
        request.parsed = edited
        request.text = edited.text
        text = edited.text
        run(request)
    }

    /// The picker's choice: replaces the place, remembers it for these words, and searches again. The picker stays
    /// with the choice ticked (a mis-tap is undone with another tap); typed again, the remembered place is searched
    /// without asking.
    public func choose(_ choice: PlacePicker.Choice) {
        guard let picker = result?.query.picker else { return }
        choose(choice.candidate, forSlot: picker.slot)
    }

    /// A place picked for a slot (the picker or the place editor): replaces the place, remembers it for the words typed
    /// for it, and searches again. A picker for the slot stays, the choice ticked.
    public func choose(_ candidate: PlaceCandidate, forSlot slot: Int) {
        guard let query = result?.query else { return }
        if let writer = index.writer, let phrase = query.picker?.slot == slot ? query.picker?.phrase : query.typedWords(slot: slot) {
            Task { try? await writer.rememberChoice(phrase: phrase, placeKey: candidate.id, radius: nil) }
        }
        if var picker = query.picker, picker.slot == slot, picker.choices.contains(where: { $0.id == candidate.id }) {
            picker.chosen = candidate.id
            chosenPicker = picker
        } else if chosenPicker?.slot == slot {
            chosenPicker = nil
        }
        apply([.replacePlace(slot: slot, placeKey: candidate.id, name: candidate.name)])
    }

    /// A no-match's widening tap.
    public func widen(_ offer: WideningOffer) {
        apply(offer.edits)
    }

    /// Shows or hides the Weaker section.
    public func setShowWeaker(_ show: Bool) {
        guard var request, request.showWeaker != show else { return }
        request.showWeaker = show
        run(request, keepsResult: true)
    }

    public func setLayout(_ layout: ResultsLayout) {
        self.layout = layout
        kv.setString(layout.rawValue, forKey: Self.layoutKey)
    }

    // MARK: Scope

    /// What searches cover changed (the full library was unlocked, or is free again): the shown search runs again at
    /// once, keeping its result on screen meanwhile, and the examples are counted again.
    public func scopeChanged() {
        refreshExamples(after: .zero)
        guard let request, result != nil else { return }
        run(request, keepsResult: true)
    }

    // MARK: Index changes

    /// The index changed: runs the shown search again after a pause (keeping the result on screen meanwhile) and
    /// refreshes the examples.
    public func indexChanged() {
        refreshExamples()
        guard request != nil, result != nil || state == .failed(Self.unavailableMessage) else { return }
        rerunTask?.cancel()
        let clock = clock, delay = rerunDelay
        rerunTask = Task { [weak self] in
            guard (try? await clock.sleep(for: delay)) != nil, let self, let request = self.request else { return }
            // The search on screen when the pause ends: a newer submit, edit or pick since the change already ran it.
            self.run(request, isRerun: true, keepsResult: true)
        }
    }

    /// Rebuilds the example searches after a pause (they need the index's counts).
    public func refreshExamples(after delay: Duration? = nil) {
        examplesTask?.cancel()
        guard let engine else { return }
        let clock = clock, wait = delay ?? examplesDelay, index = index, scope = scope()
        examplesTask = Task { [weak self] in
            if wait > .zero { guard (try? await clock.sleep(for: wait)) != nil else { return } }
            guard let reader = index.reader else {
                self?.examples = []
                return
            }
            let context = SearchIndexContext(index.status, appleMapsEnabled: index.appleMapsNames)
            let examples = (try? await engine.examples(reader: reader, index: context, scope: scope)) ?? []
            guard !Task.isCancelled else { return }
            self?.examples = examples
        }
    }

    /// A memory warning: drops search's caches and the index snapshot.
    public func releaseCaches() {
        index.releaseCaches()
        guard let engine else { return }
        Task { await engine.releaseCaches() }
    }

    /// Returns once the search, preview and examples in flight are done (tests).
    public func settled() async {
        await rerunTask?.value
        await previewTask?.value
        await searchTask?.value
        await examplesTask?.value
    }

    // MARK: Running

    private func run(_ request: SearchRequest, isRerun: Bool = false, keepsResult: Bool = false) {
        searchTask?.cancel()
        // A submit, edit or pick supersedes a pending re-run of the search it replaces.
        if !isRerun { rerunTask?.cancel() }
        runs += 1
        let run = runs
        var request = request
        request.scope = scope()
        self.request = request
        guard let engine else {
            state = .failed(Self.unavailableMessage)
            return
        }
        guard let reader = index.reader else {
            state = .failed(Self.unavailableMessage)
            return
        }
        if !keepsResult {
            state = request.parsed == nil ? .understanding : .searching
            if let edited = request.parsed { parsed = edited }
        }
        let writer = index.writer
        let context = SearchIndexContext(index.status, appleMapsEnabled: index.appleMapsNames)
        let progress: @Sendable (SearchProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.progressed(progress, run: run, quiet: keepsResult) }
        }
        searchTask = Task { [weak self] in
            do {
                let result = try await engine.search(request, reader: reader, writer: writer, index: context, isRerun: isRerun, progress: progress)
                self?.finished(result, run: run)
            } catch is CancellationError {
                return
            } catch {
                self?.failed(error, run: run)
            }
        }
    }

    private func progressed(_ progress: SearchProgress, run: Int, quiet: Bool) {
        guard run == runs, searchTask != nil else { return }
        switch progress {
        case .understood(let query):
            parsed = query
            if !quiet { state = .searching }
        case .lookingUpPlace(let name):
            if !quiet { state = .lookingUpPlace(name) }
        case .scoring:
            if !quiet { state = .searching }
        }
    }

    private func finished(_ result: SearchResult, run: Int) {
        guard run == runs else { return }
        var result = result
        if result.query.picker == nil, let picker = chosenPicker, request?.overrides.places[picker.slot]?.placeKey == picker.chosen {
            result.query.picker = picker
        }
        searchTask = nil
        parsed = result.query.parsed
        lastResult = result
        currentSearchID = result.id
        state = result.noMatch == nil ? .results(result) : .noMatch(result)
    }

    private func failed(_ error: any Error, run: Int) {
        guard run == runs else { return }
        searchTask = nil
        log.error("Search failed: \(type(of: error))", privacy: .public)
        state = .failed(Self.failedMessage)
    }
}
