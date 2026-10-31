import Foundation
import LZEmbedding
import LZIndex
import LZLibrary
import Synchronization
import Testing
@testable import LZSearch

/// Search with the image model (content search Milestone B, step 8) over the hero seed, whose stand-in vectors
/// (``SeedVectors``) come from the concept table's tag vectors: descriptions, fusion with the tags, words that aren't
/// places, the honest "no confident match", and nothing that worked before getting worse.
@Suite struct ContentSearchTests {
    /// A text model that answers a fixed vector for texts containing a key (the templates wrap the description).
    final class FakeText: TextEncoder {
        let answers: [(key: String, vector: [Float])]
        let asked = Mutex<[String]>([])

        init(answers: [(key: String, vector: [Float])]) {
            self.answers = answers
        }

        var model: EmbeddingModel? {
            try? JSONDecoder().decode(EmbeddingModel.self, from: Data("""
                {"id": "siglip2-b16-256", "dimension": 768, "imageSize": 256, "textLength": 64, "padTokenID": 0, "eosTokenID": 1, "lowercase": true,
                 "logitScale": 112.9, "logitBias": -16.77, "imageModel": "i", "textModel": "t", "source": "s", "revision": "r", "license": "l", "weights": "w"}
                """.utf8))
        }

        func embed(_ texts: [String]) async throws -> [Float] {
            asked.withLock { $0.append(contentsOf: texts) }
            guard let answer = answers.first(where: { answer in texts.contains { $0.contains(answer.key) } }) else {
                return SeedVectors.noiseVector(texts.first ?? "", dimension: 768)
            }
            return answer.vector
        }

        func prewarm() async {}
        func release() async {}
        func timings() async -> (load: Duration?, encode: Duration?) { (nil, nil) }
    }

    static let table = ConceptTable.bundled!

    static func concept(_ name: String) -> [Float] { table.vector(table.concept(for: name)!) }

    /// The tagged hero search with every seed item's stand-in vector.
    struct ModelSearch: Sendable {
        let search: HeroSearch
        let store: VectorStore

        init() async throws {
            search = try await HeroSearch(visual: true)
            store = try await VectorStore.open(search.index.database, modelID: "siglip2-b16-256", dimension: 768)
            try await SeedVectors.fill(store, reader: search.index.reader, table: ContentSearchTests.table)
        }

        func run(_ text: String, encoder: (any TextEncoder)? = nil, content: ContentSignals = .all, store: VectorStore? = nil) async throws -> SearchResult {
            let embedding = EmbeddingContext(store: store ?? self.store, table: ContentSearchTests.table, encoder: encoder)
            return try await search.engine.search(SearchRequest(text: text, content: content), reader: search.index.reader, writer: search.index.writer,
                                                  embedding: embedding)
        }
    }

    static let shared = Task { try await ModelSearch() }

    // MARK: Nothing gets worse

    @Test func aTaggedWordKeepsItsChipAndEveryBestPhoto() async throws {
        let model = try await Self.shared.value
        for word in ["soccer", "sunset", "fireworks", "beach"] {
            let before = try await model.search.search(word)
            let after = try await model.run(word)
            let beforeBest = Set(before.hits.filter { $0.tier == .best }.map(\.id))
            let afterBest = Set(after.hits.filter { $0.tier == .best }.map(\.id))
            #expect(!beforeBest.isEmpty, "\(word)")
            #expect(beforeBest.isSubset(of: afterBest), "\(word): every tag-Best photo stays Best")
            #expect(after.query.slots.first { $0.slot.kind == .visual }?.chip == "\(word) · photo tag", "\(word)")
        }
    }

    @Test func aPlaceAndADateStayWhatTheyWere() async throws {
        let model = try await Self.shared.value
        let result = try await model.run("soccer at Al-Nakheel Park")
        #expect(result.query.slots.map(\.chip).contains("Al-Nakheel Park"))
        #expect(result.query.slots.contains { $0.chip == "soccer · photo tag" })
        let nakheel = Set(SeedScenario.hero.items.filter { $0.tag == .nakheel }.map(\.id))
        #expect(result.hits.filter { $0.tier == .best }.allSatisfy { nakheel.contains($0.localID) })
    }

    // MARK: Descriptions

    @Test func aDescriptionFindsWhatItDescribes() async throws {
        let model = try await Self.shared.value
        let encoder = FakeText(answers: [("kicking a ball", Self.concept("soccer"))])
        let result = try await model.run("kids kicking a ball", encoder: encoder)
        let chips = result.query.slots.filter { $0.slot.kind == .visual }
        #expect(chips.count == 1 && chips[0].chip == "kids kicking a ball · AI search")
        guard case .visual(let match) = chips[0].resolution else {
            Issue.record("not a visual chip")
            return
        }
        #expect(match.described)
        let soccer = Set(SeedScenario.hero.items.filter { SeedLabels.analysis(for: $0).labels["soccer"] != nil }.map(\.id))
        let best = result.hits.filter { $0.tier == .best }
        #expect(!best.isEmpty && best.allSatisfy { soccer.contains($0.localID) }, "the model finds the soccer photos, and only them")
        #expect(best.contains { $0.reasons.contains { $0.text == "Looks like kids kicking a ball" } })
        #expect(encoder.asked.withLock { $0 }.contains("a photo of kids kicking a ball."), "the table's templates")
    }

    @Test func wordsThatArentAPlaceJoinTheDescription() async throws {
        let model = try await Self.shared.value
        let encoder = FakeText(answers: [("parked by the sea", Self.concept("beach"))])
        let result = try await model.run("a red car parked by the sea", encoder: encoder)
        #expect(result.query.slots.map(\.chip) == ["red car parked by the sea · AI search"])
        #expect(result.noMatch?.kind != .placeNotFound(.unconfirmed))
        #expect(!result.hits.filter { $0.tier == .best }.isEmpty)
        // A whole content word is never looked up on Apple Maps.
        let before = model.search.mapsSearches
        _ = try await model.run("people dancing at a party", encoder: FakeText(answers: []))
        #expect(model.search.mapsSearches == before)
    }

    @Test func aDescriptionNamesItsTaggedConcepts() async throws {
        let model = try await Self.shared.value
        let result = try await model.run("fireworks over the city", encoder: FakeText(answers: [("fireworks over the city", Self.concept("fireworks"))]))
        guard case .visual(let match)? = result.query.slots.first?.resolution else {
            Issue.record("no visual chip")
            return
        }
        #expect(match.tags == ["fireworks"], "the tags of the concepts it names add to it")
    }

    @Test func nothingConfidentIsSaidSo() async throws {
        let model = try await Self.shared.value
        let result = try await model.run("a purple elephant on a skateboard", encoder: FakeText(answers: []))
        #expect(result.noMatch?.kind == .notConfident)
        #expect(result.noMatch?.headline == "No confident match for “purple elephant on a skateboard”.")
        #expect(!result.hits.contains { $0.tier <= .more })
    }

    @Test func photosWithoutAVectorAreCountedNotRefused() async throws {
        let model = try await Self.shared.value
        // Half the vectors: a fresh file with only some photos.
        let database = model.search.index.database
        let half = try await VectorStore.open(database, modelID: "siglip2-b16-256-half", dimension: 768)
        try await SeedVectors.fill(half, reader: model.search.index.reader, table: Self.table)
        let all = await half.assetIDs.sorted()
        try await half.remove(all.prefix(all.count / 2))
        let encoder = FakeText(answers: [("kicking a ball", Self.concept("soccer"))])
        let result = try await model.run("kids kicking a ball", encoder: encoder, store: half)
        let embedded = all.count - all.count / 2
        #expect(result.coverage.visualLine?.hasPrefix("Checked \(embedded) of") == true, "\(result.coverage.visualLine ?? "-")")
    }

    // MARK: Without a vector

    @Test func withoutAVectorTaggedWordsWorkAsBefore() async throws {
        let model = try await Self.shared.value
        // Not in the table, and no text model: each tagged word is its own slot again.
        let result = try await model.run("beach sunset", encoder: nil)
        #expect(result.query.slots.map(\.chip) == ["beach · photo tag", "sunset · photo tag"])
        let off = try await model.search.search("beach sunset")
        #expect(Set(result.hits.map(\.id)) == Set(off.hits.map(\.id)))
    }

    @Test func theLayersCanBeTurnedOff() async throws {
        let model = try await Self.shared.value
        // Tags only: Milestone A.
        let tags = try await model.run("soccer", content: [.tags])
        let off = try await model.search.search("soccer")
        #expect(Set(tags.hits.map(\.id)) == Set(off.hits.map(\.id)))
        // The model only: no tag chip, no tag reasons.
        let embedding = try await model.run("soccer", content: [.model, .calibration])
        #expect(embedding.query.slots.first?.chip == "soccer · AI search")
        #expect(!embedding.hits.isEmpty && !embedding.hits.contains { $0.reasons.contains { $0.text.hasPrefix("Tagged") } })
        // Without calibration: SigLIP's own probability, which stand-in vectors never make sure.
        let raw = try await model.run("soccer", content: [.tags, .model])
        #expect(Set(off.hits.filter { $0.tier == .best }.map(\.id)).isSubset(of: Set(raw.hits.filter { $0.tier == .best }.map(\.id))))
    }

    // MARK: The model's score

    @Test func aNegativePromptAndNobodyLowerTheModelsScore() async throws {
        let model = try await Self.shared.value
        let snapshot = try await model.search.index.reader.snapshot()
        let database = try IndexDatabase.open(.inMemory)
        let store = try await VectorStore.open(database, modelID: "m", dimension: 3)
        // Every photo near [0, 0, 1]; photo A along the query, photo B a little closer to the negative.
        var entries = snapshot.id.enumerated().map { index, id in
            VectorEntry(assetID: id, vector: [Float(index % 7) * 0.01, Float(index % 5) * 0.01, 1])
        }
        let a = snapshot.id[0], b = snapshot.id[1]
        entries[0] = VectorEntry(assetID: a, vector: [1, 0, 0.05])
        entries[1] = VectorEntry(assetID: b, vector: [1, 0.6, 0.05])
        try await store.upsert(entries)
        let column = try #require(try await SearchEngine.column([1, 0, 0], negatives: [[0.6, 0.8, 0]], needsPerson: false, store: store,
                                                                 snapshot: snapshot, calibrated: true, model: nil))
        #expect(column.score[0] == 1 && column.z[0] > 10)
        #expect(abs(column.score[1] - 0.3) < 0.001, "the negative is closer: ×0.3")
        #expect(column.confident && column.embedded == snapshot.count)
        // A concept about people, on a checked photo of nobody: ×0.6.
        let nobody = (0..<snapshot.count).first { snapshot.isChecked($0) && snapshot.humans[$0] == 0 && snapshot.faces[$0] == 0 }
        if let nobody {
            var lone = entries
            lone[nobody] = VectorEntry(assetID: snapshot.id[nobody], vector: [1, 0, 0.05])
            try await store.upsert(lone)
            let person = try #require(try await SearchEngine.column([1, 0, 0], negatives: [], needsPerson: true, store: store, snapshot: snapshot,
                                                                     calibrated: true, model: nil))
            #expect(abs(person.score[nobody] - 0.6) < 0.001)
        }
    }

    // MARK: Whole outings and people

    @Test func anActivitysWholeOutingComesAlong() async throws {
        let model = try await Self.shared.value
        // The seed's soccer outings are tagged throughout; its swimming outings aren't.
        let with = try await model.run("swimming")
        let without = try await model.run("swimming", content: [.tags, .model, .calibration])
        let outing = with.hits.filter { hit in hit.reasons.contains { $0.text.hasPrefix("Same outing as") } }
        #expect(!outing.isEmpty && outing.allSatisfy { $0.tier == .more }, "the rest of an outing is More, never Best")
        #expect(Set(without.hits.filter { $0.tier == .best }.map(\.id)) == Set(with.hits.filter { $0.tier == .best }.map(\.id)))
        #expect(Set(without.hits.map(\.id)).isSubset(of: Set(with.hits.map(\.id))))
        // A thing seen (sunset) has no outing.
        let sunset = try await model.run("sunset")
        #expect(!sunset.hits.contains { $0.reasons.contains { $0.text.hasPrefix("Same outing as") } })
    }

    @Test func countsAndWithoutGoToThePeopleVisionSaw() {
        func parse(_ text: String) -> (String, Int?, Int?) {
            let (rest, count) = PeopleWords.parse(text)
            return (rest, count?.minimum, count?.maximum)
        }
        #expect(parse("beach without people") == ("beach", 0, 0))
        #expect(parse("nobody at the beach") == ("beach", 0, 0))
        #expect(parse("two people at the beach") == ("people at the beach", 2, 2))
        #expect(parse("3 friends hiking") == ("friends hiking", 3, 3))
        #expect(parse("me alone in the desert") == ("desert", 1, 1))
        #expect(parse("a group of friends at dinner") == ("friends at dinner", 3, nil))
        #expect(parse("sunset over the sea") == ("sunset over the sea", nil, nil))
        #expect(parse("two cars") == ("two cars", nil, nil), "only people are counted")
    }

    @Test func aCountFiltersByThePeopleCounted() async throws {
        let model = try await Self.shared.value
        let snapshot = try await model.search.index.reader.snapshot()
        let result = try await model.run("beach without people", encoder: FakeText(answers: [("beach", Self.concept("beach"))]))
        guard case .visual(let match)? = result.query.slots.first?.resolution else {
            Issue.record("no visual chip")
            return
        }
        #expect(match.people == "without people" && result.query.slots.first?.chip == "beach without people · AI search")
        let shown = result.hits.filter { $0.tier <= .more }
        #expect(!shown.isEmpty)
        for hit in shown {
            let index = Int(try #require(snapshot.indexByID[hit.id]))
            #expect(snapshot.humans[index] == 0 && snapshot.faces[index] == 0)
        }
    }

    @Test func descriptionsReadOnlyTheWordsAboutThePhotos() {
        func description(_ text: String, parts: [Int], slots: [(Int, SlotValue, Int, Int)]) -> String? {
            let parsed = ParsedQuery(text: text, slots: slots.map { QuerySlot(id: $0.0, value: $0.1, span: TextSpan(location: $0.2, length: $0.3)) })
            return Description.text(parsed, parts: Set(parts))?.text
        }
        // "people dancing at a party in Riyadh last year": the place and the date are left out.
        let text = "people dancing at a party in Riyadh last year"
        #expect(description(text, parts: [0, 1, 2], slots: [(0, .visual("people"), 0, 6), (1, .visual("dancing"), 7, 7), (2, .visual("party"), 20, 5),
                                                             (3, .visual("Riyadh"), 29, 6), (4, .visual("last year"), 36, 9)]) == "people dancing at a party")
        #expect(description("show me photos of the beach", parts: [0], slots: [(0, .visual("beach"), 22, 5)]) == "beach")
        #expect(Description.concepts(in: "a red car parked by the sea").map(\.name) == ["car", "sea"], "not park for parked")
        #expect(Description.concepts(in: "beach sunset").map(\.name) == ["beach", "sunset"])
    }
}
