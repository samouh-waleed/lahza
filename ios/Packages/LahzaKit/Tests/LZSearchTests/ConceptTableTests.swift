import Foundation
import LZEmbedding
import Testing
@testable import LZSearch

/// The bundled concept table (content search step 7) and the robust z-scores search calibrates descriptions with.
struct ConceptTableTests {
    @Test func theBundledTableIsSigLIPsAndCoversTheWordMap() throws {
        let table = try #require(ConceptTable.bundled)
        #expect(table.index.model == "siglip2-b16-256" && table.index.dimension == 768)
        #expect(table.count > 2_000 && table.index.templates.count == 5)
        for concept in VisualVocabulary.english.curatedConcepts {
            #expect(table.concept(for: concept.name) != nil, "\(concept.name)")
        }
        for label in VisualVocabulary.english.labels {
            #expect(table.label(label) != nil, "\(label)")
        }
        let soccer = try #require(table.concept(for: "soccer"))
        let negatives = table.index.entries[soccer].negatives
        #expect(negatives.count == 4 && negatives.allSatisfy { table.index.entries[$0].kind == .negative })
        #expect(table.concept(for: "Mirror Selfie") != nil && table.concept(for: "parties") != nil, "folded, and by its forms")
        #expect(table.concept(for: "a red car parked by the sea") == nil, "free text goes to the text model")
    }

    /// The vectors mean what their words mean: soccer is nearer football than sushi, and a dog nearer a puppy than a car.
    @Test func neighbouringWordsAreNear() throws {
        let table = try #require(ConceptTable.bundled)
        func vector(_ words: String) throws -> [Float] { table.vector(try #require(table.concept(for: words))) }
        let soccer = try vector("soccer"), football = try vector("football"), sushi = try vector("sushi")
        #expect(abs(VectorMath.cosine(soccer, soccer) - 1) < 0.002, "unit length within 16-bit precision")
        #expect(VectorMath.cosine(soccer, football) > VectorMath.cosine(soccer, sushi))
        #expect(VectorMath.cosine(try vector("dog"), try vector("puppy")) > VectorMath.cosine(try vector("dog"), try vector("car")))
    }

    @Test func aTableRoundTripsAndRejectsDamage() throws {
        let index = ConceptTable.Index(model: "m", revision: "r", dimension: 3, templates: ["{}"],
                                       entries: [ConceptTable.Entry(name: "a", kind: .concept, phrase: "a", negatives: [1]),
                                                 ConceptTable.Entry(name: "not a", kind: .negative, phrase: "not a")])
        let data = try ConceptTable.encode(index, vectors: [[1, 0, 0], [0, 0.6, 0.8]])
        let table = try ConceptTable(data: data)
        #expect(table.index == index && table.concept(for: "A") == 0)
        #expect(table.vector(1) == [0, 0.6, 0.8].map { Float(Float16($0)) })
        #expect(throws: (any Error).self) { try ConceptTable(data: data.dropLast()) }
        #expect(throws: (any Error).self) { try ConceptTable(data: Data("LZCV".utf8)) }
    }

    @Test func zScoresAreRobust() throws {
        // 99 cosines around 0.05 and one outlier: the median and MAD ignore it.
        let sample = (0..<99).map { Float(0.04 + 0.0002 * Float($0)) } + [0.9]
        let calibration = try #require(Calibration(sample: sample))
        #expect(abs(calibration.median - 0.05) < 0.001)
        #expect(calibration.z(0.9) > 50 && abs(calibration.z(calibration.median)) < 0.001)
        #expect(Calibration(sample: Array(sample.prefix(49))) == nil, "too few photos say nothing")
        #expect(Calibration(sample: Array(repeating: 0.1, count: 60)) == nil, "no spread, no scale")
        #expect(Calibration.score(z: 1) == 0 && Calibration.score(z: 2.75) == 0.5 && Calibration.score(z: 9) == 1)
    }
}
