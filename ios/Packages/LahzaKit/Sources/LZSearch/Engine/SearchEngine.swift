import Foundation
import LZCore
import LZEmbedding
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
/// Caches (the parse vocabulary, resolved places, the home and the library's years, example searches) are per index
/// version and are dropped on a memory warning.
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
    var examplesCache: (generation: Int, version: Int64, day: Int32, since: Int64?, examples: [ExampleSearch])?
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
                       embedding: EmbeddingContext = .off, isRerun: Bool = false,
                       progress: (@Sendable (SearchProgress) -> Void)? = nil) async throws -> SearchResult {
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
        var query = try await prepare(parsed, overrides: request.overrides, reader: reader, writer: writer, snapshot: snapshot, context: context,
                                      appleMaps: index.appleMapsEnabled, content: request.content, embedding: embedding, isRerun: isRerun,
                                      progress: progress)
        timings.resolve = ContinuousClock.now - resolveStarted
        progress?(.scoring)
        try Task.checkCancellation()

        let scoreStarted = ContinuousClock.now
        var scorer = Scorer(snapshot: snapshot, plan: query.plan)
        var (scored, unreliable) = query.canScore ? scorer.run() : ([], 0)
        // No confident match: no photo has a likely or precise tag, and the model is sure of none. Nothing is Best or
        // More; what it found waits behind "Show weaker" (content search, honest "no confident match").
        let unsure = query.plan.visual.first { target in target.embedding != nil && !(0..<snapshot.count).contains { target.isConfident($0) } }
        if unsure != nil {
            for index in scored.indices where scored[index].tier <= .locationUnknown { scored[index].tier = .weaker }
        } else if request.content.contains(.outings), query.plan.visual.contains(where: \.isActivity) {
            // An activity's whole outing: every outing with a Best photo brings its other photos into More (step 4).
            var anchors: [Int32: Int] = [:]
            for hit in scored where hit.tier == .best && snapshot.moment[Int(hit.index)] >= 0 { anchors[snapshot.moment[Int(hit.index)], default: 0] += 1 }
            if !anchors.isEmpty {
                query.plan.outings = anchors
                scorer = Scorer(snapshot: snapshot, plan: query.plan)
                (scored, unreliable) = scorer.run()
            }
        }
        // A free search keeps what was taken since its start (undated photos too) and counts the rest as locked.
        var hits = scored
        var locked = 0, lockedMatches = 0
        var since: Int64?
        if case .since(let date) = request.scope {
            let start = Int64(date.timeIntervalSince1970)
            since = start
            hits = scored.filter { hit in
                let i = Int(hit.index)
                guard snapshot.isDated(i), snapshot.utc[i] < start else { return true }
                if hit.tier == .best || hit.tier == .more { lockedMatches += 1 }
                if hit.tier != .weaker || request.showWeaker { locked += 1 }
                return false
            }
        }
        timings.score = ContinuousClock.now - scoreStarted

        let groupStarted = ContinuousClock.now
        let copy = SearchCopy(locale: locale, resolver: TimeResolver(context: context.time))
        // The first or last time: only that occasion's photos. A free search whose occasion is older than it covers
        // says so (never the earliest it covers as "the first time"); one it covers locks only its own older photos.
        var occasion: Occasion?
        var earlierOccasion = false
        var occasionTitle: String?
        if let order = query.orderSlot, order.order.isOccasion {
            let picker = OccasionPicker(snapshot: snapshot, query: query)
            if let pick = picker.pick(order.order, hits: scored, since: since) {
                occasionTitle = copy.occasionTitle(order.order, query: query)
                if pick.isEarlier {
                    earlierOccasion = true
                    hits = []
                } else {
                    hits = hits.filter { picker.contains($0, pick.chosen.key) }
                    locked = since.map { start in
                        scored.count { hit in
                            let i = Int(hit.index)
                            return snapshot.isDated(i) && snapshot.utc[i] < start && (hit.tier != .weaker || request.showWeaker)
                                && picker.contains(hit, pick.chosen.key)
                        }
                    } ?? 0
                    let others = pick.covered - 1
                    occasion = Occasion(order: order.order, isTrip: pick.chosen.isTrip, others: others,
                                        othersLabel: copy.otherOccasions(others, order: order.order, trips: pick.allTrips),
                                        showAll: order.order == .first ? [.replaceOrder(slot: order.id, .oldestFirst)] : [.remove(slot: order.id)])
                }
            }
        }
        var assembler = ResultAssembler(snapshot: snapshot, query: query, copy: copy, context: context)
        assembler.occasion = occasion.map { ($0, occasionTitle ?? "") }
        let shown = hits.filter { $0.tier != .weaker || request.showWeaker }
        let built = try await assembler.assemble(shown, reader: reader)
        let matched = hits.contains { $0.tier == .best || $0.tier == .more }
        var noMatch: NoMatch?
        if earlierOccasion, let occasionTitle, case .since(let date) = request.scope {
            noMatch = NoMatch(kind: .onlyEarlier, headline: copy.earlierOccasion(occasionTitle, since: date, now: clock.now), detail: nil, offers: [],
                              examples: [])
        } else if !matched, let unsure {
            noMatch = NoMatch(kind: .notConfident, headline: copy.notConfident(unsure.concept.name), detail: assembler.visualLine(for: unsure).map { $0 + "." },
                              offers: [], examples: [])
        } else if !matched, lockedMatches > 0, case .since(let date) = request.scope {
            // Everything that matched is older than a free search covers: say so, never "nothing".
            noMatch = NoMatch(kind: .onlyEarlier, headline: copy.onlyEarlier(since: date, now: clock.now), detail: nil, offers: [], examples: [])
        } else if !matched {
            var builder = NoMatchBuilder(snapshot: snapshot, query: query, copy: copy, context: context, index: index, since: since,
                                         showWeaker: request.showWeaker)
            // Related tags the person removed, for the tap that brings them back.
            let removed = query.plan.visual.filter { $0.related.isEmpty }.flatMap(\.concept.related)
            if !removed.isEmpty { builder.relatedPostings = try await reader.labelPostings(removed) }
            noMatch = try await builder.build(reader: reader)
            // No offer left (a lone name no place confirms, words Lahza can't search yet): the examples are the next tap.
            if noMatch?.offers.isEmpty == true, let examples = try? await examples(reader: reader, index: index, scope: request.scope) {
                noMatch?.examples = examples
            }
        }
        let start: Date? = if case .since(let date) = request.scope { date } else { nil }
        let coverage = assembler.coverage(searched: snapshot.count, index: index, unreliable: unreliable, borrowed: built.borrowed, since: start)
        timings.group = ContinuousClock.now - groupStarted
        timings.total = ContinuousClock.now - started

        let result = SearchResult(id: UUID(), query: query.resolved, sections: built.sections, totals: built.totals, coverage: coverage, noMatch: noMatch,
                                  unsupported: query.unsupported.map(\.slot),
                                  // "Showing all your photos …" only when photos match: above a no-match it would promise none (E23).
                                  unsupportedNotice: noMatch?.kind == .onlyUnsupported ? nil
                                      : copy.unsupportedNotice(query.unsupported, text: parsed.text, showing: matched ? query.showingPhrase(copy) : nil,
                                                               occasion: occasion == nil ? nil : occasionTitle, tags: snapshot.hasVisualPass),
                                  occasion: occasion, weakerCount: hits.count(where: { $0.tier == .weaker }), lockedCount: locked, timings: timings)
        log.info("Search: slots \(parsed.slots.map(\.kind.rawValue).joined(separator: ",")), \(result.totals.moments) moments, "
                 + "\(result.totals.items) items, \(hits.count(where: { $0.tier == .locationUnknown })) unlocated, \(locked) locked, "
                 + "no match \(noMatch.map { "\($0.kind)" } ?? "-"), "
                 + "Apple Maps \(query.resolved.searchedAppleMaps ? 1 : 0), \(timings.total) (resolve \(timings.resolve), score \(timings.score))",
                 privacy: .public)
        return result
    }

    /// A saved place was added, renamed or removed: the next parse rebuilds the vocabulary (its aliases), and places
    /// are resolved again.
    public func savedPlacesChanged() async {
        await vocabulary.release()
        resolutions = [:]
    }

    /// Drops the caches (memory warning): the vocabulary, resolved places, the time context and examples.
    public func releaseCaches() async {
        await vocabulary.release()
        resolutions = [:]
        contexts = nil
        examplesCache = nil
    }

    // MARK: Context

    /// The home, the library's years and the time context for relative dates. The index's part is kept per index
    /// version; "now" is read at every call, so "today" and "last weekend" move on while the library doesn't change.
    func context(_ reader: IndexReader) async throws -> EngineContext {
        let version = try await reader.indexVersion()
        if var contexts, contexts.generation == reader.generation, contexts.version == version {
            contexts.time.now = clock.now
            return contexts
        }
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
    /// at most one Apple Maps search), media and events as they are, and words about what's in photos to the photo tags
    /// they map to (when the index has a Vision pass), whose photos are read from the index.
    func prepare(_ parsed: ParsedQuery, overrides: ResolutionOverrides, reader: IndexReader, writer: UserDataWriter?, snapshot: SearchSnapshot,
                 context: EngineContext, appleMaps: Bool, content: ContentSignals = .all, embedding: EmbeddingContext = .off, isRerun: Bool,
                 progress: (@Sendable (SearchProgress) -> Void)?) async throws -> PreparedQuery {
        var query = PreparedQuery(parsed: parsed)
        // With the image model, the words about the photos become one description (``Description``).
        let describe = content.contains(.model) && embedding.isOn
        let resolver = TimeResolver(context: context.time)
        // A re-run (the index changed under a shown search) never asks Apple Maps again: it reads cached answers only.
        let environment = PlaceEnvironment(reader: reader, writer: writer, density: SnapshotDensity(snapshot: snapshot), appleMapsEnabled: appleMaps,
                                           searchRegion: context.home.map { Self.searchRegion(around: $0.center) },
                                           allowance: MapsAllowance(spent: isRerun))

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

        let places = try await preparePlaces(parsed, overrides: overrides, environment: environment, query: &query, reader: reader, context: context,
                                             describe: describe, table: embedding.table, isRerun: isRerun, progress: progress)
        var slots: [ResolvedSlot] = []
        var concepts: [(slot: Int, concept: VisualConcept, related: [String])] = []
        for slot in parsed.slots {
            switch slot.value {
            case .time(let expression):
                if case .unsupported(let message)? = timeResolution {
                    slots.append(ResolvedSlot(slot: slot, resolution: .unsupported, chip: message, systemImage: "info.circle"))
                } else if let constraint = (timeSlots.count == 1 ? timeResolution : resolver.resolve(expression))?.constraint {
                    var resolved = ResolvedSlot(slot: slot, resolution: .time(.constraint(constraint)), chip: constraint.label, systemImage: "calendar")
                    resolved.timePresets = resolver.presets(for: expression)
                    slots.append(resolved)
                }
            case .place:
                if let place = places[slot.id] { slots.append(place) }
            case .media(let filter) where describe && filter.isSelfiesOnly:
                // "mirror selfie": with the model, the words describe the photo (a mirror selfie isn't a front-camera one).
                slots.append(Self.visual(slot, slot.span?.substring(of: parsed.text) ?? filter.phrase))
            case .media(let filter):
                query.mediaSlots.append(slot.id)
                slots.append(ResolvedSlot(slot: slot, resolution: .media(filter), chip: Self.mediaChip(filter), systemImage: filter.kinds == [.video] ? "film" : "photo"))
            case .event(let event):
                if query.plan.event == nil {
                    query.plan.event = event
                    query.eventSlot = slot.id
                }
                slots.append(ResolvedSlot(slot: slot, resolution: .event(event), chip: event == .trip ? "Trips" : "Abroad", systemImage: "airplane"))
            case .order(let order):
                if query.orderSlot == nil { query.orderSlot = (slot.id, order) }
                slots.append(ResolvedSlot(slot: slot, resolution: .order(order), chip: Self.orderChip(order), systemImage: Self.orderSymbol(order)))
            case .visual(let words):
                if describe {
                    slots.append(ResolvedSlot(slot: slot, resolution: .unsupported, chip: words, systemImage: "info.circle"))
                } else if snapshot.hasVisualPass, content.contains(.tags), let concept = VisualVocabulary.english.concept(for: words) {
                    let withoutRelated = overrides.withoutRelatedTags.contains(slot.id)
                    concepts.append((slot.id, concept, withoutRelated ? [] : concept.related))
                    query.visualSlots.append(slot.id)
                    let match = VisualMatch(concept: concept.name, tags: Self.readable(concept.labels), related: Self.readable(concept.related),
                                            relatedRemoved: withoutRelated)
                    slots.append(ResolvedSlot(slot: slot, resolution: .visual(match), chip: concept.chip, systemImage: "tag"))
                } else {
                    slots.append(ResolvedSlot(slot: slot, resolution: .unsupported, chip: words, systemImage: "info.circle"))
                }
            case .people, .text:
                slots.append(ResolvedSlot(slot: slot, resolution: .unsupported, chip: slot.value.phrase(locale: locale), systemImage: "info.circle"))
            }
        }
        if describe {
            try await describeVisual(parsed, slots: &slots, query: &query, overrides: overrides, reader: reader, snapshot: snapshot, content: content,
                                     embedding: embedding)
        }
        if !concepts.isEmpty {
            let names = Array(Set(concepts.flatMap { $0.concept.labels + $0.related }))
            let postings = try await reader.labelPostings(names)
            query.plan.visual = concepts.map { VisualTarget(slot: $0.slot, concept: $0.concept, related: $0.related, postings: postings, snapshot: snapshot) }
        }
        // A selfie described by the model isn't the front camera's ("mirror selfie").
        query.plan.media = describe ? parsed.mediaFilter.flatMap(\.withoutSelfies) : parsed.mediaFilter
        query.slots = slots
        return query
    }

    /// The place slots, one place per query in v0. Known places are resolved first, then names a preposition
    /// introduced, then leftover words that only might be a place, so a leftover word ("kebab at Al-Nakheel Park")
    /// neither blocks the place nor spends the query's Apple Maps search. Once a place is searched, the other place
    /// slots are left out: a leftover word as words about what's in the photos, a name as a second place. Words that
    /// only might be a place and couldn't be looked up or confirmed ("Louvre" when Apple Maps names no place exactly
    /// that), and "my …" naming no saved place, are the query's failing place only when no other place was found;
    /// otherwise they are left out the same way.
    ///
    /// With the image model (`describe`), words that only might be a place are about the photos instead when they are
    /// content as a whole ("party", "snow": never looked up), or when no place confirms them ("parked", and a lone "Louvre"
    /// that Apple Maps doesn't name): they join the description. "my …" naming no saved place still says so (E22).
    private func preparePlaces(_ parsed: ParsedQuery, overrides: ResolutionOverrides, environment: PlaceEnvironment, query: inout PreparedQuery,
                               reader: IndexReader, context: EngineContext, describe: Bool = false, table: ConceptTable? = nil, isRerun: Bool,
                               progress: (@Sendable (SearchProgress) -> Void)?) async throws -> [Int: ResolvedSlot] {
        var outcomes: [Int: ResolvedSlot] = [:]
        var unresolved: [(slot: QuerySlot, expression: PlaceExpression, reason: PlaceNotFound, phrase: String, rank: Int)] = []
        let ranked = parsed.slots.enumerated().compactMap { offset, slot -> (slot: QuerySlot, expression: PlaceExpression, rank: Int, offset: Int)? in
            guard case .place(let expression) = slot.value else { return nil }
            return (slot, expression, Self.placeRank(expression, slot: slot, text: parsed.text), offset)
        }.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }

        func leftOut(_ slot: QuerySlot, _ expression: PlaceExpression, rank: Int, phrase: String) -> ResolvedSlot {
            rank == Self.leftoverRank ? Self.visual(slot, phrase) : ResolvedSlot(slot: slot, resolution: .unsupported, chip: expression.phrase, systemImage: "info.circle")
        }

        for (slot, expression, rank, _) in ranked {
            let phrase = slot.span?.substring(of: parsed.text) ?? expression.phrase
            if describe, case .named(let name, _, .maybe) = expression, overrides.places[slot.id] == nil, Description.isContent(name, table: table) {
                outcomes[slot.id] = Self.visual(slot, phrase)
                continue
            }
            guard query.placeSlot == nil, query.placeFailure == nil else {
                outcomes[slot.id] = leftOut(slot, expression, rank: rank, phrase: phrase)
                continue
            }
            if case .named(let name, _, _) = expression { progress?(.lookingUpPlace(name)) }
            let override = overrides.places[slot.id]
            let resolution = try await resolvePlace(expression, override: override, environment: environment, generation: reader.generation,
                                                    version: context.version, isRerun: isRerun)
            if environment.allowance.searched { query.searchedAppleMaps = true }
            if let missed = environment.allowance.missed { query.appleMapsMissed = missed }
            switch resolution {
            case .notFound(let reason) where describe && expression.isMaybe && reason != .notSaved:
                outcomes[slot.id] = Self.visual(slot, phrase)
            case .notFound(let reason):
                if reason == .unconfirmed || reason == .notSaved || expression.isMaybe {
                    unresolved.append((slot, expression, reason, phrase, rank))
                } else {
                    query.placeFailure = (slot.id, reason, phrase)
                    outcomes[slot.id] = ResolvedSlot(slot: slot, resolution: .place(resolution), chip: expression.phrase.capitalizedFirst, systemImage: "mappin")
                }
            case .resolved(let candidate, _), .ambiguous(let candidate, _):
                query.placeSlot = (slot.id, candidate, PlaceDescription(candidate), phrase)
                query.plan.place = PlaceTarget(candidate.resolved)
                let near = (override?.near ?? (expression.relation == .near)) && candidate.resolved.breadth == 0
                var resolved = ResolvedSlot(slot: slot, resolution: .place(resolution), chip: near ? "Near \(candidate.name)" : candidate.name,
                                            systemImage: "mappin")
                if case .area = candidate.resolved, let natural = candidate.naturalRadius {
                    resolved.radius = PlaceRadius(natural: natural, chosen: override?.radius, near: near)
                }
                outcomes[slot.id] = resolved
                if case .ambiguous(_, let candidates) = resolution {
                    query.picker = PlacePicker(slot: slot.id, phrase: phrase, question: "Which \(candidate.name)?",
                                               choices: candidates.map { PlacePicker.Choice(candidate: $0, label: "\($0.context ?? $0.subtitle) · \($0.photoCount.formatted(.number.locale(locale)))") },
                                               chosen: candidate.id)
                }
            }
        }
        for item in unresolved {
            if query.placeSlot == nil, query.placeFailure == nil {
                query.placeFailure = (item.slot.id, item.reason, item.phrase)
                outcomes[item.slot.id] = ResolvedSlot(slot: item.slot, resolution: .place(.notFound(item.reason)), chip: item.expression.phrase.capitalizedFirst,
                                                      systemImage: "mappin")
            } else {
                outcomes[item.slot.id] = leftOut(item.slot, item.expression, rank: item.rank, phrase: item.phrase)
            }
        }
        return outcomes
    }

    static let leftoverRank = 2

    /// Known places (and aliases, categories and picks) 0, a name a place preposition introduced 1, leftover words 2.
    static func placeRank(_ expression: PlaceExpression, slot: QuerySlot, text: String) -> Int {
        guard case .named(_, _, .maybe) = expression else { return 0 }
        guard let span = slot.span, let before = TextSpan(location: 0, length: span.location).substring(of: text) else { return leftoverRank }
        var words = before.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        while let last = words.last, ["the", "a", "an"].contains(last) { words.removeLast() }
        return words.last.map { Lexicon.english.placePrepositions[$0] != nil } == true ? 1 : leftoverRank
    }

    /// Words left out as about what's in the photos.
    private static func visual(_ slot: QuerySlot, _ words: String) -> ResolvedSlot {
        ResolvedSlot(slot: QuerySlot(id: slot.id, value: .visual(words), span: slot.span), resolution: .unsupported, chip: words, systemImage: "info.circle")
    }

    /// The region an Apple Maps search is biased to: home ±2°, its centre rounded to whole degrees so the request
    /// carries the home's area, never its position.
    static func searchRegion(around home: Coordinate) -> GeoRegion {
        GeoRegion(center: Coordinate(latitude: home.latitude.rounded(), longitude: home.longitude.rounded()), spanDegrees: 4)
    }

    private func resolvePlace(_ expression: PlaceExpression, override: PlaceOverride?, environment: PlaceEnvironment, generation: Int, version: Int64,
                              isRerun: Bool) async throws -> PlaceResolution {
        let key = ResolutionKey(generation: generation, expression: expression, override: override)
        // A fresh search resolves again (a remembered pick may have changed). A re-run keeps what it showed while the
        // index is the same; after a change it resolves again (a place read since then has its row and its photos),
        // keeping what it showed if the place can't be found without asking Apple Maps.
        if isRerun, let cached = resolutions[key] {
            if cached.version == version { return cached.resolution }
            let fresh = try await places.resolve(expression, override: override, in: environment)
            if case .notFound = fresh { return cached.resolution }
            resolutions[key] = (version, fresh)
            return fresh
        }
        let resolution = try await places.resolve(expression, override: override, in: environment)
        if resolutions.count >= Self.resolutionCacheSize { resolutions.removeAll(keepingCapacity: true) }
        resolutions[key] = (version, resolution)
        return resolution
    }

    /// "First time", "Last time", "Oldest first", "Newest first".
    static func orderChip(_ order: SearchOrder) -> String {
        switch order {
        case .first: "First time"
        case .last: "Last time"
        case .oldestFirst: "Oldest first"
        case .newestFirst: "Newest first"
        }
    }

    static func orderSymbol(_ order: SearchOrder) -> String {
        switch order {
        case .first: "flag"
        case .last: "clock.arrow.circlepath"
        case .oldestFirst, .newestFirst: "arrow.up.arrow.down"
        }
    }

    /// Tags as people read them, each once ("cake" for both `cake` and `cake_regular`).
    static func readable(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.map(VisualVocabulary.readable).filter { seen.insert($0).inserted }
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
    /// The visual slots searched by photo tags, in the plan's order.
    var visualSlots: [Int] = []
    /// The query's order: the first or last time, or oldest or newest first (the first order slot).
    var orderSlot: (id: Int, order: SearchOrder)?
    var picker: PlacePicker?
    var searchedAppleMaps = false
    var appleMapsMissed: PlaceNotFound?

    init(parsed: ParsedQuery) {
        self.parsed = parsed
    }

    var unsupported: [ResolvedSlot] { slots.filter { !$0.isSupported } }

    /// A place slot that resolved to nothing can't be scored; neither can a query with nothing to score.
    var canScore: Bool { placeFailure == nil && !plan.isEmpty && !(plan.time?.isFuture ?? false) }

    var resolved: ResolvedQuery {
        ResolvedQuery(parsed: parsed, slots: slots, picker: picker, searchedAppleMaps: searchedAppleMaps, appleMapsMissed: appleMapsMissed)
    }

    /// "at Al-Nakheel Park during Ramadan 2024": what the results show, for the unsupported notice.
    func showingPhrase(_ copy: SearchCopy) -> String? {
        var parts: [String] = []
        if !plan.visual.isEmpty { parts.append("tagged " + copy.list(plan.visual.map(\.concept.name))) }
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

    func members(level: MembershipLevel, placeID: Int64) async throws -> Int {
        guard placeID >= 0, placeID <= Int64(Int32.max) else { return 0 }
        let id = Int32(placeID)
        switch level {
        case .country: return snapshot.country.count { $0 == id }
        case .region: return snapshot.region.count { $0 == id }
        case .city: return (0..<snapshot.count).count { snapshot.city[$0] == id || snapshot.metro[$0] == id }
        case .locality: return snapshot.locality.count { $0 == id }
        }
    }

    func positions(inLocality placeID: Int64) async throws -> [Coordinate] {
        guard placeID >= 0, placeID <= Int64(Int32.max) else { return [] }
        let id = Int32(placeID)
        return (0..<snapshot.count).compactMap { i in
            snapshot.locality[i] == id && snapshot.placeSource[i] == SearchSnapshot.PositionSource.gps.rawValue ? snapshot.position(i) : nil
        }
    }
}
