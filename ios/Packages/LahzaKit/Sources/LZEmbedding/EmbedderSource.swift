import CoreML
import Foundation

/// Where an embedding runs. In the foreground Core ML may use the Neural Engine and the GPU; in the background iOS 27
/// keeps the Neural Engine for apps with the inference entitlement, so the CPU does it (and its vectors are slightly
/// further from the reference: the index records which made each vector).
public enum ComputeMode: Sendable, Hashable, CaseIterable {
    case foreground
    case background

    public var computeUnits: MLComputeUnits {
        #if targetEnvironment(simulator)
        // The Simulator has no Neural Engine or GPU path for these models: anything but the CPU gives empty vectors.
        .cpuOnly
        #else
        switch self {
        case .foreground: .all
        case .background: .cpuOnly
        }
        #endif
    }
}

/// The image tower on this iPhone, if there is one: the index asks for it when it has photos to embed, and lets go of
/// it when it stops, so the 90 MB model is only held while it works.
public protocol ImageEmbedderSource: Sendable {
    /// The model's manifest, read without loading the model (nil: no model on this iPhone).
    var model: EmbeddingModel? { get }
    /// The loaded tower for `mode`, loaded once per mode (the first Core ML compile takes seconds).
    func embedder(_ mode: ComputeMode) async throws -> any ImageEmbedder
    /// Lets go of the loaded towers.
    func release() async
    /// How long the latest load took (the label lab).
    func lastLoad() async -> Duration?
}

/// The towers of a model folder (`make model`'s output: `model.json` and the compiled models).
public actor ModelFolderEmbedderSource: ImageEmbedderSource {
    public nonisolated let folder: URL
    public nonisolated let model: EmbeddingModel?
    private var loaded: [ComputeMode: CoreMLImageEmbedder] = [:]
    private var loadTime: Duration?

    /// `folder` holds a converted model; the manifest is read now, the towers when first asked for.
    public init(folder: URL) {
        self.folder = folder
        model = try? EmbeddingModel.load(from: folder)
    }

    public func embedder(_ mode: ComputeMode) async throws -> any ImageEmbedder {
        if let embedder = loaded[mode] { return embedder }
        let started = ContinuousClock.now
        let embedder = try await CoreMLImageEmbedder.load(from: folder, computeUnits: mode.computeUnits)
        loadTime = ContinuousClock.now - started
        loaded[mode] = embedder
        return embedder
    }

    public func release() {
        loaded = [:]
    }

    public func lastLoad() -> Duration? { loadTime }
}
