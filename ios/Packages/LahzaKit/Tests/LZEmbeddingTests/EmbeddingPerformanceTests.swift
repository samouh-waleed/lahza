import CoreGraphics
import CoreML
import Foundation
import Testing
@testable import LZEmbedding

/// How fast the converted model runs on this Mac (opt-in: `make perf-kit`, with a model in `LZ_MODEL_DIR` from
/// `make model`). Phase 0 spike S3 asks the same of iPhones: ≥ 8 photos/s on an A14, text under 300 ms warm and
/// 3 s cold. A Mac is far faster, so these only catch a broken or very slow conversion.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LZ_PERF"] == "1" && ModelFolder.isAvailable))
struct EmbeddingPerformanceTests {
    /// A different 300×400 photo-like image each time (gradients and a block), so nothing is cached.
    private func image(_ seed: Int) throws -> CGImage {
        let width = 300, height = 400
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let hue = CGFloat(seed % 17) / 17
        context.setFillColor(CGColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1 - hue, green: 0.3, blue: hue, alpha: 1))
        context.fill(CGRect(x: seed % 100, y: seed % 150, width: 120, height: 160))
        return try #require(context.makeImage())
    }

    private func median(_ samples: [Duration]) -> Duration { samples.sorted()[samples.count / 2] }

    @Test func theModelRunsFastEnoughOnThisMac() async throws {
        let folder = try #require(ModelFolder.url)
        let parity = try ModelFolder.parity()

        // Image tower: load and first photo (cold), then photos per second (warm).
        var started = ContinuousClock.now
        let images = try await CoreMLImageEmbedder.load(from: folder)
        _ = try await images.embed(try image(0))
        let imageCold = ContinuousClock.now - started
        let photos = 100
        let inputs = try (1...photos).map(image)
        started = ContinuousClock.now
        for input in inputs { _ = try await images.embed(input) }
        let imageWarm = ContinuousClock.now - started
        let perSecond = Double(photos) / (Double(imageWarm.components.seconds) + Double(imageWarm.components.attoseconds) / 1e18)

        // Text tower: load and first text (cold), then the median of 20 (warm).
        started = ContinuousClock.now
        let texts = try await CoreMLTextEmbedder.load(from: folder)
        let ids = ModelFolder.unpadded(try #require(parity.prompts.first).tokenIDs, pad: texts.model.padTokenID)
        _ = try await texts.embed(tokenIDs: ids)
        let textCold = ContinuousClock.now - started
        var warm: [Duration] = []
        for prompt in parity.prompts + parity.prompts + parity.prompts + parity.prompts + parity.prompts {
            let start = ContinuousClock.now
            _ = try await texts.embed(tokenIDs: ModelFolder.unpadded(prompt.tokenIDs, pad: texts.model.padTokenID))
            warm.append(ContinuousClock.now - start)
        }
        print("PERF model \(images.model.id): image cold \(imageCold), \(String(format: "%.1f", perSecond)) photos/s warm over \(photos); "
              + "text cold \(textCold), warm median \(median(warm)) over \(warm.count)")
        #expect(perSecond >= 8, "S3's A14 bar; a Mac should beat it easily")
        #expect(median(warm) < .milliseconds(300))
        #expect(textCold < .seconds(3))
    }
}
