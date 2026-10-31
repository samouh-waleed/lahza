import Foundation
import LZEmbedding
import LZIndex

/// What search needs from the image model (content search L3): the vector file, the bundled concept table, and the
/// text model for words the table lacks. Without a vector file, descriptions aren't searched and words with a photo tag
/// work as in Milestone A.
public struct EmbeddingContext: Sendable {
    public var store: VectorStore?
    /// The model the vectors belong to (its logit scale and bias, for the uncalibrated ablation).
    public var model: EmbeddingModel?
    public var table: ConceptTable?
    public var encoder: (any TextEncoder)?

    public static let off = EmbeddingContext()

    public init(store: VectorStore? = nil, model: EmbeddingModel? = nil, table: ConceptTable? = ConceptTable.bundled, encoder: (any TextEncoder)? = nil) {
        self.store = store
        self.model = model
        self.table = table.flatMap { table in model.map { $0.id == table.index.model } ?? true ? table : nil }
        self.encoder = encoder
    }

    /// Photos have vectors to search.
    public var isOn: Bool { store != nil }

    /// Any description can be searched, not only the table's words.
    public var freeText: Bool { store != nil && encoder?.model != nil }
}
