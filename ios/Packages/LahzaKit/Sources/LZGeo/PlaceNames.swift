import Foundation

/// The one way place names are compared: the gazetteer build, its name index and (later) the
/// query parser all fold names with ``fold(_:)``, so "Ad Dir‘īyah", "ad diriyah" and "AD-DIRIYAH"
/// meet as `ad diriyah`.
public enum PlaceNames {
    /// Apostrophes and transliteration marks that vanish inside words ("Dir‘īyah" → "diriyah").
    private static let deleted: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "\u{02BB}", "\u{02BF}", "\u{02BE}", "`", "\u{00B4}"]
    /// Arabic articles dropped by ``variants(_:)`` ("Al-Nakheel Park" → `nakheel park`).
    private static let articles: [String] = ["al", "el", "ad", "ar", "as", "at", "az", "an", "ash", "adh", "ath"]

    /// Deletes apostrophes and ‘ ’ ʼ ʻ ʿ ʾ ` ´, lowercases, decomposes (NFKD), strips combining
    /// marks, turns every other non-alphanumeric into a space and collapses spaces. The deletions
    /// come first because NFKD would turn ´ into a space.
    public static func fold(_ s: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !deleted.contains(scalar) { kept.append(scalar) }
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in String(kept).lowercased().decomposedStringWithCompatibilityMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                continue
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                if pendingSpace, !output.isEmpty { output.append(" ") }
                pendingSpace = false
                output.append(scalar)
            default:
                pendingSpace = true
            }
        }
        return String(output)
    }

    /// The folded name, plus the folded name without a leading Arabic article when at least 3
    /// characters remain ("Ad Dir'iyah" → [`ad diriyah`, `diriyah`]).
    public static func variants(_ s: String) -> [String] {
        let folded = fold(s)
        guard let space = folded.firstIndex(of: " "), articles.contains(String(folded[..<space])) else {
            return folded.isEmpty ? [] : [folded]
        }
        let rest = folded[folded.index(after: space)...]
        return rest.count >= 3 ? [folded, String(rest)] : [folded]
    }
}
