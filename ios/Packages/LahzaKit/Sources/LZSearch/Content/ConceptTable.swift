import Foundation
import LZGeo

/// The bundled concept table (content search step 7): SigLIP 2 text vectors for the words people search most, so
/// common words are instant and never load the 270 MB text model. Each concept, Vision tag and negative prompt is the
/// unit-length mean of its phrase in a few prompt templates ("a photo of people hiking."). Built on the Mac by
/// `lz-concepts table` (`make concepts`) from `Tools/concepts/Concepts.txt`, the word map and Vision's tags, with the
/// same tokenizer and text tower the iPhone uses.
///
/// File: `LZCV`, version, the length of a JSON index (model, revision, templates, entries), the index, then one row of
/// 16-bit floats per entry.
public struct ConceptTable: Sendable {
    public struct Entry: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            /// A searchable idea ("hiking", "people dancing"): the word map's concepts and more.
            case concept
            /// One of Vision's tags, by its identifier ("sand_dune"), for "did you mean" and fusion.
            case label
            /// A look-alike that should not count ("soccer on a TV screen").
            case negative
        }

        /// The folded concept name, the tag's identifier, or the negative prompt.
        public var name: String
        public var kind: Kind
        /// What went into the templates.
        public var phrase: String
        /// Indices of this concept's negative prompts.
        public var negatives: [Int]

        public init(name: String, kind: Kind, phrase: String, negatives: [Int] = []) {
            self.name = name
            self.kind = kind
            self.phrase = phrase
            self.negatives = negatives
        }
    }

    public struct Index: Sendable, Hashable, Codable {
        /// The model the vectors belong to; a table for another model is never used.
        public var model: String
        public var revision: String
        public var dimension: Int
        /// "{}" is the phrase.
        public var templates: [String]
        public var entries: [Entry]

        public init(model: String, revision: String, dimension: Int, templates: [String], entries: [Entry]) {
            self.model = model
            self.revision = revision
            self.dimension = dimension
            self.templates = templates
            self.entries = entries
        }
    }

    public static let fileName = "Concepts"
    static let magic = Data("LZCV".utf8)
    static let version: UInt16 = 1

    public let index: Index
    private let vectors: Data
    private let concepts: [String: Int]
    private let labels: [String: Int]

    /// The table bundled with search (nil if it is missing or damaged, which a test rules out).
    public static let bundled: ConceptTable? = try? loadBundled()

    static func loadBundled() throws -> ConceptTable {
        guard let url = Bundle.module.url(forResource: fileName, withExtension: "lzcv") else { throw CocoaError(.fileNoSuchFile) }
        return try ConceptTable(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        guard data.count >= 12, data.prefix(4) == Self.magic, data.littleEndian(at: 4, as: UInt16.self) == Self.version else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let length = Int(data.littleEndian(at: 8, as: UInt32.self))
        let start = 12 + length + length % 2
        guard data.count >= start else { throw CocoaError(.fileReadCorruptFile) }
        index = try JSONDecoder().decode(Index.self, from: data.subdata(in: 12..<(12 + length)))
        guard data.count == start + index.entries.count * index.dimension * 2 else { throw CocoaError(.fileReadCorruptFile) }
        vectors = data.subdata(in: start..<data.count)
        var concepts: [String: Int] = [:], labels: [String: Int] = [:]
        for (position, entry) in index.entries.enumerated() {
            switch entry.kind {
            case .concept: if concepts[entry.name] == nil { concepts[entry.name] = position }
            case .label: labels[entry.name] = position
            case .negative: break
            }
        }
        self.concepts = concepts
        self.labels = labels
    }

    public var count: Int { index.entries.count }

    /// Entry `position`'s vector (unit length, within 16-bit precision).
    public func vector(_ position: Int) -> [Float] {
        let dimension = index.dimension
        return vectors.withUnsafeBytes { raw in
            (0..<dimension).map { Float(Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: (position * dimension + $0) * 2, as: UInt16.self)))) }
        }
    }

    /// The concept for typed words: as typed (folded), then by the word map's forms ("hikes" → "hike").
    public func concept(for words: String, vocabulary: VisualVocabulary = .english) -> Int? {
        let folded = PlaceNames.fold(words)
        if let position = concepts[folded] { return position }
        return vocabulary.forms(of: folded).lazy.compactMap { concepts[$0] }.first
    }

    /// One of Vision's tags, by its identifier.
    public func label(_ identifier: String) -> Int? { labels[identifier] }

    // MARK: Writing

    public static func encode(_ index: Index, vectors: [[Float]]) throws -> Data {
        precondition(vectors.count == index.entries.count && vectors.allSatisfy { $0.count == index.dimension })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(index)
        var data = magic
        data.append(littleEndian: version)
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt32(json.count))
        data.append(json)
        if json.count % 2 == 1 { data.append(0) }
        for vector in vectors {
            for value in vector { data.append(littleEndian: Float16(value).bitPattern) }
        }
        return data
    }
}

/// Robust z-scores (content search L3): SigLIP's own probability means little on personal photos (it reaches 0.5 only at
/// a cosine of about 0.149), so a cosine is judged against the same description's cosines over the library's random
/// reference sample: z = (cosine − median) / (1.4826 · MAD).
public struct Calibration: Sendable, Hashable {
    public var median: Float
    /// 1.4826 × the median absolute deviation: the standard deviation of a normal sample.
    public var scale: Float

    /// Fewer cosines than this say too little about the library: no embedding signal yet.
    public static let minimumSample = 50

    public init?(sample: [Float]) {
        guard sample.count >= Self.minimumSample else { return nil }
        let median = Self.median(sample)
        let deviation = Self.median(sample.map { abs($0 - median) })
        guard deviation > 0 else { return nil }
        self.median = median
        scale = 1.4826 * deviation
    }

    public func z(_ cosine: Float) -> Float { (cosine - median) / scale }

    /// s_emb: 0 up to z 1.5, 1 from z 4 (content search plan, placeholders tuned on the scoreboard).
    public static func score(z: Float) -> Double { Double(min(1, max(0, (z - 1.5) / 2.5))) }

    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

extension Data {
    func littleEndian<T: FixedWidthInteger>(at offset: Int, as _: T.Type) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
