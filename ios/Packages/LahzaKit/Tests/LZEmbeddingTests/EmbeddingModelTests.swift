import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Testing
@testable import LZEmbedding

struct EmbeddingModelTests {
    static let manifest = """
        {"id": "siglip2-b16-256", "dimension": 768, "imageSize": 256, "textLength": 64, "padTokenID": 0, "eosTokenID": 1,
         "lowercase": true, "logitScale": 112.0, "logitBias": -16.5, "imageModel": "SigLIP2Image.mlmodelc",
         "textModel": "SigLIP2Text.mlmodelc", "source": "https://huggingface.co/google/siglip2-base-patch16-256",
         "revision": "abc", "license": "Apache-2.0", "weights": "int8 per-channel"}
        """

    @Test func theManifestReadsFromAModelFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lz-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: EmbeddingError.missingModel("model.json")) { try EmbeddingModel.load(from: folder) }

        try Data(Self.manifest.utf8).write(to: folder.appendingPathComponent(EmbeddingModel.manifestName))
        let model = try EmbeddingModel.load(from: folder)
        #expect(model.id == "siglip2-b16-256" && model.dimension == 768 && model.textLength == 64)
        #expect(model.probability(cosine: 0.2) > 0.9, "112 × 0.2 − 16.5 = 5.9")
        #expect(model.probability(cosine: 0) < 0.001)
    }

    @Test func aMissingCompiledModelSaysWhich() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lz-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(Self.manifest.utf8).write(to: folder.appendingPathComponent(EmbeddingModel.manifestName))
        await #expect(throws: EmbeddingError.missingModel("SigLIP2Image.mlmodelc")) { try await CoreMLImageEmbedder.load(from: folder) }
        await #expect(throws: EmbeddingError.missingModel("SigLIP2Text.mlmodelc")) { try await CoreMLTextEmbedder.load(from: folder) }
    }

    @Test func aModelFolderSourceReadsTheManifestAndLoadsLater() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lz-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ModelFolderEmbedderSource(folder: folder).model == nil, "no manifest, no model")

        try Data(Self.manifest.utf8).write(to: folder.appendingPathComponent(EmbeddingModel.manifestName))
        let source = ModelFolderEmbedderSource(folder: folder)
        #expect(source.model?.id == "siglip2-b16-256")
        await #expect(throws: EmbeddingError.missingModel("SigLIP2Image.mlmodelc")) { try await source.embedder(.foreground) }
        #expect(await source.lastLoad() == nil)
        #expect(ComputeMode.foreground.computeUnits == .all && ComputeMode.background.computeUnits == .cpuOnly)
    }

    @Test func anEmptyOrBrokenOutputIsNoVector() throws {
        func output(_ values: [Float]) throws -> any MLFeatureProvider {
            try MLDictionaryFeatureProvider(dictionary: [CoreMLNetwork.output: MLMultiArray(MLShapedArray<Float>(scalars: values, shape: [1, values.count]))])
        }
        #expect(throws: EmbeddingError.unexpectedOutput) { try CoreMLNetwork.embedding(try output([0, 0, 0]), dimension: 3) }
        #expect(throws: EmbeddingError.unexpectedOutput) { try CoreMLNetwork.embedding(try output([1, .nan, 0]), dimension: 3) }
        #expect(throws: EmbeddingError.unexpectedOutput) { try CoreMLNetwork.embedding(try output([1, 0]), dimension: 3) }
        #expect(try CoreMLNetwork.embedding(try output([3, 4, 0]), dimension: 3) == [0.6, 0.8, 0])
    }

    @Test func cosinesOfUnitVectors() {
        #expect(VectorMath.normalized([3, 4]) == [0.6, 0.8])
        #expect(VectorMath.normalized([0, 0]) == [0, 0])
        #expect(abs(VectorMath.cosine([1, 0], [1, 1]) - 0.7071) < 0.0001)
    }
}

/// The folder `make model` writes (`LZ_MODEL_DIR`), when it holds a converted model.
enum ModelFolder {
    static var url: URL? {
        guard let path = ProcessInfo.processInfo.environment["LZ_MODEL_DIR"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(EmbeddingModel.manifestName).path) ? url : nil
    }

    static var isAvailable: Bool { url != nil }

    /// `parity.json`: PyTorch's fp32 embeddings for the test PNGs and prompts, written by the conversion script.
    struct Parity: Decodable {
        struct Image: Decodable { var file: String; var embedding: [Float] }
        struct Prompt: Decodable { var text: String; var tokenIDs: [Int32]; var embedding: [Float] }
        var minCosine: Float
        var images: [Image]
        var prompts: [Prompt]
    }

    static func parity() throws -> Parity {
        let url = try #require(url)
        return try JSONDecoder().decode(Parity.self, from: Data(contentsOf: url.appendingPathComponent("parity.json")))
    }

    static func image(_ file: String) throws -> CGImage {
        let url = try #require(url).appendingPathComponent(file)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The prompt's ids without the padding the script recorded.
    static func unpadded(_ ids: [Int32], pad: Int32) -> [Int32] {
        Array(ids.reversed().drop { $0 == pad }.reversed())
    }
}

/// The converted model against PyTorch (opt-in: `LZ_MODEL_DIR`, set by `make model` and `make perf-kit`).
@Suite(.enabled(if: ModelFolder.isAvailable))
struct EmbeddingParityTests {
    @Test func coreMLMatchesPyTorch() async throws {
        let folder = try #require(ModelFolder.url)
        let parity = try ModelFolder.parity()
        let images = try await CoreMLImageEmbedder.load(from: folder)
        let texts = try await CoreMLTextEmbedder.load(from: folder)
        for reference in parity.images {
            let embedding = try await images.embed(try ModelFolder.image(reference.file))
            #expect(embedding.count == images.model.dimension)
            let cosine = VectorMath.cosine(embedding, reference.embedding)
            #expect(cosine >= parity.minCosine, "\(reference.file): \(cosine)")
        }
        for prompt in parity.prompts {
            let embedding = try await texts.embed(tokenIDs: ModelFolder.unpadded(prompt.tokenIDs, pad: texts.model.padTokenID))
            let cosine = VectorMath.cosine(embedding, prompt.embedding)
            #expect(cosine >= parity.minCosine, "“\(prompt.text)”: \(cosine)")
        }
    }

    @Test func redAndBlueSquaresMatchTheirWords() async throws {
        let folder = try #require(ModelFolder.url)
        let parity = try ModelFolder.parity()
        let images = try await CoreMLImageEmbedder.load(from: folder)
        let texts = try await CoreMLTextEmbedder.load(from: folder)
        let red = try await images.embed(try ModelFolder.image("parity-red.png"))
        let blue = try await images.embed(try ModelFolder.image("parity-blue.png"))
        let words = Dictionary(uniqueKeysWithValues: parity.prompts.map { ($0.text, $0.tokenIDs) })
        let redWords = try await texts.embed(tokenIDs: ModelFolder.unpadded(try #require(words["a red square"]), pad: texts.model.padTokenID))
        let blueWords = try await texts.embed(tokenIDs: ModelFolder.unpadded(try #require(words["a blue square"]), pad: texts.model.padTokenID))
        #expect(VectorMath.cosine(red, redWords) > VectorMath.cosine(red, blueWords))
        #expect(VectorMath.cosine(blue, blueWords) > VectorMath.cosine(blue, redWords))
    }

    @Test func tooManyTokensIsAnError() async throws {
        let texts = try await CoreMLTextEmbedder.load(from: try #require(ModelFolder.url))
        let limit = texts.model.textLength
        await #expect(throws: EmbeddingError.tooManyTokens(count: limit + 1, limit: limit)) {
            try await texts.embed(tokenIDs: Array(repeating: 2, count: limit + 1))
        }
    }
}
