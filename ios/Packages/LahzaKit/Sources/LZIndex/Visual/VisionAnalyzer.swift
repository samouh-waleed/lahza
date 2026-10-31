import CoreGraphics
import Foundation
import LZLibrary
import Vision

/// Tags photos with Apple's built-in image tagger, on the iPhone, no download (content search L2): one local image per
/// photo (network off; a smaller local one of at least `minimumSide` pixels when the original is only in iCloud), and
/// one Vision perform of `ClassifyImageRequest` (revision 2), face and person rectangles and the aesthetics scores.
///
/// A tag is kept when it passes Apple's high-recall filter, `hasMinimumPrecision(0.1, forRecall: 0.8)`, with its
/// confidence and whether it passes the 0.7- and 0.9-precision filters (``VisualLabelFlags``).
public struct VisionAnalyzer: VisualAnalyzer {
    private let images: any AssetImageProvider
    /// The short side asked for, in pixels.
    public let side: Int
    public let minimumSide: Int

    public init(images: any AssetImageProvider, side: Int = 360, minimumSide: Int = 224) {
        self.images = images
        self.side = side
        self.minimumSide = minimumSide
    }

    public func supportedLabels() async -> [String] {
        ClassifyImageRequest().supportedIdentifiers
    }

    public func analyze(_ asset: VisualAsset) async -> VisualOutcome {
        switch await images.analysisImage(for: asset.localID, side: side, minimumSide: minimumSide) {
        case .image(let image), .reduced(let image):
            guard let analysis = try? await Self.analyze(image) else { return .failed }
            return .analysed(analysis)
        case .inCloud:
            return .inCloud
        case .missing:
            return .failed
        }
    }

    /// Vision over one image.
    public static func analyze(_ image: CGImage) async throws -> VisualAnalysis {
        var humans = DetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let handler = ImageRequestHandler(image)
        let (classifications, faces, people, aesthetics) = try await handler.perform(ClassifyImageRequest(), DetectFaceRectanglesRequest(), humans,
                                                                                      CalculateImageAestheticsScoresRequest())
        let labels = classifications.filter { $0.hasMinimumPrecision(0.1, forRecall: 0.8) }.map { observation in
            var flags: VisualLabelFlags = []
            if observation.hasMinimumRecall(0.01, forPrecision: 0.7) { flags.insert(.likely) }
            if observation.hasMinimumRecall(0.01, forPrecision: 0.9) { flags.insert(.precise) }
            return VisualLabel(name: observation.identifier, confidence: observation.confidence, flags: flags)
        }
        let largest = faces.map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
        return VisualAnalysis(labels: labels, faces: faces.count, humans: people.count, largestFace: largest, isUtility: aesthetics.isUtility,
                              aesthetic: Double(aesthetics.overallScore))
    }
}
