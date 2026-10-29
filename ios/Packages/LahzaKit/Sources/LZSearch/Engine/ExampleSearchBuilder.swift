import Foundation
import LZIndex

extension SearchEngine {
    /// Up to `limit` searches this library can answer, each verified by a count of its Best matches (search spec §6.9),
    /// in this order: the latest trip with 20 items or more; the most photographed point of interest; last Ramadan (10
    /// or more) or last summer; videos from the home city this year, or favorites; and "N years ago" for the largest N
    /// of 10, 5, 3, 2 and 1 with 5 or more. Each needs 3 or more. Never asks Apple Maps; cached per index version,
    /// day ("last summer" and "N years ago" move with the date) and scope.
    ///
    /// Under a free search's scope a count is what tapping the example shows (the Best matches since the scope's
    /// start), so an example whose photos are all older is left out and the trip is the latest of the newest few (by
    /// label) with matches, none when no trip ends inside the scope.
    public func examples(reader: IndexReader, limit: Int = 5, index: SearchIndexContext = SearchIndexContext(),
                         scope: SearchScope = .wholeLibrary) async throws -> [ExampleSearch] {
        let version = try await reader.indexVersion()
        let today = TimeResolver(context: try await context(reader).time).today
        // The counts are those of this exact start (search and the examples read the same one through the day).
        let since: Int64? = if case .since(let date) = scope { Int64(date.timeIntervalSince1970.rounded(.down)) } else { nil }
        if let cached = examplesCache, cached.generation == reader.generation, cached.version == version, cached.day == today, cached.since == since {
            return Array(cached.examples.prefix(limit))
        }
        let started = ContinuousClock.now
        let summary = try await reader.summary()
        var examples: [ExampleSearch] = []
        if summary.assets > 0 {
            let trips = try await reader.trips()
            if let since {
                // Only photos taken since the start count, and "X trip" matches only photos in a trip: without a trip
                // ending since then (a day early, whatever the zone) there is nothing to try.
                let startDay = Int32((Double(since) / 86_400).rounded(.down)) - 1
                var tried = Set<String>()
                if trips.contains(where: { $0.endDay >= startDay }) {
                    for trip in trips where trip.itemCount >= 20 {
                        guard tried.count < Self.freeTripTries else { break }
                        guard tried.insert(trip.label).inserted else { continue }
                        if let example = try await verified("\(trip.label) trip", reader: reader, scope: scope) {
                            examples.append(example)
                            break
                        }
                    }
                }
            } else if let trip = trips.first(where: { $0.itemCount >= 20 }), let example = try await verified("\(trip.label) trip", reader: reader, scope: scope) {
                // The whole library's latest trip.
                examples.append(example)
            }
            if let place = try await reader.places(kinds: [.poi], minPhotos: 1, limit: 1).first,
               let example = try await verified(place.name, reader: reader, scope: scope) {
                examples.append(example)
            }
            if let example = try await verified("Last Ramadan", minimum: 10, reader: reader, scope: scope) {
                examples.append(example)
            } else if let example = try await verified("Last summer", reader: reader, scope: scope) {
                examples.append(example)
            }
            var videos: ExampleSearch?
            if let city = summary.homeCityName { videos = try await verified("Videos from \(city) this year", reader: reader, scope: scope) }
            if let videos {
                examples.append(videos)
            } else if let example = try await verified("Favorites", reader: reader, scope: scope) {
                examples.append(example)
            }
            for years in [10, 5, 3, 2, 1] {
                if let example = try await verified(years == 1 ? "1 year ago" : "\(years) years ago", minimum: 5, reader: reader, scope: scope) {
                    examples.append(example)
                    break
                }
            }
        }
        examplesCache = (reader.generation, version, today, since, examples)
        log.debug("Examples: \(examples.count) in \(ContinuousClock.now - started)", privacy: .public)
        return Array(examples.prefix(limit))
    }

    /// The most trips a free search's examples try (each is a whole search).
    static let freeTripTries = 3

    /// The search with its count, when it has at least `minimum` Best matches in `scope`.
    private func verified(_ text: String, minimum: Int = 3, reader: IndexReader, scope: SearchScope) async throws -> ExampleSearch? {
        let count = try await bestCount(text, reader: reader, scope: scope)
        return count >= minimum ? ExampleSearch(text: text, count: count) : nil
    }

    /// The Best matches of a typed search in `scope`, without Apple Maps.
    func bestCount(_ text: String, reader: IndexReader, scope: SearchScope = .wholeLibrary) async throws -> Int {
        let parsed = await parse(text, reader: reader)
        async let snapshotTask = reader.snapshot()
        let context = try await context(reader)
        let snapshot = try await snapshotTask
        let query = try await prepare(parsed, overrides: ResolutionOverrides(), reader: reader, writer: nil, snapshot: snapshot, context: context,
                                      appleMaps: false, isRerun: false, progress: nil)
        guard query.canScore, query.unsupported.isEmpty else { return 0 }
        var scorer = Scorer(snapshot: snapshot, plan: query.plan)
        let since: Int64? = if case .since(let date) = scope { Int64(date.timeIntervalSince1970) } else { nil }
        return scorer.run().hits.count { hit in
            let i = Int(hit.index)
            return hit.tier == .best && (since.map { !snapshot.isDated(i) || snapshot.utc[i] >= $0 } ?? true)
        }
    }
}
