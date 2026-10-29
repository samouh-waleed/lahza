import Foundation
import LZCore
import LZGeo
import LZIndex

/// Where a running search is, for the Ask screen's states.
public enum SearchProgress: Sendable, Hashable {
    /// The query is parsed (the chips can show).
    case understood(ParsedQuery)
    /// A typed place is being looked up (the place chip shows a spinner).
    case lookingUpPlace(String)
    /// Places and dates are resolved; photos are being scored.
    case scoring
}

/// Search (search spec §6): parse → resolve (time, place) → score the snapshot → tier → group by moment and trip →
/// reasons, or a no-match that names the failing slot and offers to widen. At most one Apple Maps search per query.
/// Caches (the parse vocabulary, resolved places, the time context, example searches) are per index version and are
/// dropped on a memory warning.
public actor SearchEngine {
    private let gazetteer: Gazetteer
    private let parser: any QueryParser
    private let clock: any AppClock
    private let locale: Locale
    private let deviceTimeZone: @Sendable () -> TimeZone
    private let places: PlaceResolver
    private let vocabulary: VocabularyCache
    private var contexts: EngineContext?
    /// The places resolved for each place expression, reused when the index changes under a shown search.
    private var resolutions: [ResolutionKey: (version: Int64, resolution: PlaceResolution)] = [:]
    var examplesCache: (generation: Int, version: Int64, examples: [ExampleSearch])?
    let log = Log("search")

    static let resolutionCacheSize = 64

    public init(gazetteer: Gazetteer, maps: any MapsClient, budget: MapsBudget, parser: any QueryParser = RulesQueryParser(), clock: any AppClock,
                network: any NetworkStatus, locale: Locale = .autoupdatingCurrent, deviceTimeZone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.gazetteer = gazetteer
        self.parser = parser
        self.clock = clock
        self.locale = locale
        self.deviceTimeZone = deviceTimeZone
        places = PlaceResolver(gazetteer: gazetteer, maps: maps, budget: budget, network: network, clock: clock)
        vocabulary = VocabularyCache(gazetteer: gazetteer, clock: clock)
    }

    /// Parses `text` with the index's place names (the chips preview while typing).
    public func parse(_ text: String, reader: IndexReader?) async -> ParsedQuery {
        let vocabulary = await vocabulary.vocabulary(reader: reader)
        return await parser.parse(text, context: ParseContext(now: clock.now, vocabulary: vocabulary, locale: locale))
    }

    /// Runs `request` over the index. `isRerun` (the index changed under a shown result) reuses the places resolved
    /// for the same words.
    public func search(_ request: SearchRequest, reader: IndexReader, writer: UserDataWriter?, index: SearchIndexContext = SearchIndexContext(),
                       isRerun: Bool = false, progress: (@Sendable (SearchProgress) -> Void)? = nil) async throws -> SearchResult {
        let started = ContinuousClock.now
        var timings = Timings()
        let parsed: ParsedQuery
        if let edited = request.parsed {
            parsed = edited
        } else {
            parsed = await parse(request.text, reader: reader)
        }
        timings.parse = ContinuousClock.now - started
        progress?(.understood(parsed))
        try Task.checkCancellation()

        let snapshotStarted = ContinuousClock.now
        async let snapshotTask = reader.snapshot()
        let context = try await context(reader)
        let snapshot = try await snapshotTask
        timings.snapshot = ContinuousClock.now - snapshotStarted

        let resolveStarted = ContinuousClock.now
        let query = try await prepare(parsed, overrides: request.overrides, reader: reader, writer: writer, snapshot: snapshot, context: context,
                                      appleMaps: index.appleMapsEnabled, isRerun: isRerun, progress: progress)
        timings.resolve = ContinuousClock.now - resolveStarted
        progress?(.scoring)
        try Task.checkCancellation()

        let scoreStarted = ContinuousClock.now
        var scorer = Scorer(snapshot: snapshot, plan: query.plan)
        let (scored, unreliable) = query.canScore ? scorer.run() : ([], 0)
        var hits = scored
        var locked = 0
        if case .since(let date) = request.scope {
            let since = Int64(date.timeIntervalSince1970)
            let before = hits.count
            hits.removeAll { snapshot.utc[Int($0.index)] < since }
            locked = before - hits.count
        }
        timings.score = ContinuousClock.now - scoreStarted

        let groupStarted = ContinuousClock.now
        let copy = SearchCopy(locale: locale, resolver: TimeResolver(context: context.time))
        let assembler = ResultAssembler(snapshot: snapshot, query: query, copy: copy, context: context)
        let shown = hits.filter { $0.tier != .weaker || request.showWeaker }
        let built = try await assembler.assemble(shown, reader: reader)
        let matched = hits.contains { $0.tier == .best || $0.tier == .more }
        var noMatch: NoMatch?
        if !matched {
            let builder = NoMatchBuilder(snapshot: snapshot, query: query, copy: copy, context: context, index: index)
            noMatch = try await builder.build(reader: reader)
            if noMatch?.kind == .onlyUnsupported, let examples = try? await examples(reader: reader, index: index) { noMatch?.examples = examples }
        }
        let coverage = assembler.coverage(searched: snapshot.count, index: index, unreliable: unreliable, borrowed: built.borrowed)
        timings.group = ContinuousClock.now - groupStarted
        timings.total = ContinuousClock.now - started

        let result = SearchResult(id: UUID(), query: query.resolved, sections: built.sections, totals: built.totals, coverage: coverage, noMatch: noMatch,
                                  unsupported: query.unsupported.map(\.slot),
                                  unsupportedNotice: noMatch?.kind == .onlyUnsupported ? nil
                                      : copy.unsupportedNotice(query.unsupported, showing: query.showingPhrase(copy)),
                                  weakerCount: hits.count(where: { $0.tier == .weaker }), lockedCount: locked, timings: timings)
        log.info("Search: slots \(parsed.slots.map(\.kind.rawValue).joined(separator: ",")), \(result.totals.moments) moments, "
                 + "\(result.totals.items) items, \(hits.count(where: { $0.tier == .locationUnknown })) unlocated, no match \(noMatch.map { "\($0.kind)" } ?? "-"), "
                 + "Apple Maps \(query.resolved.searchedAppleMaps ? 1 : 0), \(timings.total) (resolve \(timings.resolve), score \(timings.score))",
                 privacy: .public)
        return result
    }

    /// Drops the caches (memory warning): the vocabulary, resolved places, the time context and examples.
    public func releaseCaches() async {
        await vocabulary.release()
        resolutions = [:]
        contexts = nil
        examplesCache = nil
    }

    // MARK: Context

    /// The home, the library's years and the time context for relative dates, per index version.
    func context(_ reader: IndexReader) async throws -> EngineContext {
        let version = try await reader.indexVersion()
        if let contexts, contexts.generation == reader.generation, contexts.version == version { return contexts }
        async let summaryTask = reader.summary()
        let home = try await reader.homeBase(year: nil)
        let summary = try await summaryTask
        let zone = home?.timeZone.flatMap(TimeZone.init(identifier:)) ?? deviceTimeZone()
        var years: ClosedRange<Int>?
        if let first = summary.firstYear, let last = summary.lastYear, first <= last { years = first...last }
        var homeCountryPlace: Int32?
        if let code = home?.countryCode, let row = try await reader.places(keys: [PlaceKey.country(code)])[PlaceKey.country(code)] {
            homeCountryPlace = Int32(clamping: row.id)
        }
        let time = TimeContext(now: clock.now, zone: zone, homeCountry: home?.countryCode, homeIsSouth: (home?.center.latitude ?? 0) < 0, locale: locale,
                               years: years)
        let context = EngineContext(generation: reader.generation, version: version, time: time, home: home, summary: summary,
                                    homeCountryPlace: homeCountryPlace, zone: zone)
        contexts = context
        return context
    }

    // MARK: Resolving

    /// Resolves every slot: the time slots together (pure), the place slot through the resolver (own index, gazetteer,
    /// at most one Apple Maps search), media and events as they are.
    func prepare(_ parsed: ParsedQuery, overrides: ResolutionOverrides, reader: IndexReader, writer: UserDataWriter?, snapshot: SearchSnapshot,
                 context: EngineContext, appleMaps: Bool, isRerun: Bool, progress: (@Sendable (SearchProgress) -> Void)?) async throws -> PreparedQuery {
        var query = PreparedQuery(parsed: parsed)
        let resolver = TimeResolver(context: context.time)
        let environment = PlaceEnvironment(reader: reader, writer: writer, density: SnapshotDensity(snapshot: snapshot), appleMapsEnabled: appleMaps,
                                           searchRegion: context.home.map { GeoRegion(center: $0.center, spanDegrees: 4) })

        // Time: every time slot together.
        let timeSlots = parsed.slots.filter { $0.kind == .time }
        var timeResolution: TimeResolution?
        if !timeSlots.isEmpty {
            let expressions = parsed.timeExpressions
            let combined = resolver.resolve(expressions)
            timeResolution = combined
            query.timeSlots = timeSlots.map(\.id)
            query.timeExpression = expressions.count == 1 ? expressions[0] : .all(expressions)
            if case .constraint(let constraint) = combined { query.plan.time = constraint }
        }

        var slots: [ResolvedSlot] = []
        for slot in parsed.slots {
            switch slot.value {
            case .time(let expression):
                if case .unsupported(let message)? = timeResolution {
                    slots.append(ResolvedSlot(slot: slot, resolution: .unsupported, chip: message, systemImage: "info.circle"))
                } else if let constraint = (timeSlots.count == 1 ? timeResolution : resolver.resolve(expression))?.constraint {
                    slots.append(ResolvedSlot(slot: slot, resolution: .time(.constraint(constraint)), chip: constraint.label, systemImage: "calendar"))
                }
            case .place(let expression):
                guard query.placeSlot == nil, query.placeFailure == nil else {
                    // One place per query in v0: a second one is left out.
                    slots.append(ResolvedSlot(slot: slot, resolution: .unsupported, chip: expression.phrase, systemImage: "info.circle"))
                    continue
                }
                let phrase = slot.span?.substring(of: parsed.text) ?? expression.phrase
                if case .named(let name, _, _) = expression { progress?(.lookingUpPlace(name)) }
                let override = overrides.places[slot.id]
                let resolution = try await resolvePlace(expression, override: override, environment: environment, generation: reader.generation,
                                                        version: context.version, isRerun: isRerun)
                if environment.allowance.searched { query.searchedAppleMaps = true }
                switch resolution {
                case .notFound(.notAPlace):
                    // Words that only might be a place and match none are about what's in the photos.
                    let words = phrase
                    slots.append(ResolvedSlot(slot: QuerySlot(id: slot.id, value: .visual(words), span: slot.span), resolution: .unsupported, chip: words,
                                              systemImage: "info.circle"))
                case .notFound(let reason):
                    query.placeFailure = (slot.id, reason, phrase)
                    slots.append(ResolvedSlot(slot: slot, resolution: .place(resolution), chip: expression.phrase.capitalizedFirst, systemImage: "mappin"))
                case .resolved(let candidate, _), .ambiguous(let candidate, _):
                    query.placeSlot = (slot.id, candidate, PlaceDescription(candidate), phrase)
                    query.plan.place = PlaceTarget(candidate.resolved)
                    let near = (override?.near ?? (expression.relation == .near)) && candidate.resolved.breadth == 0
                    slots.append(ResolvedSlot(slot: slot, resolution: .place(resolution), chip: near ? "Near \(candidate.name)" : candidate.name,
                                              systemImage: "mappin"))
                    if case .ambiguous(_, let candidates) = resolution {
                        query.picker = PlacePicker(slot: slot.id, phrase: phrase, question: "Which \(candidate.name)?",
                                                   choices: candidates.map { PlacePicker.Choice(candidate: $0, label: "\($0.context ?? $0.subtitle) · \($0.photoCount.formatted(.number.locale(locale)))") },
                                                   chosen: candidate.id)
                    }
                }
            case .media(let filter):
                query.mediaSlots.append(slot.id)
                slots.append(ResolvedSlot(slot: slot, resolution: .media(filter), chip: Self.mediaChip(filter), systemImage: filter.kinds == [.video] ? "film" : "photo"))
            case .event(let event):
                if query.plan.event == nil {
                    query.plan.event = event
                    query.eventSlot = slot.id
                }
                slots.append(ResolvedSlot(slot: slot, resolution: .event(event), chip: event == .trip ? "Trips" : "Abroad", systemImage: "airplane"))
            case .people, .visual, .text:
                slots.append(ResolvedSlot(slot: slot, resolution: .unsupported, chip: slot.value.phrase(locale: locale), systemImage: "info.circle"))
            }
        }
        query.plan.media = parsed.mediaFilter
        query.slots = slots
        return query
    }

    private func resolvePlace(_ expression: PlaceExpression, override: PlaceOverride?, environment: PlaceEnvironment, generation: Int, version: Int64,
                              isRerun: Bool) async throws -> PlaceResolution {
        let key = ResolutionKey(generation: generation, expression: expression, override: override)
        // A fresh search resolves again (a remembered pick may have changed); a re-run keeps what it showed.
        if isRerun, let cached = resolutions[key] { return cached.resolution }
        let resolution = try await places.resolve(expression, override: override, in: environment)
        if resolutions.count >= Self.resolutionCacheSize { resolutions.removeAll(keepingCapacity: true) }
        resolutions[key] = (version, resolution)
        return resolution
    }

    /// "Videos", "Favorite videos", "Screenshots", "Photos".
    static func mediaChip(_ filter: MediaFilter) -> String {
        filter.kinds == [.photo] && filter.flags.isEmpty ? "Photos" : filter.phrase.replacingOccurrences(of: "only photos", with: "photos").capitalizedFirst
    }
}

/// What a search knows about the index besides its rows: the home and the library's years.
struct EngineContext: Sendable {
    var generation: Int
    var version: Int64
    var time: TimeContext
    var home: HomeBaseRow?
    var summary: LibrarySummary
    /// The home country's place id (trip grouping: places outside it).
    var homeCountryPlace: Int32?
    var zone: TimeZone
}

private struct ResolutionKey: Hashable {
    var generation: Int
    var expression: PlaceExpression
    var override: PlaceOverride?
}

/// A query with its slots resolved, ready to score.
struct PreparedQuery: Sendable {
    var parsed: ParsedQuery
    var slots: [ResolvedSlot] = []
    var plan = ScoringPlan()
    var placeSlot: (id: Int, candidate: PlaceCandidate, description: PlaceDescription, phrase: String)?
    var placeFailure: (id: Int, reason: PlaceNotFound, phrase: String)?
    var timeSlots: [Int] = []
    var timeExpression: TimeExpression?
    var mediaSlots: [Int] = []
    var eventSlot: Int?
    var picker: PlacePicker?
    var searchedAppleMaps = false

    init(parsed: ParsedQuery) {
        self.parsed = parsed
    }

    var unsupported: [ResolvedSlot] { slots.filter { !$0.isSupported } }

    /// A place slot that resolved to nothing can't be scored; neither can a query with nothing to score.
    var canScore: Bool { placeFailure == nil && !plan.isEmpty && !(plan.time?.isFuture ?? false) }

    var resolved: ResolvedQuery {
        ResolvedQuery(parsed: parsed, slots: slots, picker: picker, searchedAppleMaps: searchedAppleMaps)
    }

    /// "at Al-Nakheel Park during Ramadan 2024": what the results show, for the unsupported notice.
    func showingPhrase(_ copy: SearchCopy) -> String? {
        var parts: [String] = []
        if let place = placeSlot { parts.append(place.description.phrase) }
        if let time = timeExpression, plan.time != nil { parts.append("\(copy.preposition(time)) \(copy.sentenceName(time))") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Photo counts around a point from the snapshot's grid (about a millisecond), for the place resolver.
struct SnapshotDensity: PlaceDensity {
    let snapshot: SearchSnapshot

    func count(near center: Coordinate, within radius: Double) async throws -> Int {
        snapshot.indices(near: center, within: radius).count
    }

    func ownDistances(from center: Coordinate, within radius: Double) async throws -> [Double] {
        snapshot.indices(near: center, within: radius, ownGPSOnly: true).compactMap { snapshot.position(Int($0))?.distance(to: center) }
    }

    func positions(inLocality placeID: Int64) async throws -> [Coordinate] {
        guard placeID >= 0, placeID <= Int64(Int32.max) else { return [] }
        let id = Int32(placeID)
        return (0..<snapshot.count).compactMap { i in
            snapshot.locality[i] == id && snapshot.placeSource[i] == SearchSnapshot.PositionSource.gps.rawValue ? snapshot.position(i) : nil
        }
    }
}
