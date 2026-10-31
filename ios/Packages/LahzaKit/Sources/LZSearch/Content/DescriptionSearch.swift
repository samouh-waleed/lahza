import Foundation
import LZEmbedding
import LZIndex

/// A description against the photos' vectors (content search L3): its vector from the concept table when the words
/// are a concept, otherwise from the text model over the table's templates; then every photo's cosine, judged against
/// the library's reference sample (``Calibration``).
public enum DescriptionSearch {
    /// Where a description's vector came from.
    public enum Source: Sendable, Hashable {
        /// The bundled concept table: instant.
        case table(String)
        /// The text model on this iPhone.
        case model
    }

    /// The description's vector, or nil when the table hasn't the words and there is no text model.
    public static func vector(for words: String, table: ConceptTable?, encoder: (any TextEncoder)?) async throws -> (vector: [Float], source: Source)? {
        if let table, let position = table.concept(for: words) {
            return (table.vector(position), .table(table.index.entries[position].name))
        }
        guard let encoder, encoder.model != nil else { return nil }
        let templates = table?.index.templates ?? ["{}"]
        let phrase = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try await encoder.embed(templates.map { $0.replacingOccurrences(of: "{}", with: phrase) }), .model)
    }

    /// Every photo with a vector, scored against `vector`, calibrated over the reference photos among them (over all of
    /// them while fewer than ``Calibration/minimumSample`` reference photos have one).
    public static func scores(_ vector: [Float], store: VectorStore, reference: Set<Int64>) async throws -> DescriptionScores {
        let scores = try await store.scores(for: vector)
        var sample: [Float] = []
        for (id, cosine) in zip(scores.assetIDs, scores.scores) where reference.contains(id) { sample.append(cosine) }
        if sample.count < Calibration.minimumSample { sample = scores.scores }
        return DescriptionScores(assetIDs: scores.assetIDs, cosines: scores.scores, calibration: Calibration(sample: sample))
    }
}

/// Every photo's cosine with one description, and the calibration that turns them into z-scores.
public struct DescriptionScores: Sendable {
    public var assetIDs: [Int64]
    public var cosines: [Float]
    /// Nil while too few photos have a vector to judge.
    public var calibration: Calibration?

    /// The `limit` closest photos, closest first, with their z-scores (nil without a calibration).
    public func top(_ limit: Int) -> [(assetID: Int64, cosine: Float, z: Float?)] {
        zip(assetIDs, cosines).sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map { ($0.0, $0.1, calibration?.z($0.1)) }
    }

    /// How many photos reach `z`.
    public func count(atLeast z: Float) -> Int {
        guard let calibration else { return 0 }
        return cosines.count { calibration.z($0) >= z }
    }
}
