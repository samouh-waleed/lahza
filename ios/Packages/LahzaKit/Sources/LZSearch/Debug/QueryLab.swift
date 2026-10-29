#if DEBUG
import Foundation
import LZGeo
import LZIndex

/// The DEBUG index inspector's query lab (search spec §8.3): one query through the engine, with what each step made of
/// it: the parsed slots as JSON (with their spans), the resolved dates as ISO local times, the place candidates with
/// their counts and sources, each slot's count alone, the timings and the top hits with their slot scores, S and tier.
/// It never writes to the index (no remembered Apple Maps answers, no picks) and shows asset row ids, never local
/// identifiers or positions.
public struct QueryLabReport: Sendable, Hashable {
    public struct Candidate: Sendable, Hashable {
        public var name: String
        public var subtitle: String
        public var photos: Int
        public var source: String
        public var match: Double
        public var isChosen: Bool
    }

    public struct SlotCount: Sendable, Hashable {
        /// "place Al-Nakheel Park", "time Last summer · Jun – Aug 2026".
        public var label: String
        /// Best matches of the slot alone (with the photo-type filter).
        public var best: Int
    }

    public struct Hit: Sendable, Hashable {
        public var assetID: Int64
        public var tier: Tier
        public var score: Double
        /// "place 1.00 · time 0.67" (unknown slots marked "?").
        public var slots: String
        /// The local date and time, or "undated".
        public var when: String
        public var isVideo: Bool
    }

    public var text: String
    /// `ParsedQuery` as pretty JSON (spans are UTF-16 offsets into `text`).
    public var parsedJSON: String
    /// "place → Al-Nakheel Park", "time → Last summer · Jun – Aug 2026".
    public var chips: [String]
    /// "2026-06-01T00:00 → 2026-09-01T00:00", then weekdays, minute windows, months and τ.
    public var time: [String]
    public var candidates: [Candidate]
    public var slotCounts: [SlotCount]
    public var timings: Timings
    /// Hits per tier (Weaker included).
    public var tiers: [Tier: Int]
    /// The best 20 by S.
    public var top: [Hit]
    public var searchedAppleMaps: Bool
}

extension SearchEngine {
    /// Runs `text` for the query lab. Apple Maps is asked as a search would (once, if the words need it) when
    /// `appleMaps` is on, but its answer isn't kept.
    public func lab(_ text: String, reader: IndexReader, appleMaps: Bool, limit: Int = 20) async throws -> QueryLabReport {
        let started = ContinuousClock.now
        var timings = Timings()
        let parsed = await parse(text, reader: reader)
        timings.parse = ContinuousClock.now - started

        let snapshotStarted = ContinuousClock.now
        let snapshot = try await reader.snapshot()
        let context = try await context(reader)
        timings.snapshot = ContinuousClock.now - snapshotStarted

        let resolveStarted = ContinuousClock.now
        let query = try await prepare(parsed, overrides: ResolutionOverrides(), reader: reader, writer: nil, snapshot: snapshot, context: context,
                                      appleMaps: appleMaps, isRerun: false, progress: nil)
        timings.resolve = ContinuousClock.now - resolveStarted

        let scoreStarted = ContinuousClock.now
        var scorer = Scorer(snapshot: snapshot, plan: query.plan)
        let hits = query.canScore ? scorer.run().hits : []
        timings.score = ContinuousClock.now - scoreStarted
        timings.total = ContinuousClock.now - started

        func best(_ plan: ScoringPlan) -> Int {
            var scorer = Scorer(snapshot: snapshot, plan: plan)
            return scorer.run().hits.count { $0.tier == .best }
        }
        var counts: [QueryLabReport.SlotCount] = []
        let plan = query.plan
        if let place = query.placeSlot { counts.append(.init(label: "place \(place.candidate.name)", best: best(ScoringPlan(place: plan.place, media: plan.media)))) }
        if let time = plan.time { counts.append(.init(label: "time \(time.label)", best: best(ScoringPlan(time: time, media: plan.media)))) }
        if let event = plan.event { counts.append(.init(label: "event \(event)", best: best(ScoringPlan(event: event, media: plan.media)))) }
        if let media = plan.media { counts.append(.init(label: "media \(media.phrase)", best: best(ScoringPlan(media: media)))) }

        var candidates: [QueryLabReport.Candidate] = []
        for slot in query.slots {
            guard case .place(let resolution) = slot.resolution else { continue }
            let chosen = resolution.chosen?.id
            candidates += resolution.candidates.map {
                .init(name: $0.name, subtitle: $0.subtitle, photos: $0.photoCount, source: "\($0.source)", match: $0.match.rawValue, isChosen: $0.id == chosen)
            }
        }

        let ranked = hits.sorted { ($0.score, $1.index) > ($1.score, $0.index) }.prefix(limit)
        let top = ranked.map { hit -> QueryLabReport.Hit in
            let i = Int(hit.index)
            let parts: [(String, SlotScore?)] = [("place", hit.place), ("time", hit.time), ("event", hit.event)]
            let slots = parts.compactMap { name, score in
                score.map { "\(name) \(String(format: "%.2f", $0.value))\($0.isUnknown ? "?" : "")" }
            }.joined(separator: " · ")
            return QueryLabReport.Hit(assetID: snapshot.id[i], tier: hit.tier, score: hit.score, slots: slots.isEmpty ? "media only" : slots,
                                      when: snapshot.isDated(i) ? Self.iso(snapshot.wall[i]) : "undated", isVideo: snapshot.isVideo(i))
        }

        return QueryLabReport(text: text, parsedJSON: Self.json(parsed), chips: query.slots.map { "\($0.slot.kind.rawValue) → \($0.chip)" },
                              time: plan.time.map(Self.describe) ?? [], candidates: candidates, slotCounts: counts, timings: timings,
                              tiers: Dictionary(grouping: hits, by: \.tier).mapValues(\.count), top: Array(top),
                              searchedAppleMaps: query.searchedAppleMaps)
    }

    private static func json(_ parsed: ParsedQuery) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(parsed)).flatMap { String(data: $0, encoding: .utf8) } ?? "–"
    }

    /// The constraint's parts, its ranges as ISO local times (wall seconds read as UTC give the local clock).
    private static func describe(_ time: TimeConstraint) -> [String] {
        var lines: [String] = []
        if let ranges = time.ranges {
            lines += ranges.isEmpty ? ["no range can match"] : ranges.map { "\(iso($0.lowerBound)) → \(iso($0.upperBound))" }
        }
        if let weekdays = time.weekdays { lines.append("weekdays \(weekdays.sorted().map(String.init).joined(separator: ","))") }
        if let windows = time.minuteWindows {
            lines.append("minutes " + windows.map { String(format: "%02d:%02d–%02d:%02d", $0.start / 60, $0.start % 60, $0.end / 60, $0.end % 60) }
                .joined(separator: ", "))
        }
        if let months = time.months { lines.append("months N \(months.north.sorted()) · S \(months.south.sorted())") }
        lines.append("τ \(time.tau / 3_600) h\(time.isFuture ? " · future" : "")")
        return lines
    }

    private static func iso(_ wall: Int64) -> String {
        let (year, month, day) = LocalTime.civil(day: Int32((Double(wall) / 86_400).rounded(.down)))
        let seconds = Int(((wall % 86_400) + 86_400) % 86_400)
        return String(format: "%04d-%02d-%02dT%02d:%02d", year, month, day, seconds / 3_600, seconds / 60 % 60)
    }
}
#endif
