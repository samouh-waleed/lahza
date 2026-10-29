import Foundation
import LZGeo

/// One word of the query: folded, with its UTF-16 range in the original text and the separators before it.
struct QueryToken: Sendable, Hashable {
    /// ``PlaceNames/fold(_:)`` of the word.
    var text: String
    /// UTF-16 offsets into the original text.
    var range: Range<Int>
    /// The characters between the previous word and this one, as typed ("", " ", ", ", "-", "/", " '").
    var gap: String

    /// Digits ("2024", "03"), or an ordinal ("14th").
    var digits: Int? {
        if let value = Int(text), text.count <= 4 { return value }
        for suffix in ["st", "nd", "rd", "th"] where text.hasSuffix(suffix) && text.count > suffix.count {
            if let value = Int(text.dropLast(suffix.count)), value <= 31 { return value }
        }
        return nil
    }

    var isNumeric: Bool { text.allSatisfy(\.isNumber) }

    /// A comma, full stop or other mark ends a place name before this word.
    var followsPunctuation: Bool { gap.contains { ",.;:!?()[]{}\"“”|".contains($0) } }
}

/// Splits a query into words: runs of letters and digits. Apostrophes and transliteration marks inside a word vanish
/// ("year's" → `years`, "Dir'iyah" → `diriyah`); every other mark separates words and is kept in the next word's gap.
enum QueryTokenizer {
    private static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "\u{02BB}", "\u{02BF}", "\u{02BE}", "`", "\u{00B4}"]

    static func tokens(_ text: String) -> [QueryToken] {
        let scalars = Array(text.unicodeScalars)
        var tokens: [QueryToken] = []
        var word = String.UnicodeScalarView()
        var wordStart = 0, offset = 0
        var gap = String.UnicodeScalarView()

        func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber,
                 .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark:
                true
            default:
                false
            }
        }

        func flush(end: Int) {
            guard !word.isEmpty else { return }
            let folded = PlaceNames.fold(String(word))
            for part in folded.split(separator: " ") {
                tokens.append(QueryToken(text: String(part), range: wordStart..<end, gap: String(gap)))
                gap = String.UnicodeScalarView()
            }
            word = String.UnicodeScalarView()
        }

        for (index, scalar) in scalars.enumerated() {
            let width = scalar.utf16.count
            defer { offset += width }
            if isWordScalar(scalar) {
                if word.isEmpty { wordStart = offset }
                word.append(scalar)
                continue
            }
            if apostrophes.contains(scalar), !word.isEmpty, index + 1 < scalars.count, isWordScalar(scalars[index + 1]) {
                continue                                                    // inside a word: it vanishes
            }
            flush(end: offset)
            gap.append(scalar)
        }
        flush(end: offset)
        return tokens
    }
}
