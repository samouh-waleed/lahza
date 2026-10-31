import CoreML
import Foundation

/// Turns a description into an embedding comparable with the photos': the text tower and our tokenizer (content search
/// step 7), loaded when first needed and kept until released. Search asks only for words the bundled concept table
/// doesn't hold, and Ask prewarms it when it opens, so the 270 MB tower is never loaded for nothing.
public protocol TextEncoder: Sendable {
    /// The model's manifest, read without loading anything (nil: no text model on this iPhone).
    var model: EmbeddingModel? { get }
    /// The unit-length mean of the texts' embeddings (prompt templates of one query).
    func embed(_ texts: [String]) async throws -> [Float]
    /// Loads the tokenizer and the tower now, so the next search doesn't wait (Ask opening).
    func prewarm() async
    /// Lets go of the tower (memory pressure, or the image pass needing the room).
    func release() async
    /// How long the latest load took, and the latest encode.
    func timings() async -> (load: Duration?, encode: Duration?)
}

/// The text side of a model folder: `model.json`, `SigLIP2Text.mlmodelc` and `siglip2-vocab.lzvb`.
public actor ModelFolderTextEncoder: TextEncoder {
    public nonisolated let folder: URL
    public nonisolated let model: EmbeddingModel?
    private let computeUnits: MLComputeUnits
    private var loaded: (tokenizer: GemmaTokenizer, tower: CoreMLTextEmbedder)?
    private var loading: Task<(tokenizer: GemmaTokenizer, tower: CoreMLTextEmbedder), any Error>?
    private var loadTime: Duration?
    private var encodeTime: Duration?

    /// `folder` holds a converted model with its text tower and vocabulary; nothing is loaded yet.
    public init(folder: URL, mode: ComputeMode = .foreground) {
        self.folder = folder
        computeUnits = mode.computeUnits
        let model = try? EmbeddingModel.load(from: folder)
        let files = [model?.textModel, TokenizerVocabulary.fileName].compactMap { $0 }
        self.model = files.count == 2 && files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) } ? model : nil
    }

    public func embed(_ texts: [String]) async throws -> [Float] {
        let (tokenizer, tower) = try await load()
        guard !texts.isEmpty else { throw EmbeddingError.unexpectedOutput }
        let started = ContinuousClock.now
        var sum = [Float](repeating: 0, count: tower.model.dimension)
        for text in texts {
            let vector = try await tower.embed(tokenIDs: tokenizer.encode(text, limit: tower.model.textLength))
            for index in sum.indices { sum[index] += vector[index] }
        }
        encodeTime = ContinuousClock.now - started
        return VectorMath.normalized(sum)
    }

    public func prewarm() async {
        _ = try? await load()
    }

    public func release() {
        loading?.cancel()
        loading = nil
        loaded = nil
    }

    public func timings() -> (load: Duration?, encode: Duration?) { (loadTime, encodeTime) }

    /// The tokenizer and the tower, loaded once; callers waiting meanwhile share the one load.
    private func load() async throws -> (tokenizer: GemmaTokenizer, tower: CoreMLTextEmbedder) {
        if let loaded { return loaded }
        if let loading { return try await loading.value }
        let folder = folder, computeUnits = computeUnits
        let task = Task { () throws -> (tokenizer: GemmaTokenizer, tower: CoreMLTextEmbedder) in
            async let tower = CoreMLTextEmbedder.load(from: folder, computeUnits: computeUnits)
            let tokenizer = try GemmaTokenizer.load(from: folder)
            return (tokenizer, try await tower)
        }
        loading = task
        let started = ContinuousClock.now
        do {
            let value = try await task.value
            loadTime = ContinuousClock.now - started
            loaded = value
            loading = nil
            return value
        } catch {
            loading = nil
            throw error
        }
    }
}
