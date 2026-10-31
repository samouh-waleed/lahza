import Foundation

/// What a converted embedding model is and how to feed it: the `model.json` manifest `make model` writes next to
/// the compiled Core ML models (Tools/model/convert_siglip2.py). The index records ``id`` with every vector, so a new
/// model re-embeds the library instead of mixing vectors.
public struct EmbeddingModel: Sendable, Hashable, Codable {
    /// "siglip2-b16-256".
    public var id: String
    /// 768: the length of every embedding, image or text.
    public var dimension: Int
    /// The square the image tower takes (256); Core ML stretches any image to it, as SigLIP's processor does.
    public var imageSize: Int
    /// Token ids the text tower takes (64): the text's ids, `<eos>`, then padding.
    public var textLength: Int
    public var padTokenID: Int32
    public var eosTokenID: Int32
    /// The tokenizer lowercases text first.
    public var lowercase: Bool
    /// Turn a cosine into SigLIP's logit (`cosine × logitScale + logitBias`); its sigmoid is a match probability.
    public var logitScale: Float
    public var logitBias: Float
    /// The compiled models' folder names (`SigLIP2Image.mlmodelc`).
    public var imageModel: String
    public var textModel: String
    /// Where the weights came from (Hugging Face URL, revision, license, weight format): for Acknowledgements.
    public var source: String
    public var revision: String
    public var license: String
    public var weights: String

    /// The manifest's file name inside a model folder.
    public static let manifestName = "model.json"

    /// Reads `model.json` from `folder`.
    public static func load(from folder: URL) throws -> EmbeddingModel {
        let url = folder.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw EmbeddingError.missingModel(manifestName) }
        return try JSONDecoder().decode(EmbeddingModel.self, from: Data(contentsOf: url))
    }

    /// The match probability SigLIP gives an image and a text whose embeddings have this cosine.
    public func probability(cosine: Float) -> Float {
        1 / (1 + exp(-(cosine * logitScale + logitBias)))
    }
}

public enum EmbeddingError: Error, Sendable, Hashable {
    /// A file the model folder should hold is missing (the manifest or a compiled model).
    case missingModel(String)
    /// More token ids than the text tower takes.
    case tooManyTokens(count: Int, limit: Int)
    /// The model returned no embedding, or one of the wrong length.
    case unexpectedOutput
}
