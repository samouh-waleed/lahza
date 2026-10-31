import Foundation
import LZCore

/// The index's one vector file, for the model on this iPhone: opened when first needed and again after a rebuild (a
/// new ``MetaKey/vectorIdentity``) or for another model. The embedding pass writes through it; search reads it.
public actor VectorIndex {
    private let database: IndexDatabase
    private var opened: VectorStore?

    init(database: IndexDatabase) {
        self.database = database
    }

    /// The store for `modelID`, opening the file when it isn't open for that model or no longer belongs to the index.
    /// The store it replaces is retired first, so one store at a time owns the file.
    public func store(modelID: String, dimension: Int) async throws -> VectorStore {
        if let opened, opened.modelID == modelID, opened.dimension == dimension, try await opened.isCurrent() { return opened }
        opened = nil
        let store = try await VectorStore.open(database, modelID: modelID, dimension: dimension)
        opened = store
        return store
    }

    /// The open store, if one is (search reads vectors only once the pass has opened the file).
    public var current: VectorStore? { opened }
}

/// The random photos the embedding pass does first, so search can calibrate a description's scores against the
/// library from the start (content search plan: robust z-scores over a 1,000-photo reference sample). The pick is a
/// pure function of the asset ids, so the pass and search agree without storing it.
public enum ReferenceSample {
    public static let size = 1_000

    /// The `count` ids whose mixed value is smallest (all of them when there are fewer).
    public static func pick(_ ids: some Sequence<Int64>, count: Int = size) -> Set<Int64> {
        Set(ids.map { (id: $0, key: mix($0)) }.sorted { $0.key < $1.key }.prefix(count).map(\.id))
    }

    /// SplitMix64's finaliser: neighbouring ids land far apart.
    static func mix(_ id: Int64) -> UInt64 {
        var z = UInt64(bitPattern: id) &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
