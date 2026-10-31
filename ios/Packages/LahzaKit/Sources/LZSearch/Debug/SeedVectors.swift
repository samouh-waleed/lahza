#if DEBUG
import Foundation
import LZEmbedding
import LZIndex
import LZLibrary

/// The hero seed's stand-in for the image model (its pictures are drawn gradients, as for Vision's tags): each item's
/// vector is the concept table's vectors of its ``SeedLabels`` tags, weighted by how sure the tag is, plus a fixed
/// noise of its own; an item without tags is noise alone. The tag vectors are taken less their mean: SigLIP's text
/// vectors share one large direction (any two tags are about 0.9 alike), which real photos' vectors don't. A description
/// then scores the seed the way the model would score real photos of those things. Kit tests and `-LZSeed` fill the
/// vector file with these.
public enum SeedVectors {
    /// The noise's share of a tagged item's vector.
    static let noise: Float = 0.5

    /// `item`'s stand-in vector (unit length).
    public static func vector(for item: SeedItem, table: ConceptTable, mean known: [Float]? = nil) -> [Float] {
        let dimension = table.index.dimension
        var vector = noiseVector(item.id, dimension: dimension)
        let analysis = SeedLabels.analysis(for: item)
        if !analysis.labels.isEmpty {
            let mean = known ?? labelMean(table)
            vector = vector.map { $0 * noise }
            for (name, strength) in analysis.labels {
                guard let position = table.label(name) else { continue }
                let weight: Float = switch strength {
                case .precise: 1
                case .likely: 0.7
                case .candidate: 0.4
                }
                for (index, value) in table.vector(position).enumerated() { vector[index] += weight * (value - mean[index]) }
            }
        }
        return VectorMath.normalized(vector)
    }

    /// The mean of the table's Vision tag vectors (the direction every text vector shares).
    static func labelMean(_ table: ConceptTable) -> [Float] {
        var mean = [Float](repeating: 0, count: table.index.dimension)
        let labels = table.index.entries.indices.filter { table.index.entries[$0].kind == .label }
        for position in labels {
            for (index, value) in table.vector(position).enumerated() { mean[index] += value / Float(labels.count) }
        }
        return mean
    }

    /// Writes every seed item's vector into `store`; assets are matched by seed id (the fake library) or by capture
    /// second (the seeded Simulator), as ``SeedVisualAnalyzer`` matches them. Returns how many were written.
    @discardableResult
    public static func fill(_ store: VectorStore, reader: IndexReader, table: ConceptTable) async throws -> Int {
        let snapshot = try await reader.snapshot()
        let localIDs = try await reader.localIdentifiers(for: snapshot.id)
        var entries: [VectorEntry] = []
        let mean = labelMean(table)
        for (index, id) in snapshot.id.enumerated() {
            let utc = snapshot.utc[index]
            guard let item = localIDs[id].flatMap({ SeedScenario.hero.item(id: $0) }) ?? (utc == Int64.min ? nil : SeedScenario.hero.item(matchingUTC: utc))
            else { continue }
            entries.append(VectorEntry(assetID: id, vector: vector(for: item, table: table, mean: mean)))
        }
        try await store.upsert(entries)
        return entries.count
    }

    /// A fixed pseudo-random unit vector for an id (SplitMix64, Box–Muller).
    static func noiseVector(_ id: String, dimension: Int) -> [Float] {
        var state = id.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0100_0000_01b3 }
        func next() -> Double {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        let values = (0..<dimension).map { _ in Float(sqrt(-2 * log(max(next(), 1e-12))) * cos(2 * .pi * next())) }
        return VectorMath.normalized(values)
    }
}
#endif

#if DEBUG
extension SeedVectors {
    /// The model the stand-in vectors pretend to be (the concept table's), for `-LZSeed`.
    public static let model: EmbeddingModel? = try? JSONDecoder().decode(EmbeddingModel.self, from: Data("""
        {"id": "siglip2-b16-256", "dimension": 768, "imageSize": 256, "textLength": 64, "padTokenID": 0, "eosTokenID": 1, "lowercase": true,
         "logitScale": 112.9, "logitBias": -16.77, "imageModel": "-", "textModel": "-", "source": "seed stand-in", "revision": "-",
         "license": "-", "weights": "-"}
        """.utf8))
}
#endif
