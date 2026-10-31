#if DEBUG
import Foundation
import LZEmbedding
import LZLibrary

/// The hero seed's stand-in for Vision (its pictures are drawn gradients): each item's ``SeedLabels``, found by its
/// seed id (the fake library) or its capture second (the seeded Simulator's PhotoKit). Anything else, such as the
/// Simulator's own samples, has no tags. It makes no vectors.
public struct SeedVisualAnalyzer: VisualAnalyzer {
    private let labels: [String]

    /// `labels`: the tag list it reports (Vision's, bundled with search, in tests).
    public init(labels: [String]) {
        self.labels = labels
    }

    public func supportedLabels() async -> [String] { labels }

    public func analyze(_ asset: VisualAsset, tags _: Bool, embedder _: (any ImageEmbedder)?) async -> VisualOutcome {
        guard let item = SeedScenario.hero.item(id: asset.localID) ?? asset.createdUTC.flatMap({ SeedScenario.hero.item(matchingUTC: $0) }) else {
            return .analysed(VisualAnalysis(labels: []))
        }
        let analysis = SeedLabels.analysis(for: item)
        if analysis.inCloud { return .inCloud }
        let tags = analysis.labels.sorted { $0.key < $1.key }.map { name, strength in
            VisualLabel(name: name, confidence: strength.confidence, flags: Self.flags(strength))
        }
        return .analysed(VisualAnalysis(labels: tags, faces: analysis.faces, humans: analysis.humans, largestFace: analysis.faces > 0 ? 0.05 : 0,
                                        isUtility: analysis.isUtility))
    }

    static func flags(_ strength: SeedLabels.Strength) -> VisualLabelFlags {
        switch strength {
        case .candidate: []
        case .likely: .likely
        case .precise: [.likely, .precise]
        }
    }
}
#endif
