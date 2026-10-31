import Accelerate
import CoreGraphics
import CoreML
import Foundation
import Vision

/// Turns a photo into an embedding: a unit vector of ``EmbeddingModel/dimension`` floats. The indexer and search see
/// only this protocol, so the model behind it can change (the index then re-embeds, keyed by ``EmbeddingModel/id``).
public protocol ImageEmbedder: Sendable {
    var model: EmbeddingModel { get }
    func embed(_ image: CGImage) async throws -> [Float]
}

/// Turns a text into an embedding comparable with the images'.
public protocol TextEmbedder: Sendable {
    var model: EmbeddingModel { get }
    /// `tokenIDs`: the tokenizer's ids for the (lowercased) text and `<eos>`, unpadded. The Swift tokenizer is a later
    /// step; until then tests pass ids the conversion script recorded.
    func embed(tokenIDs: [Int32]) async throws -> [Float]
}

/// The SigLIP 2 image tower, compiled by `make model`. Core ML scales pixels to [-1, 1] and stretches the image to
/// the model's square, as SigLIP's own processor does.
public actor CoreMLImageEmbedder: ImageEmbedder {
    public nonisolated let model: EmbeddingModel
    private let network: MLModel
    private let constraint: MLImageConstraint

    private init(model: EmbeddingModel, network: MLModel, constraint: MLImageConstraint) {
        self.model = model
        self.network = network
        self.constraint = constraint
    }

    /// Loads the image tower from a model folder (`model.json` + the compiled model).
    public static func load(from folder: URL, computeUnits: MLComputeUnits = .all) async throws -> CoreMLImageEmbedder {
        let model = try EmbeddingModel.load(from: folder)
        let network = try await CoreMLNetwork.load(folder.appendingPathComponent(model.imageModel), computeUnits: computeUnits)
        guard let constraint = network.modelDescription.inputDescriptionsByName[CoreMLNetwork.imageInput]?.imageConstraint else {
            throw EmbeddingError.unexpectedOutput
        }
        return CoreMLImageEmbedder(model: model, network: network, constraint: constraint)
    }

    public func embed(_ image: CGImage) throws -> [Float] {
        let value = try MLFeatureValue(cgImage: image, constraint: constraint,
                                       options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let input = try MLDictionaryFeatureProvider(dictionary: [CoreMLNetwork.imageInput: value])
        return try CoreMLNetwork.embedding(try network.prediction(from: input), dimension: model.dimension)
    }
}

/// The SigLIP 2 text tower, compiled by `make model`: token ids in, padded here to ``EmbeddingModel/textLength``.
public actor CoreMLTextEmbedder: TextEmbedder {
    public nonisolated let model: EmbeddingModel
    private let network: MLModel

    private init(model: EmbeddingModel, network: MLModel) {
        self.model = model
        self.network = network
    }

    /// Loads the text tower from a model folder (`model.json` + the compiled model).
    public static func load(from folder: URL, computeUnits: MLComputeUnits = .all) async throws -> CoreMLTextEmbedder {
        let model = try EmbeddingModel.load(from: folder)
        let network = try await CoreMLNetwork.load(folder.appendingPathComponent(model.textModel), computeUnits: computeUnits)
        return CoreMLTextEmbedder(model: model, network: network)
    }

    public func embed(tokenIDs: [Int32]) throws -> [Float] {
        guard tokenIDs.count <= model.textLength else { throw EmbeddingError.tooManyTokens(count: tokenIDs.count, limit: model.textLength) }
        let padded = tokenIDs + Array(repeating: model.padTokenID, count: model.textLength - tokenIDs.count)
        let ids = MLMultiArray(MLShapedArray<Int32>(scalars: padded, shape: [1, model.textLength]))
        let input = try MLDictionaryFeatureProvider(dictionary: [CoreMLNetwork.textInput: MLFeatureValue(multiArray: ids)])
        return try CoreMLNetwork.embedding(try network.prediction(from: input), dimension: model.dimension)
    }
}

/// What the two towers share: their input and output names, loading, and reading the embedding back.
enum CoreMLNetwork {
    static let imageInput = "image"
    static let textInput = "input_ids"
    static let output = "embedding"

    static func load(_ url: URL, computeUnits: MLComputeUnits) async throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EmbeddingError.missingModel(url.lastPathComponent) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try await MLModel.load(contentsOf: url, configuration: configuration)
    }

    /// The output as floats, normalised again (the model normalises in 16-bit).
    static func embedding(_ output: any MLFeatureProvider, dimension: Int) throws -> [Float] {
        guard let array = output.featureValue(for: Self.output)?.multiArrayValue, array.count == dimension else {
            throw EmbeddingError.unexpectedOutput
        }
        return VectorMath.normalized(MLShapedArray<Float>(converting: array).scalars)
    }
}

/// Unit vectors and their cosines (a dot product, since both are unit length).
public enum VectorMath {
    public static func normalized(_ vector: [Float]) -> [Float] {
        let length = sqrt(vDSP.sumOfSquares(vector))
        return length > 0 ? vDSP.divide(vector, length) : vector
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vectors of different lengths")
        let length = sqrt(vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b))
        return length > 0 ? vDSP.dot(a, b) / length : 0
    }
}
