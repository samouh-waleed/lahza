import Foundation

/// SigLIP 2's tokenizer data (Gemma's BPE vocabulary) in Lahza's own compact file, `siglip2-vocab.lzvb`, built on the
/// Mac from Hugging Face's `tokenizer.json` (`make tokenizer`). It holds what encoding needs and nothing else: the
/// pieces of one Unicode scalar, the 256 byte pieces, every merge with its rank, and the added tokens. The file is
/// memory-mapped and searched in place, so loading it costs nothing; the English trim (step 11) rewrites it smaller.
///
/// Layout, little-endian: a 32-byte header (`LZVB`, version, `<eos>`, `<pad>`, `<unk>`, then the scalar, merge and
/// added-token counts); 256 byte-piece ids (−1 when absent); (scalar, id) pairs sorted by scalar; (left << 32 | right,
/// rank, merged) merges sorted by pair; then each added token as (id, byte count, UTF-8).
public struct TokenizerVocabulary: Sendable {
    public static let fileName = "siglip2-vocab.lzvb"
    static let magic = Data("LZVB".utf8)
    static let version: UInt16 = 1
    static let headerSize = 32
    static let scalarStride = 8
    static let mergeStride = 16

    public let eos: Int32
    public let pad: Int32
    public let unk: Int32
    public let mergeCount: Int
    private let data: Data
    private let byteIDs: [Int32]
    private let scalarsOffset: Int
    private let scalarCount: Int
    private let mergesOffset: Int
    /// Added tokens by their first scalar, longest first.
    let added: [UInt32: [(scalars: [UInt32], id: Int32)]]

    /// Reads a vocabulary file (memory-mapped).
    public static func load(_ url: URL) throws -> TokenizerVocabulary {
        guard FileManager.default.fileExists(atPath: url.path) else { throw EmbeddingError.missingModel(url.lastPathComponent) }
        return try TokenizerVocabulary(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        guard data.count >= Self.headerSize + 256 * 4, data.prefix(4) == Self.magic, data.integer(at: 4, as: UInt16.self) == Self.version else {
            throw EmbeddingError.unexpectedOutput
        }
        self.data = data
        eos = data.integer(at: 8, as: Int32.self)
        pad = data.integer(at: 12, as: Int32.self)
        unk = data.integer(at: 16, as: Int32.self)
        scalarCount = Int(data.integer(at: 20, as: UInt32.self))
        mergeCount = Int(data.integer(at: 24, as: UInt32.self))
        let addedCount = Int(data.integer(at: 28, as: UInt32.self))
        byteIDs = (0..<256).map { data.integer(at: Self.headerSize + $0 * 4, as: Int32.self) }
        scalarsOffset = Self.headerSize + 256 * 4
        mergesOffset = scalarsOffset + scalarCount * Self.scalarStride
        var offset = mergesOffset + mergeCount * Self.mergeStride
        guard offset <= data.count else { throw EmbeddingError.unexpectedOutput }
        var added: [UInt32: [(scalars: [UInt32], id: Int32)]] = [:]
        for _ in 0..<addedCount {
            guard offset + 8 <= data.count else { throw EmbeddingError.unexpectedOutput }
            let id = data.integer(at: offset, as: Int32.self)
            let length = Int(data.integer(at: offset + 4, as: UInt32.self))
            guard offset + 8 + length <= data.count, let text = String(data: data[(data.startIndex + offset + 8)..<(data.startIndex + offset + 8 + length)], encoding: .utf8),
                  let first = text.unicodeScalars.first else { throw EmbeddingError.unexpectedOutput }
            added[first.value, default: []].append((text.unicodeScalars.map(\.value), id))
            offset += 8 + length
        }
        self.added = added.mapValues { $0.sorted { $0.scalars.count > $1.scalars.count } }
    }

    /// The piece of one scalar, if the vocabulary has it.
    func id(ofScalar scalar: UInt32) -> Int32? {
        var low = 0, high = scalarCount - 1
        while low <= high {
            let middle = (low + high) / 2
            let found = data.integer(at: scalarsOffset + middle * Self.scalarStride, as: UInt32.self)
            if found == scalar { return data.integer(at: scalarsOffset + middle * Self.scalarStride + 4, as: Int32.self) }
            if found < scalar { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// The piece `<0xNN>` for a byte (byte fallback), if the vocabulary has it.
    func id(ofByte byte: UInt8) -> Int32? {
        let id = byteIDs[Int(byte)]
        return id >= 0 ? id : nil
    }

    /// The merge of two pieces, with its rank (lower merges first).
    func merge(_ left: Int32, _ right: Int32) -> (rank: UInt32, merged: Int32)? {
        let key = UInt64(UInt32(bitPattern: left)) << 32 | UInt64(UInt32(bitPattern: right))
        var low = 0, high = mergeCount - 1
        while low <= high {
            let middle = (low + high) / 2
            let base = mergesOffset + middle * Self.mergeStride
            let found = data.integer(at: base, as: UInt64.self)
            if found == key { return (data.integer(at: base + 8, as: UInt32.self), data.integer(at: base + 12, as: Int32.self)) }
            if found < key { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    // MARK: Writing

    /// A vocabulary file. `merges` are (left, right, merged) piece ids in rank order (the first merges first).
    public static func encode(scalars: [UInt32: Int32], bytes: [UInt8: Int32], merges: [(left: Int32, right: Int32, merged: Int32)],
                              added: [(text: String, id: Int32)], eos: Int32, pad: Int32, unk: Int32) -> Data {
        var data = magic
        data.append(little: version)
        data.append(little: UInt16(0))
        data.append(little: eos)
        data.append(little: pad)
        data.append(little: unk)
        data.append(little: UInt32(scalars.count))
        data.append(little: UInt32(merges.count))
        data.append(little: UInt32(added.count))
        for byte in 0...255 { data.append(little: bytes[UInt8(byte)] ?? -1) }
        for (scalar, id) in scalars.sorted(by: { $0.key < $1.key }) {
            data.append(little: scalar)
            data.append(little: id)
        }
        let ranked = merges.enumerated().map { rank, merge in
            (key: UInt64(UInt32(bitPattern: merge.left)) << 32 | UInt64(UInt32(bitPattern: merge.right)), rank: UInt32(rank), merged: merge.merged)
        }
        // A pair merges once, at its first (lowest) rank.
        var seen = Set<UInt64>()
        for merge in ranked.filter({ seen.insert($0.key).inserted }).sorted(by: { $0.key < $1.key }) {
            data.append(little: merge.key)
            data.append(little: merge.rank)
            data.append(little: merge.merged)
        }
        for token in added {
            let bytes = Data(token.text.utf8)
            data.append(little: token.id)
            data.append(little: UInt32(bytes.count))
            data.append(bytes)
        }
        // The merge count in the header is the number written.
        let count = UInt32(seen.count)
        withUnsafeBytes(of: count.littleEndian) { data.replaceSubrange(24..<28, with: $0) }
        return data
    }

    /// The vocabulary file from Hugging Face's `tokenizer.json` (a BPE model with byte fallback, as Gemma's is). Pieces
    /// are kept scalar by scalar: Foundation's JSON reader and Swift strings treat canonically equal pieces ("é" as one
    /// scalar or two) as one, and the vocabulary keeps them apart (six of Gemma's 256,000 pieces).
    public static func build(fromTokenizerJSON json: Data) throws -> Data {
        var reader = ExactJSON(json)
        guard case .object(let root) = try reader.value(), case .object(let model)? = root[key: "model"], case .string(let type)? = model[key: "type"],
              type == Array("BPE".unicodeScalars.map(\.value)), case .object(let rawVocab)? = model[key: "vocab"],
              case .array(let rawMerges)? = model[key: "merges"] else {
            throw EmbeddingError.unexpectedOutput
        }
        var vocab: [[UInt32]: Int32] = [:]
        for (piece, value) in rawVocab {
            guard case .number(let id) = value else { throw EmbeddingError.unexpectedOutput }
            vocab[piece] = Int32(id)
        }
        var singles: [UInt32: Int32] = [:], bytes: [UInt8: Int32] = [:]
        for (piece, id) in vocab {
            if piece.count == 1 { singles[piece[0]] = id }
            let text = String(String.UnicodeScalarView(piece.compactMap(Unicode.Scalar.init)))
            if piece.count == 6, text.hasPrefix("<0x"), text.hasSuffix(">"), let byte = UInt8(text.dropFirst(3).dropLast(), radix: 16) { bytes[byte] = id }
        }
        var merges: [(left: Int32, right: Int32, merged: Int32)] = []
        merges.reserveCapacity(rawMerges.count)
        for raw in rawMerges {
            let pair: [[UInt32]]
            switch raw {
            case .array(let list) where list.count == 2:
                guard case .string(let left) = list[0], case .string(let right) = list[1] else { throw EmbeddingError.unexpectedOutput }
                pair = [left, right]
            case .string(let text):
                guard let space = text.firstIndex(of: 0x20) else { throw EmbeddingError.unexpectedOutput }
                pair = [Array(text[..<space]), Array(text[(space + 1)...])]
            default:
                throw EmbeddingError.unexpectedOutput
            }
            guard let left = vocab[pair[0]], let right = vocab[pair[1]], let merged = vocab[pair[0] + pair[1]] else { throw EmbeddingError.unexpectedOutput }
            merges.append((left, right, merged))
        }
        var addedTokens: [(text: String, id: Int32)] = []
        if case .array(let tokens)? = root[key: "added_tokens"] {
            for case .object(let token) in tokens {
                guard case .string(let content)? = token[key: "content"], case .number(let id)? = token[key: "id"], !content.isEmpty else { continue }
                addedTokens.append((String(String.UnicodeScalarView(content.compactMap(Unicode.Scalar.init))), Int32(id)))
            }
        }
        func special(_ name: String) -> Int32 { vocab[name.unicodeScalars.map(\.value)] ?? -1 }
        return encode(scalars: singles, bytes: bytes, merges: merges, added: addedTokens, eos: special("<eos>"), pad: special("<pad>"), unk: special("<unk>"))
    }
}

/// A JSON value whose strings are their exact Unicode scalars, and whose objects keep every key in order (no merging
/// of canonically equal keys).
enum ExactJSONValue {
    case string([UInt32])
    case number(Double)
    case bool(Bool)
    case null
    case array([ExactJSONValue])
    case object([(key: [UInt32], value: ExactJSONValue)])
}

extension Array where Element == (key: [UInt32], value: ExactJSONValue) {
    /// The first value under `key`.
    subscript(key name: String) -> ExactJSONValue? {
        let wanted = name.unicodeScalars.map(\.value)
        return first { $0.key == wanted }?.value
    }
}

/// Just enough JSON to read `tokenizer.json` exactly (UTF-8, standard escapes, surrogate pairs).
struct ExactJSON {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    mutating func value() throws -> ExactJSONValue {
        skipSpace()
        guard index < bytes.count else { throw EmbeddingError.unexpectedOutput }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var members: [(key: [UInt32], value: ExactJSONValue)] = []
            skipSpace()
            if consume(UInt8(ascii: "}")) { return .object(members) }
            repeat {
                skipSpace()
                let key = try string()
                skipSpace()
                try expect(UInt8(ascii: ":"))
                members.append((key, try value()))
                skipSpace()
            } while consume(UInt8(ascii: ","))
            try expect(UInt8(ascii: "}"))
            return .object(members)
        case UInt8(ascii: "["):
            index += 1
            var elements: [ExactJSONValue] = []
            skipSpace()
            if consume(UInt8(ascii: "]")) { return .array(elements) }
            repeat { elements.append(try value()); skipSpace() } while consume(UInt8(ascii: ","))
            try expect(UInt8(ascii: "]"))
            return .array(elements)
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            try literal("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try literal("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try literal("null")
            return .null
        default:
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw EmbeddingError.unexpectedOutput }
            return .number(number)
        }
    }

    private mutating func string() throws -> [UInt32] {
        try expect(UInt8(ascii: "\""))
        var scalars: [UInt32] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return scalars
            }
            if byte == UInt8(ascii: "\\") {
                guard index + 1 < bytes.count else { break }
                let escape = bytes[index + 1]
                index += 2
                switch escape {
                case UInt8(ascii: "n"): scalars.append(0x0A)
                case UInt8(ascii: "t"): scalars.append(0x09)
                case UInt8(ascii: "r"): scalars.append(0x0D)
                case UInt8(ascii: "b"): scalars.append(0x08)
                case UInt8(ascii: "f"): scalars.append(0x0C)
                case UInt8(ascii: "u"):
                    var unit = try hex4()
                    if (0xD800...0xDBFF).contains(unit), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let saved = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) { unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00) } else { index = saved }
                    }
                    scalars.append(unit)
                default: scalars.append(UInt32(escape))
                }
                continue
            }
            // One UTF-8 sequence.
            let length = byte < 0x80 ? 1 : byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
            guard index + length <= bytes.count else { break }
            var scalar = length == 1 ? UInt32(byte) : UInt32(byte) & (0xFF >> (length + 1))
            for offset in 1..<length { scalar = scalar << 6 | UInt32(bytes[index + offset] & 0x3F) }
            scalars.append(scalar)
            index += length
        }
        throw EmbeddingError.unexpectedOutput
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16) else {
            throw EmbeddingError.unexpectedOutput
        }
        index += 4
        return value
    }

    private mutating func skipSpace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard consume(byte) else { throw EmbeddingError.unexpectedOutput }
    }

    private mutating func literal(_ word: String) throws {
        for byte in word.utf8 { try expect(byte) }
    }
}

extension Data {
    /// A little-endian integer at a byte offset from the start (any alignment).
    func integer<T: FixedWidthInteger>(at offset: Int, as _: T.Type) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    mutating func append<T: FixedWidthInteger>(little value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
