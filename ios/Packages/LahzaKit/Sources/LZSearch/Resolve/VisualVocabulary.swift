import Foundation
import LZGeo
import NaturalLanguage
import Synchronization

/// One searchable idea ("hiking") and the photo tags that show it (Vision's identifiers).
public struct VisualConcept: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Something you do; later the whole outing counts ("soccer", "hiking").
        case occasion
        /// Something you see ("sunset", "sushi").
        case thing
        /// A paper or a card ("receipt", "passport"): utility photos are what's wanted, not junk.
        case document
    }

    /// The name chips and reasons use ("hiking", "scuba diving").
    public var name: String
    /// Searched strictly: a photo with one of them can be Best.
    public var labels: [String]
    /// Searched loosely: a photo with only these goes under More (E24).
    public var related: [String]
    public var kind: Kind
    /// The tag means people doing it.
    public var needsPerson: Bool

    /// The chip: "soccer · photo tag".
    public var chip: String { "\(name) · photo tag" }

    public init(name: String, labels: [String], related: [String] = [], kind: Kind = .thing, needsPerson: Bool = false) {
        self.name = name
        self.labels = labels
        self.related = related
        self.kind = kind
        self.needsPerson = needsPerson
    }
}

/// Words for what's in photos, mapped to Vision's photo tags (content search L1): the curated concepts of
/// `VisualLabels.txt` ("hike", "hikes", "trek" → `hiking`), and every other tag by its own name ("sand dune" →
/// `sand_dune`) with its plural. A typed word is folded, then looked up as typed, then by suffix rules ("waterfalls",
/// "snorkelled"), then by its `NLTagger` lemma; a form is accepted only when it lands on a known word, so a wrong lemma
/// ("parties" → "partie") never maps anywhere.
public struct VisualVocabulary: Sendable {
    public let concepts: [VisualConcept]
    /// Vision's identifiers, as bundled (`VisionLabels.txt`).
    public let labels: [String]
    /// The tags curated concepts use, strictly or loosely.
    public let curatedLabels: Set<String>
    /// How many of ``concepts`` come from `VisualLabels.txt` (they come first).
    let curatedCount: Int
    /// Folded word or phrase → index into ``concepts``.
    private let byWords: [String: Int]
    /// The curated words and forms (what the parser always treats as about photos).
    let curatedWords: Set<String>
    /// The other tags' names and plurals.
    let labelWords: Set<String>
    /// The longest word or phrase, in words.
    let longestPhrase: Int
    private let lemmas = LemmaCache()

    /// The bundled English vocabulary.
    public static let english = VisualVocabulary.bundled()

    /// The concepts of `VisualLabels.txt` (soccer, hiking…), without the ones every other tag makes by its name.
    public var curatedConcepts: ArraySlice<VisualConcept> { concepts.prefix(curatedCount) }

    // MARK: Lookup

    /// The concept for words about photos ("hikes", "sand dunes", "Scuba diving"), or nil when no tag shows it.
    public func concept(for words: String) -> VisualConcept? {
        index(for: PlaceNames.fold(words)).map { concepts[$0] }
    }

    /// The concept a curated word or a tag's name maps to, without forms.
    public func concept(exactly words: String) -> VisualConcept? {
        byWords[PlaceNames.fold(words)].map { concepts[$0] }
    }

    /// How many of `words` (folded) from the start make one known word or phrase, the longest; nil when none does.
    func phraseLength(_ words: ArraySlice<String>) -> Int? {
        for length in stride(from: min(longestPhrase, words.count), through: 1, by: -1) {
            let phrase = words.prefix(length).joined(separator: " ")
            if byWords[phrase] != nil || forms(of: phrase).contains(where: { byWords[$0] != nil }) { return length }
        }
        return nil
    }

    private func index(for folded: String) -> Int? {
        guard !folded.isEmpty else { return nil }
        if let index = byWords[folded] { return index }
        for form in forms(of: folded) { if let index = byWords[form] { return index } }
        // The lemma of the last word ("trekked"), checked against what's known.
        let words = folded.split(separator: " ").map(String.init)
        guard let last = words.last, let lemma = lemmas.lemma(last), lemma != last else { return nil }
        return byWords[(words.dropLast() + [lemma]).joined(separator: " ")]
    }

    /// Candidate base forms of a folded word or phrase: its last word without an ending ("hikes" → "hike", "beaches" →
    /// "beach", "buggies" → "buggy", "snorkelled" → "snorkel", "hiking" → "hike"), and irregular forms.
    func forms(of folded: String) -> [String] {
        var words = folded.split(separator: " ").map(String.init)
        guard let last = words.popLast(), last.count >= 3 else { return [] }
        var bases: [String] = []
        if let irregular = Self.irregular[last] { bases.append(irregular) }
        func strip(_ suffix: String, add: String = "") {
            guard last.hasSuffix(suffix), last.count > suffix.count + 1 else { return }
            let stem = String(last.dropLast(suffix.count))
            bases.append(stem + add)
            // A doubled consonant ("swimming", "snorkelled"): the stem without it.
            if add.isEmpty, let final = stem.last, stem.count >= 3, stem.dropLast().last == final, !"aeiou".contains(final) {
                bases.append(String(stem.dropLast()))
            }
        }
        strip("ies", add: "y")
        strip("es")
        strip("s")
        strip("ing")
        strip("ing", add: "e")
        strip("ed")
        strip("d")
        return bases.map { (words + [$0]).joined(separator: " ") }
    }

    static let irregular: [String: String] = [
        "skied": "ski", "swam": "swim", "swum": "swim", "dove": "dive", "ran": "run", "rode": "ride", "flew": "fly", "children": "child",
        "geese": "goose", "mice": "mouse", "teeth": "tooth", "leaves": "leaf", "knives": "knife", "wolves": "wolf", "loaves": "loaf",
    ]

    // MARK: Names

    /// A tag as people read it: "sand_dune" → "sand dune", "sunset_sunrise" → "sunset".
    public static func readable(_ label: String) -> String {
        readableOverrides[label] ?? label.replacingOccurrences(of: "_", with: " ")
    }

    static let readableOverrides: [String: String] = [
        "sunset_sunrise": "sunset", "cricket_sport": "cricket", "tea_drink": "tea", "train_real": "train", "cake_regular": "cake",
        "house_single": "house", "road_other": "road", "celestial_body_other": "night sky", "atv": "quad bike", "speakers_music": "speakers",
        "kitchen_room": "kitchen", "bathroom_room": "bathroom", "fencing_sport": "fencing", "squash_sport": "squash",
    ]

    /// The words a tag is found by besides its readable name: "cricket" for `cricket_sport`.
    static func aliases(_ label: String) -> [String] {
        var names = [readable(label)]
        let plain = label.replacingOccurrences(of: "_", with: " ")
        if plain != names[0] { names.append(plain) }
        return names
    }

    // MARK: Loading

    /// The vocabulary from `VisualLabels.txt` and `VisionLabels.txt`.
    static func bundled() -> VisualVocabulary {
        func lines(_ name: String) -> [String] {
            (Bundle.module.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        return VisualVocabulary(curated: lines("VisualLabels"), labels: lines("VisionLabels"))
    }

    /// `curated`: `concept | words | tags | related tags | kind | person` lines; `labels`: Vision's identifiers.
    init(curated: [String], labels: [String]) {
        var concepts: [VisualConcept] = []
        var byWords: [String: Int] = [:]
        var curatedWords = Set<String>()
        var curatedLabels = Set<String>()
        func list(_ field: Substring) -> [String] {
            field.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        for line in curated {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 6 else { continue }
            let concept = VisualConcept(name: fields[0].trimmingCharacters(in: .whitespaces), labels: list(fields[2]), related: list(fields[3]),
                                        kind: VisualConcept.Kind(rawValue: fields[4].trimmingCharacters(in: .whitespaces)) ?? .thing,
                                        needsPerson: fields[5].trimmingCharacters(in: .whitespaces) == "yes")
            let index = concepts.count
            concepts.append(concept)
            curatedLabels.formUnion(concept.labels + concept.related)
            for word in list(fields[1]) + [concept.name] {
                let folded = PlaceNames.fold(word)
                // The first concept to claim a word keeps it.
                if byWords[folded] == nil { byWords[folded] = index }
                curatedWords.insert(folded)
            }
        }
        let curatedCount = concepts.count
        // Every tag no curated concept takes strictly is searchable by its name and its plural.
        var labelWords = Set<String>()
        let strict = Set(concepts.flatMap(\.labels))
        for label in labels where !strict.contains(label) {
            let names = Self.aliases(label).map(PlaceNames.fold).filter { byWords[$0] == nil }
            guard !names.isEmpty else { continue }
            let index = concepts.count
            concepts.append(VisualConcept(name: Self.readable(label), labels: [label]))
            for name in names {
                for form in [name, Self.plural(name)] where byWords[form] == nil {
                    byWords[form] = index
                    labelWords.insert(form)
                }
            }
        }
        self.concepts = concepts
        self.labels = labels
        self.curatedLabels = curatedLabels
        self.curatedCount = curatedCount
        self.byWords = byWords
        self.curatedWords = curatedWords
        self.labelWords = labelWords
        longestPhrase = byWords.keys.map { $0.split(separator: " ").count }.max() ?? 1
    }

    /// "dune" → "dunes", "beach" → "beaches", "butterfly" → "butterflies" (the last word of a phrase).
    static func plural(_ name: String) -> String {
        if name.hasSuffix("s") || name.hasSuffix("x") || name.hasSuffix("ch") || name.hasSuffix("sh") { return name + "es" }
        if name.hasSuffix("y"), let before = name.dropLast().last, !"aeiou".contains(before) { return name.dropLast() + "ies" }
        return name + "s"
    }
}

/// `NLTagger` lemmas of single words, remembered (a tagger costs more than the lookup).
private final class LemmaCache: Sendable {
    private let cache = Mutex<[String: String?]>([:])

    func lemma(_ word: String) -> String? {
        if let cached = cache.withLock({ $0[word] }) { return cached }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        let lemma = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma).0.map { PlaceNames.fold($0.rawValue) }
        cache.withLock { $0[word] = lemma }
        return lemma
    }
}
