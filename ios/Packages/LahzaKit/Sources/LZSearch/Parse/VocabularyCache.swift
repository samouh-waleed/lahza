import Foundation
import LZCore
import LZGeo
import LZIndex

/// The parse vocabulary of one index: rebuilt when the index version changes, but at most once per `debounce` while
/// versions churn (the first build bumps them every few hundred milliseconds), and dropped on a memory warning.
public actor VocabularyCache {
    private let gazetteer: Gazetteer
    private let clock: any AppClock
    private let debounce: Duration
    private var cached: (generation: Int, version: Int64, built: Date, vocabulary: PlaceVocabulary)?
    private let log = Log("search")

    public init(gazetteer: Gazetteer, clock: any AppClock, debounce: Duration = .seconds(2)) {
        self.gazetteer = gazetteer
        self.clock = clock
        self.debounce = debounce
    }

    /// The vocabulary for `reader`'s index (an empty one, with the gazetteer, without a reader or when reading fails).
    public func vocabulary(reader: IndexReader?) async -> PlaceVocabulary {
        guard let reader else { return PlaceVocabulary(gazetteer: gazetteer) }
        let version = (try? await reader.indexVersion()) ?? cached?.version ?? 0
        if let cached, cached.generation == reader.generation {
            let window = Double(debounce.components.seconds) + Double(debounce.components.attoseconds) / 1e18
            let recent = clock.now.timeIntervalSince(cached.built) < window
            if cached.version == version || recent { return cached.vocabulary }
        }
        do {
            let started = ContinuousClock.now
            async let names = reader.ownPlaceNames()
            async let saved = reader.savedPlaces()
            let vocabulary = PlaceVocabulary(savedAliases: PlaceVocabulary.aliases(for: try await saved), ownNames: try await names, gazetteer: gazetteer)
            cached = (reader.generation, version, clock.now, vocabulary)
            log.debug("Vocabulary built: \(vocabulary.ownNames.count) names, \(vocabulary.savedAliases.count) aliases in \(ContinuousClock.now - started)",
                      privacy: .public)
            return vocabulary
        } catch is CancellationError {
            // A newer keystroke or search took over: nothing went wrong.
            return cached?.vocabulary ?? PlaceVocabulary(gazetteer: gazetteer)
        } catch {
            log.error("Vocabulary build failed: \(type(of: error))", privacy: .public)
            return cached?.vocabulary ?? PlaceVocabulary(gazetteer: gazetteer)
        }
    }

    /// Drops the vocabulary (memory warning); the next parse rebuilds it.
    public func release() {
        cached = nil
    }
}
