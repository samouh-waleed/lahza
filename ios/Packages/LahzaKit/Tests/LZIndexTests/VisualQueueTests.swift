import CoreGraphics
import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Synchronization
import Testing
@testable import LZIndex

/// P1a, the Vision pass: what the queue writes, in what order, what it does with photos only in iCloud, edits, a new
/// tag list and deleted photos, what search reads back, and Vision itself on this Mac.
@Suite struct VisualQueueTests {
    /// An analyzer that records what it was asked, in order, and answers from a script (tags by local id; ids in
    /// `inCloud` have no local image).
    final class ScriptedAnalyzer: VisualAnalyzer {
        private let state = Mutex<(asked: [String], labels: [String])>(([], ["soccer", "grass", "hiking"]))
        let inCloud: Set<String>
        let tags: [String: [VisualLabel]]

        init(tags: [String: [VisualLabel]] = [:], inCloud: Set<String> = []) {
            self.tags = tags
            self.inCloud = inCloud
        }

        var asked: [String] { state.withLock { $0.asked } }

        func setLabels(_ labels: [String]) { state.withLock { $0.labels = labels } }

        func supportedLabels() async -> [String] { state.withLock { $0.labels } }

        func analyze(_ asset: VisualAsset) async -> VisualOutcome {
            state.withLock { $0.asked.append(asset.localID) }
            if inCloud.contains(asset.localID) { return .inCloud }
            return .analysed(VisualAnalysis(labels: tags[asset.localID] ?? [], faces: 1, humans: 2, largestFace: 0.1, isUtility: false, aesthetic: 0.3))
        }
    }

    static let day: Int64 = 86_400
    static let now = Int64(Fixture.now.timeIntervalSince1970)

    /// An index over `assets`, synced.
    private func index(_ reader: FakeLibraryReader) async throws -> (IndexDatabase, LibraryIndexer) {
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader)
        await Fixture.sync(indexer)
        return (database, indexer)
    }

    private func queue(_ database: IndexDatabase, _ indexer: LibraryIndexer, _ analyzer: any VisualAnalyzer, clock: any AppClock = FixedClock(Fixture.now))
        -> VisualQueue {
        VisualQueue(database: database, analyzer: analyzer, clock: clock, notify: { await indexer.enqueue(.restructure) },
                    policy: VisualPolicy(batchSize: 4, concurrency: 1, checkpointInterval: .zero))
    }

    private func rows(_ database: IndexDatabase) async throws -> [String: (status: Int, labels: [String])] {
        try await database.read { db in
            var rows: [String: (Int, [String])] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT a.local_id, v.status, v.asset_id FROM asset_visual v JOIN asset a ON a.id = v.asset_id") {
                let labels = try String.fetchAll(db, sql: """
                    SELECT l.name FROM asset_label x JOIN visual_label l ON l.id = x.label_id WHERE x.asset_id = ? ORDER BY l.name
                    """, arguments: [row[2] as Int64])
                rows[row[0]] = (row[1], labels)
            }
            return rows
        }
    }

    // MARK: Writing

    @Test func tagsEveryPhotoAndRecordsThePass() async throws {
        let reader = FakeLibraryReader(.explicit([Fixture.photo("a", Self.now - Self.day), Fixture.photo("b", Self.now - 2 * Self.day),
                                                   Fixture.photo("c", nil)]))
        let (database, indexer) = try await index(reader)
        let versionBefore = try await IndexReader(database: database).indexVersion()
        let analyzer = ScriptedAnalyzer(tags: ["a": [VisualLabel(name: "soccer", confidence: 0.9, flags: [.likely, .precise])],
                                               "b": [VisualLabel(name: "grass", confidence: 0.3, flags: [])]])
        let queue = queue(database, indexer, analyzer)
        await queue.run()
        await indexer.settled()

        let written = try await rows(database)
        #expect(written["a"]?.status == VisualStatus.done.rawValue && written["a"]?.labels == ["soccer"])
        #expect(written["b"]?.labels == ["grass"])
        #expect(written["c"]?.status == VisualStatus.done.rawValue && written["c"]?.labels == [], "undated photos are tagged too")
        let meta = try await database.read { db in (try Meta.int(db, .visualVersion), try Meta.int(db, .visualLabelsHash)) }
        #expect(meta.0 == Int64(VisualPass.version))
        #expect(meta.1 != nil)
        #expect(try await IndexReader(database: database).indexVersion() > versionBefore, "search sees the tags")

        let postings = try await IndexReader(database: database).labelPostings(["soccer", "grass", "hiking"])
        #expect(postings["soccer"]?.map(\.flags) == [[.likely, .precise]])
        #expect(postings["grass"]?.map(\.confidence) == [0.3])
        #expect(postings["hiking"] == nil)

        let stats = try await IndexReader(database: database).visualStats()
        #expect(stats.checked == 3 && stats.labelRows == 2 && stats.supported == ["grass", "hiking", "soccer"])
        let samples = try await IndexReader(database: database).visualSamples(limit: 10)
        #expect(samples.map(\.localID) == ["a", "b", "c"], "newest first, undated last")
        #expect(samples.first?.humans == 2 && samples.first?.faces == 1)

        // A second run finds nothing due.
        await queue.run()
        #expect(analyzer.asked.count == 3)
    }

    @Test func theLastTwelveMonthsGoFirstNewestFirst() async throws {
        let old = Fixture.photo("old", Self.now - 400 * Self.day), older = Fixture.photo("older", Self.now - 800 * Self.day)
        let recent = Fixture.photo("recent", Self.now - 10 * Self.day), newest = Fixture.photo("newest", Self.now - Self.day)
        let (database, indexer) = try await index(FakeLibraryReader(.explicit([older, recent, Fixture.photo("undated", nil), old, newest])))
        let analyzer = ScriptedAnalyzer()
        await queue(database, indexer, analyzer).run()
        #expect(analyzer.asked == ["newest", "recent", "old", "older", "undated"])
    }

    @Test func photosOnlyInICloudWaitAndAreNeverCountedAsNo() async throws {
        let clock = FixedClock(Fixture.now)
        let (database, indexer) = try await index(FakeLibraryReader(.explicit([Fixture.photo("here", Self.now), Fixture.photo("cloud", Self.now - 60)])))
        let analyzer = ScriptedAnalyzer(inCloud: ["cloud"])
        let queue = queue(database, indexer, analyzer, clock: clock)
        await queue.run()
        #expect(try await rows(database)["cloud"]?.status == VisualStatus.pendingCloud.rawValue)
        let snapshot = try await IndexReader(database: database).snapshot()
        #expect(snapshot.hasVisualPass)
        #expect(snapshot.visualCounts == (checked: 1, pendingCloud: 1, unchecked: 0))
        let cloud = Int(try #require(snapshot.indexByID.first { $0.value == 1 }).value)
        #expect(!snapshot.isChecked(cloud))

        // Not asked again until the retry time.
        await queue.run()
        #expect(analyzer.asked.filter { $0 == "cloud" }.count == 1)
        await clock.advance(by: .seconds(Int(VisualPolicy.default.cloudRetry) + 1))
        await queue.run()
        #expect(analyzer.asked.filter { $0 == "cloud" }.count == 2)
    }

    @Test func anEditedPhotoIsTaggedAgain() async throws {
        let reader = FakeLibraryReader(.explicit([Fixture.photo("a", Self.now), Fixture.photo("b", Self.now - 60)]))
        let (database, indexer) = try await index(reader)
        let analyzer = ScriptedAnalyzer()
        let queue = queue(database, indexer, analyzer)
        await queue.run()
        var edited = Fixture.photo("a", Self.now)
        edited.adjustedDate = Fixture.now
        edited.hasAdjustments = true
        reader.update([edited])
        await Fixture.sync(indexer, .sync(.libraryChanged))
        await queue.run()
        #expect(analyzer.asked == ["a", "b", "a"])
    }

    @Test func aNewTagListTagsEveryPhotoAgain() async throws {
        let (database, indexer) = try await index(FakeLibraryReader(.explicit([Fixture.photo("a", Self.now), Fixture.photo("b", Self.now - 60)])))
        let analyzer = ScriptedAnalyzer()
        let queue = queue(database, indexer, analyzer)
        await queue.run()
        analyzer.setLabels(["soccer", "grass", "hiking", "padel"])
        await queue.run()
        #expect(analyzer.asked == ["a", "b", "a", "b"], "an iOS update changed Vision's list")
        #expect(try await IndexReader(database: database).visualStats().supported.contains("padel"))
    }

    @Test func aDeletedPhotoTakesItsTagsWithIt() async throws {
        let reader = FakeLibraryReader(.explicit([Fixture.photo("a", Self.now), Fixture.photo("b", Self.now - 60)]))
        let (database, indexer) = try await index(reader)
        let analyzer = ScriptedAnalyzer(tags: ["a": [VisualLabel(name: "soccer", confidence: 0.9, flags: [.precise])]])
        await queue(database, indexer, analyzer).run()
        reader.delete(["a"])
        await Fixture.sync(indexer, .sync(.libraryChanged))
        #expect(try await Fixture.count(database, "asset_label") == 0)
        #expect(try await Fixture.count(database, "asset_visual") == 1)
    }

    @Test func progressCountsWhatIsChecked() async throws {
        let (database, indexer) = try await index(FakeLibraryReader(.explicit(Fixture.library(10))))
        let queue = queue(database, indexer, ScriptedAnalyzer(inCloud: ["a00003"]))
        let stream = queue.progress
        await queue.run()
        var last: VisualProgress?
        for await progress in stream {
            last = progress
            if progress.state == .done { break }
        }
        #expect(last?.checked == 9 && last?.pendingCloud == 1 && last?.total == 10)
        #expect(last?.photosPerSecond != nil)
    }

    /// A cancelled run stops between photos and keeps what it wrote.
    @Test func aCancelledRunKeepsWhatItTagged() async throws {
        let (database, indexer) = try await index(FakeLibraryReader(.explicit(Fixture.library(40))))
        let analyzer = ScriptedAnalyzer()
        let queue = queue(database, indexer, analyzer)
        let task = Task { await queue.run() }
        task.cancel()
        await task.value
        let checked = try await IndexReader(database: database).visualStats().checked
        #expect(checked == analyzer.asked.count || checked <= 40)
        await queue.run()
        #expect(try await IndexReader(database: database).visualStats().checked == 40)
    }

    // MARK: Without a pass

    @Test func anIndexWithoutAPassHasNoVisualColumns() async throws {
        let (database, _) = try await index(FakeLibraryReader(.explicit(Fixture.library(3))))
        let snapshot = try await IndexReader(database: database).snapshot()
        #expect(!snapshot.hasVisualPass && snapshot.visualStatus.isEmpty && !snapshot.isChecked(0))
    }

    // MARK: Vision

    /// Vision's classifier runs here too (macOS 26): it knows soccer and hiking, and keeps the tags of a plain blue
    /// picture with their confidences, no face and no person.
    @Test func visionTagsAnImage() async throws {
        let labels = await VisionAnalyzer(images: FakeAssetImageProvider()).supportedLabels()
        #expect(labels.count > 1_000)
        #expect(labels.contains("soccer") && labels.contains("hiking"))
        let context = try #require(CGContext(data: nil, width: 360, height: 270, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 360, height: 270))
        let analysis = try await VisionAnalyzer.analyze(try #require(context.makeImage()))
        #expect(analysis.faces == 0 && analysis.humans == 0)
        #expect(!analysis.labels.isEmpty && analysis.labels.allSatisfy { (0...1).contains($0.confidence) })
        #expect(!analysis.labels.contains { $0.name == "soccer" || $0.name == "hiking" })
    }

    @Test func theSeedStandInTagsTheSeed() async throws {
        let analyzer = SeedVisualAnalyzer(labels: ["soccer"])
        let pitch = try #require(SeedScenario.hero.items.first { $0.tag == .nakheel && $0.number % 4 == 1 })
        guard case .analysed(let analysis) = await analyzer.analyze(VisualAsset(id: 1, localID: "elsewhere", createdUTC: pitch.utc)) else {
            Issue.record("not analysed")
            return
        }
        #expect(analysis.labels.contains(VisualLabel(name: "soccer", confidence: 0.9, flags: [.likely, .precise])))
        let orphan = try #require(SeedScenario.hero.items.first { $0.tag == .orphans })
        #expect(await analyzer.analyze(VisualAsset(id: 2, localID: orphan.id, createdUTC: nil)) == .inCloud)
    }
}
