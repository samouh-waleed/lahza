import Foundation

/// SigLIP 2's text tokenizer (Gemma's BPE), in Swift with no dependencies (decision 41). It gives the ids Hugging Face's
/// `tokenizers` gives for the same lowercased text, which golden tests check:
///
/// 1. lowercase the text (the model was trained on lowercase), as Python's `str.lower()` does: Unicode's full mappings,
///    and a capital sigma ending a word as "ς";
/// 2. keep the added tokens whole (`<eos>`, `\n`, `<b>`…), leftmost and longest first;
/// 3. in the text between them, spaces become "▁" (no "▁" before the first word);
/// 4. BPE over Unicode scalars: a scalar without a piece falls back to its UTF-8 bytes (`<0xNN>`), then the adjacent
///    pair with the lowest merge rank merges, leftmost first, until none can;
/// 5. append `<eos>`; no `<bos>`. Padding to 64 is the text tower's job (``CoreMLTextEmbedder``).
public struct GemmaTokenizer: Sendable {
    public let vocabulary: TokenizerVocabulary

    public init(vocabulary: TokenizerVocabulary) {
        self.vocabulary = vocabulary
    }

    /// The tokenizer whose vocabulary file sits in a model folder (`siglip2-vocab.lzvb`).
    public static func load(from folder: URL) throws -> GemmaTokenizer {
        GemmaTokenizer(vocabulary: try TokenizerVocabulary.load(folder.appendingPathComponent(TokenizerVocabulary.fileName)))
    }

    static let space: UInt32 = 0x20
    static let spaceMark: UInt32 = 0x2581

    /// The ids for `text`, ending with `<eos>`, unpadded and untruncated.
    public func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        let scalars = Self.lowercased(text)
        var start = 0, index = 0
        while index < scalars.count {
            guard let token = addedToken(in: scalars, at: index) else {
                index += 1
                continue
            }
            if start < index { bpe(scalars[start..<index], into: &ids) }
            ids.append(token.id)
            index += token.length
            start = index
        }
        if start < scalars.count { bpe(scalars[start..<scalars.count], into: &ids) }
        ids.append(vocabulary.eos)
        return ids
    }

    /// At most `limit` ids (the text tower's 64), still ending with `<eos>`. Text beyond about 1,000 characters is
    /// never read: no search is that long.
    public func encode(_ text: String, limit: Int) -> [Int32] {
        precondition(limit >= 1)
        let ids = encode(String(text.unicodeScalars.prefix(1_024)))
        return ids.count <= limit ? ids : Array(ids.prefix(limit - 1)) + [vocabulary.eos]
    }

    /// `text` lowercased as Python's `str.lower()` does it. Swift's `lowercased()` gives the same full mappings but
    /// always "σ" for "Σ"; Python gives "ς" when it ends a word (Unicode's Final_Sigma: a cased letter before it and
    /// none after it, skipping case-ignorable ones).
    static func lowercased(_ text: String) -> [UInt32] {
        let scalars = Array(text.unicodeScalars)
        var lowered: [UInt32] = []
        lowered.reserveCapacity(scalars.count)
        for (index, scalar) in scalars.enumerated() {
            guard scalar.value == 0x03A3 else {
                lowered.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars.map(\.value))
                continue
            }
            let before = scalars[..<index].last { !$0.properties.isCaseIgnorable }
            let after = scalars[(index + 1)...].first { !$0.properties.isCaseIgnorable }
            let final = before?.properties.isCased == true && after?.properties.isCased != true
            lowered.append(final ? 0x03C2 : 0x03C3)
        }
        return lowered
    }

    /// The longest added token starting at `index`.
    private func addedToken(in scalars: [UInt32], at index: Int) -> (id: Int32, length: Int)? {
        guard let candidates = vocabulary.added[scalars[index]] else { return nil }
        for candidate in candidates where index + candidate.scalars.count <= scalars.count {
            if scalars[index..<(index + candidate.scalars.count)].elementsEqual(candidate.scalars) { return (candidate.id, candidate.scalars.count) }
        }
        return nil
    }

    /// BPE over one stretch of text between added tokens.
    private func bpe(_ text: ArraySlice<UInt32>, into ids: inout [Int32]) {
        var symbols: [Int32] = []
        symbols.reserveCapacity(text.count)
        for raw in text {
            let scalar = raw == Self.space ? Self.spaceMark : raw
            if let id = vocabulary.id(ofScalar: scalar) {
                symbols.append(id)
                continue
            }
            let bytes = Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8)
            let fallback = bytes.compactMap(vocabulary.id(ofByte:))
            if fallback.count == bytes.count {
                symbols.append(contentsOf: fallback)
            } else if symbols.last != vocabulary.unk {
                // Unknown pieces fuse into one.
                symbols.append(vocabulary.unk)
            }
        }
        while symbols.count > 1 {
            var best: (rank: UInt32, index: Int, merged: Int32)?
            for index in 0..<(symbols.count - 1) {
                guard let merge = vocabulary.merge(symbols[index], symbols[index + 1]) else { continue }
                if merge.rank < best?.rank ?? .max { best = (merge.rank, index, merge.merged) }
            }
            guard let best else { break }
            symbols[best.index] = best.merged
            symbols.remove(at: best.index + 1)
        }
        ids.append(contentsOf: symbols)
    }
}
