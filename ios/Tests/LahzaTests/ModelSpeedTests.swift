import CoreGraphics
import Foundation
import LZEmbedding
import LZIndex
import LZLibrary
import Photos
import Testing

/// The image tower over the seeded Simulator's real PhotoKit: 256-px local thumbnails, embedded and stored in a
/// vector file, as the indexer's visual pass will (Phase 0 spike S3's photos per second). The Simulator runs Core ML
/// on the Mac's CPU only, so these numbers are no iPhone's; they check the whole path works on iOS. Opt-in:
///
///     make model && make model-speed-sim
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["LZ_MODEL_DIR"] ?? "").isEmpty, "needs a converted model: LZ_MODEL_DIR"))
struct ModelSpeedTests {
    @Test func theSeededLibraryEmbedsFromThumbnails() async throws {
        try #require(LiveLibraryReader().access() == .full, "Lahza needs full photo access: make grant-photos")
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LZ_MODEL_DIR"]), isDirectory: true)
        let loadStarted = ContinuousClock.now
        let embedder = try await CoreMLImageEmbedder.load(from: folder)
        let loadTime = ContinuousClock.now - loadStarted

        let options = PHFetchOptions()
        options.fetchLimit = 200
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        let ids = (0..<fetched.count).map { fetched.object(at: $0).localIdentifier }
        try #require(ids.count >= 50, "seed the simulator first: make seed-photos")

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("model-speed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let database = try IndexDatabase.open(.directory(base))
        let store = try await VectorStore.open(database, modelID: embedder.model.id, dimension: embedder.model.dimension)

        let images = LiveAssetImageProvider()
        var thumbnails = Duration.zero, embeddings = Duration.zero, embedded = 0
        var entries: [VectorEntry] = []
        for (index, id) in ids.enumerated() {
            let fetchStarted = ContinuousClock.now
            guard case .image(let thumbnail) = await images.thumbnail(for: id, side: embedder.model.imageSize) else { continue }
            thumbnails += ContinuousClock.now - fetchStarted
            let embedStarted = ContinuousClock.now
            let vector = try await embedder.embed(thumbnail)
            embeddings += ContinuousClock.now - embedStarted
            embedded += 1
            entries.append(VectorEntry(assetID: Int64(index + 1), vector: vector))
        }
        try await store.upsert(entries)
        let scores = try await store.scores(for: try #require(entries.first?.vector))

        func perSecond(_ duration: Duration) -> String {
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            return String(format: "%.1f", Double(embedded) / max(seconds, 0.001))
        }
        print("MODEL simulator (CPU only): load \(loadTime); \(embedded) photos: thumbnails \(perSecond(thumbnails))/s, "
              + "embedding \(perSecond(embeddings))/s, together \(perSecond(thumbnails + embeddings))/s")
        #expect(embedded == ids.count, "every seeded photo is local")
        #expect(await store.count == embedded)
        #expect(scores.top(1).first?.assetID == 1, "a photo is its own nearest neighbour")
        await database.close()
    }
}
