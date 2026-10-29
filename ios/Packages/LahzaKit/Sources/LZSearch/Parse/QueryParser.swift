import Foundation
import LZGeo
import LZIndex

/// Turns typed text into a ``ParsedQuery``. The rules parser is the v0 one; a Foundation Models parser can fill the
/// same model later, with the rules parser as its fallback.
public protocol QueryParser: Sendable {
    func parse(_ text: String, context: ParseContext) async -> ParsedQuery
}

/// What a parse may look at besides the text.
public struct ParseContext: Sendable {
    /// Bounds standalone years (1990 to next year).
    public var now: Date
    public var vocabulary: PlaceVocabulary
    /// The order of numeric dates ("3/4/2024").
    public var locale: Locale

    public init(now: Date, vocabulary: PlaceVocabulary, locale: Locale = .autoupdatingCurrent) {
        self.now = now
        self.vocabulary = vocabulary
        self.locale = locale
    }

    /// The Gregorian year of `now` (in UTC; a day either way doesn't matter for bounding years).
    var currentYear: Int { LocalTime.civil(day: Int32((now.timeIntervalSince1970 / 86_400).rounded(.down))).year }
}

/// The place names a parse can recognise without a preposition: saved places, the person's own places with photos,
/// countries and large cities. Rebuilt per index version (``VocabularyCache``).
public struct PlaceVocabulary: Sendable {
    /// Folded name → saved place id ("my pitch", "pitch").
    public var savedAliases: [String: Int64]
    /// Folded name variants of the own places with at least one photo.
    public var ownNames: Set<String>
    public var gazetteer: Gazetteer

    public init(savedAliases: [String: Int64] = [:], ownNames: Set<String> = [], gazetteer: Gazetteer) {
        self.savedAliases = savedAliases
        self.ownNames = ownNames
        self.gazetteer = gazetteer
    }

    /// The aliases saved places are found by: each name's folded variants, also without a leading "my", "our" or
    /// "the" ("My pitch" → `my pitch`, `pitch`). A name two places share keeps the first.
    public static func aliases(for places: [SavedPlaceRow]) -> [String: Int64] {
        var aliases: [String: Int64] = [:]
        for place in places {
            for variant in PlaceNames.variants(place.name) {
                var forms = [variant]
                for article in ["my ", "our ", "the "] where variant.hasPrefix(article) && variant.count > article.count {
                    forms.append(String(variant.dropFirst(article.count)))
                }
                for form in forms where aliases[form] == nil { aliases[form] = place.id }
            }
        }
        return aliases
    }

    /// Gazetteer cities of at least this population are known without a preposition.
    static let bareCityPopulation = 100_000

    /// Whether `folded` names a known place. `bare` (no preposition before it) asks more: a gazetteer city must have
    /// 100,000 people and not be a common word, and regions don't count.
    func knows(_ folded: String, bare: Bool, lexicon: Lexicon) -> Bool {
        guard folded.count >= 2, !lexicon.notBareCountries.contains(folded) || !bare else { return false }
        if savedAliases[folded] != nil || ownNames.contains(folded) || !CountryNames.codes(matching: folded).isEmpty { return true }
        guard folded.count >= 3, !lexicon.commonWordCities.contains(folded) || !bare else { return false }
        let cities = gazetteer.cities(exactlyNamed: folded, limit: 1)
        if bare { return cities.first.map { $0.population >= Self.bareCityPopulation } ?? false }
        return !cities.isEmpty || !gazetteer.admin1s(exactlyNamed: folded, limit: 1).isEmpty
    }
}
