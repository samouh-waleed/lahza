import Foundation
import LZIndex

extension SearchEngine {
    /// Up to `limit` searches this library can answer, each verified by a count of its Best matches (search spec §6.9),
    /// in this order: the latest trip with 20 items or more; the most photographed point of interest; last Ramadan (10
    /// or more) or last summer; videos from the home city this year, or favorites; and "N years ago" for the largest N
    /// of 10, 5, 3, 2 and 1 with 5 or more. Each needs 3 or more. Never asks Apple Maps; cached per index version and
    /// day ("last summer" and "N years ago" move with the date).
    public func examples(reader: IndexReader, limit: Int = 5, index: SearchIndexContext = SearchIndexContext()) async throws -> [ExampleSearch] {
        let version = try await reader.indexVersion()
        let today = TimeResolver(context: try await context(reader).time).today
        if let cached = examplesCache, cached.generation == reader.generation, cached.version == version, cached.day == today {
            return Array(cached.examples.prefix(limit))
        }
        let started = ContinuousClock.now
        let summary = try await reader.summary()
        var examples: [ExampleSearch] = []
        if summary.assets > 0 {
            if let trip = try await reader.trips().first(where: { $0.itemCount >= 20 }),
               let example = try await verified("\(trip.label) trip", reader: reader) {
                examples.append(example)
            }
            if let place = try await reader.places(kinds: [.poi], minPhotos: 1, limit: 1).first,
               let example = try await verified(place.name, reader: reader) {
                examples.append(example)
            }
            if let example = try await verified("Last Ramadan", minimum: 10, reader: reader) {
                examples.append(example)
            } else if let example = try await verified("Last summer", reader: reader) {
                examples.append(example)
            }
            var videos: ExampleSearch?
            if let city = summary.homeCityName { videos = try await verified("Videos from \(city) this year", reader: reader) }
            if let videos {
                examples.append(videos)
            } else if let example = try await verified("Favorites", reader: reader) {
                examples.append(example)
            }
            for years in [10, 5, 3, 2, 1] {
                if let example = try await verified(years == 1 ? "1 year ago" : "\(years) years ago", minimum: 5, reader: reader) {
                    examples.append(example)
                    break
                }
            }
        }
        examplesCache = (reader.generation, version, today, examples)
        log.debug("Examples: \(examples.count) in \(ContinuousClock.now - started)", privacy: .public)
        return Array(examples.prefix(limit))
    }

    /// The search with its count, when it has at least `minimum` Best matches.
    private func verified(_ text: String, minimum: Int = 3, reader: IndexReader) async throws -> ExampleSearch? {
        let count = try await bestCount(text, reader: reader)
        return count >= minimum ? ExampleSearch(text: text, count: count) : nil
    }

    /// The Best matches of a typed search, without Apple Maps.
    func bestCount(_ text: String, reader: IndexReader) async throws -> Int {
        let parsed = await parse(text, reader: reader)
        async let snapshotTask = reader.snapshot()
        let context = try await context(reader)
        let snapshot = try await snapshotTask
        let query = try await prepare(parsed, overrides: ResolutionOverrides(), reader: reader, writer: nil, snapshot: snapshot, context: context,
                                      appleMaps: false, isRerun: false, progress: nil)
        guard query.canScore, query.unsupported.isEmpty else { return 0 }
        var scorer = Scorer(snapshot: snapshot, plan: query.plan)
        return scorer.run().hits.count(where: { $0.tier == .best })
    }
}

