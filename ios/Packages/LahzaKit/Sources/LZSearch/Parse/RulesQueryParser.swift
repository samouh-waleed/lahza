import Foundation
import LZGeo

/// The v0 parser: English rules, no model, a few milliseconds per query (search spec §6.3).
///
/// Recognisers run left to right, longest match first, in priority order: media, Hijri events and holidays, time
/// ranges, times, saved places and home (and "at my pitch" when no place is saved by that name), places after a
/// preposition, "the beach", known place names, trips, people, filler, and finally leftovers. Each claims its words,
/// so a later one never takes them. Leftover words become a maybe-place (it resolves only to an exact name) or, for
/// words about what's in photos ("soccer"), an unsupported chip; nothing is dropped silently.
public struct RulesQueryParser: QueryParser {
    public let lexicon: Lexicon

    public init(lexicon: Lexicon = .english) {
        self.lexicon = lexicon
    }

    public func parse(_ text: String, context: ParseContext) -> ParsedQuery {
        var scan = RuleScan(text: text, tokens: QueryTokenizer.tokens(text), lexicon: lexicon, context: context)
        scan.run()
        return scan.query()
    }
}

/// One parse in progress: the words, which of them are claimed, and the slots found so far.
struct RuleScan {
    /// A slot found over words `first...last` (its span), having claimed `claimed`.
    struct Found {
        var value: SlotValue
        var first: Int
        var last: Int
        var claimed: Range<Int>
    }

    let text: String
    let tokens: [QueryToken]
    let lexicon: Lexicon
    let context: ParseContext
    var taken: [Bool]
    var found: [Found] = []

    init(text: String, tokens: [QueryToken], lexicon: Lexicon, context: ParseContext) {
        self.text = text
        self.tokens = tokens
        self.lexicon = lexicon
        self.context = context
        taken = Array(repeating: false, count: tokens.count)
    }

    mutating func run() {
        media()
        hijriAndHolidays()
        timeRanges()
        times()
        aliases()
        prepositionalPlaces()
        categoryPlaces()
        barePlaces()
        events()
        people()
        filler()
        leftovers()
        mergeTimes()
        mergePlaces()
    }

    func query() -> ParsedQuery {
        let ordered = found.sorted { $0.first < $1.first }
        var seenEvents = Set<EventKind>()
        var slots: [QuerySlot] = []
        for item in ordered {
            if case .event(let kind) = item.value, !seenEvents.insert(kind).inserted { continue }
            let start = tokens[item.first].range.lowerBound, end = tokens[item.last].range.upperBound
            slots.append(QuerySlot(id: slots.count, value: item.value, span: TextSpan(location: start, length: end - start)))
        }
        return ParsedQuery(text: text, slots: slots, parser: .rules)
    }

    // MARK: Words

    /// The folded word at `index` if it exists and is not claimed.
    func word(_ index: Int) -> String? {
        guard index >= 0, index < tokens.count, !taken[index] else { return nil }
        return tokens[index].text
    }

    func isFree(_ index: Int) -> Bool { index >= 0 && index < tokens.count && !taken[index] }

    /// The typed text of words `first...last`.
    func original(_ first: Int, _ last: Int) -> String {
        let start = tokens[first].range.lowerBound, end = tokens[last].range.upperBound
        return TextSpan(location: start, length: end - start).substring(of: text) ?? tokens[first...last].map(\.text).joined(separator: " ")
    }

    func folded(_ first: Int, _ last: Int) -> String {
        tokens[first...last].map(\.text).joined(separator: " ")
    }

    /// The longest phrase of `table` starting at `index` over free words (no punctuation inside), and its length.
    func longest<Value>(_ table: [[String]: Value], at index: Int) -> (Value, Int)? {
        guard isFree(index) else { return nil }
        var words: [String] = []
        var best: (Value, Int)?
        for offset in 0..<lexicon.longestPhrase {
            let position = index + offset
            guard let word = word(position), offset == 0 || !tokens[position].followsPunctuation else { break }
            words.append(word)
            if let value = table[words] { best = (value, words.count) }
        }
        return best
    }

    mutating func claim(_ range: Range<Int>) {
        for index in range where index >= 0 && index < tokens.count { taken[index] = true }
    }

    mutating func add(_ value: SlotValue, first: Int, last: Int, claimed: Range<Int>) {
        claim(claimed)
        found.append(Found(value: value, first: first, last: last, claimed: claimed))
    }

    // MARK: 1. Media

    private mutating func media() {
        var index = 0
        while index < tokens.count {
            guard var match = mediaPhrase(at: index) else {
                index += 1
                continue
            }
            // Adjacent media words make one filter ("favorite videos").
            while let next = mediaPhrase(at: match.end), !tokens[match.end].followsPunctuation {
                match.filter.kinds.formUnion(next.filter.kinds)
                match.filter.flags.formUnion(next.filter.flags)
                match.end = next.end
            }
            add(.media(match.filter), first: index, last: match.end - 1, claimed: index..<match.end)
            index = match.end
        }
    }

    private func mediaPhrase(at index: Int) -> (filter: MediaFilter, end: Int)? {
        guard let first = word(index) else { return nil }
        if first == "no", let next = word(index + 1), next == "video" || next == "videos" { return (.photos, index + 2) }
        let only = first == "only" || first == "just"
        let start = only ? index + 1 : index
        guard let head = word(start) else { return nil }
        if lexicon.photoWords.contains(head), longest(lexicon.media, at: start) == nil {
            if only { return (.photos, start + 1) }
            if word(start + 1) == "only" { return (.photos, start + 2) }
            return nil
        }
        guard let (filter, length) = longest(lexicon.media, at: start) else { return nil }
        let end = start + length
        return (filter, word(end) == "only" ? end + 1 : end)
    }

    // MARK: 5. Saved places and home

    private mutating func aliases() {
        var index = 0
        while index < tokens.count {
            guard let first = word(index) else {
                index += 1
                continue
            }
            var relation = PlaceRelation.at
            var start = index
            if let preposition = lexicon.placePrepositions[first] {
                relation = preposition
                start += 1
            }
            var nameStart = start
            if let determiner = word(nameStart), ["my", "our", "the"].contains(determiner) { nameStart += 1 }
            if word(nameStart) == "home" {
                add(.place(.alias(.home, relation: relation)), first: nameStart, last: nameStart, claimed: index..<nameStart + 1)
                index = nameStart + 1
                continue
            }
            if let (id, first, last) = savedAlias(from: start), startsAName(first, last) {
                add(.place(.alias(.saved(id), relation: relation)), first: first, last: last, claimed: index..<last + 1)
                index = last + 1
                continue
            }
            if start > index, let last = unsavedName(from: start) {
                add(.place(.alias(.unsaved(original(start, last)), relation: relation)), first: start, last: last, claimed: index..<last + 1)
                index = last + 1
                continue
            }
            index += 1
        }
    }

    /// The end of "my pitch", "our cabin" after a place preposition (`start` is at "my" or "our") when no saved place
    /// goes by the name: a place of the person's own, which search says isn't saved and never looks up (E22). The name
    /// runs to a word that ends a place name, at most 4 words, and ends at its last place word ("my pitch" in "at my
    /// pitch playing soccer"); without one, words about what's in photos make it no place ("near my dog", "from my
    /// sister"). People ("my family"), the photo library ("in my camera roll") and known places stay as they were.
    private func unsavedName(from start: Int) -> Int? {
        guard let determiner = word(start), ["my", "our"].contains(determiner) else { return nil }
        var end = start + 1
        while let word = word(end), end < start + 5, !tokens[end].followsPunctuation {
            if lexicon.stopWords.contains(word) || lexicon.placePrepositions[word] != nil || word == "to" || lexicon.filler.contains(word) { break }
            end += 1
        }
        var words = tokens[start + 1..<end].map(\.text)
        if let last = words.lastIndex(where: Self.ownPlaceWords.contains) {
            words.removeSubrange((last + 1)...)
        } else if words.contains(where: lexicon.contentWords.contains) {
            return nil
        }
        guard !words.isEmpty, lexicon.people[[determiner] + words] == nil, lexicon.people[words] == nil,
              !words.contains(where: Self.libraryWords.contains) else { return nil }
        let name = words.joined(separator: " ")
        guard !PlaceNames.variants(name).contains(where: { context.vocabulary.knows($0, bare: false, lexicon: lexicon) }) else { return nil }
        return start + words.count
    }

    /// Place words, and kinds of places of one's own that are also words about what's in photos ("my office"): what a
    /// name after "my" ends with.
    static let ownPlaceWords = placeWords.union([
        "office", "room", "bedroom", "kitchen", "classroom", "shop", "store", "gym", "building", "tent", "campsite", "playground", "pool",
        "cabin", "chalet", "villa", "flat", "apartment", "studio", "cottage", "lodge", "camp", "ranch", "yard", "backyard", "balcony", "roof",
        "rooftop", "garage", "majlis", "istiraha", "compound", "spot",
    ])

    /// Words for the photo library itself: "photos in my library" means no place.
    static let libraryWords: Set<String> = ["library", "album", "albums", "gallery", "camera", "roll", "phone", "iphone", "ipad", "recents", "collection"]

    /// A saved name inside a longer name isn't the saved place: "park" (from "My park") in "Al-Nakheel Park" or "at Foo
    /// Park". Its first word must start a name (nothing before it but a preposition, an article, words never in a
    /// name, punctuation or words another recogniser took), and no longer known name may start there.
    private func startsAName(_ first: Int, _ last: Int) -> Bool {
        if first > 0, isFree(first - 1), !tokens[first].followsPunctuation {
            let before = tokens[first - 1].text
            let outsideNames = lexicon.placePrepositions[before] != nil || before == "to" || ["the", "a", "an"].contains(before)
                || lexicon.filler.contains(before) || lexicon.stopWords.contains(before)
            guard outsideNames else { return false }
        }
        var end = last + 1
        while end < min(tokens.count, first + 5), isFree(end), !tokens[end].followsPunctuation {
            if context.vocabulary.knows(folded(first, end), bare: false, lexicon: lexicon) { return false }
            end += 1
        }
        return true
    }

    /// The longest saved-place name starting at `start` (with its "my" or "the", or without).
    private func savedAlias(from start: Int) -> (Int64, Int, Int)? {
        let aliases = context.vocabulary.savedAliases
        guard !aliases.isEmpty else { return nil }
        for begin in [start, start + 1] where begin == start || ["my", "our", "the"].contains(word(start) ?? "") {
            var words: [String] = []
            var best: (Int64, Int, Int)?
            for position in begin..<min(tokens.count, begin + 5) {
                guard let word = word(position), position == begin || !tokens[position].followsPunctuation else { break }
                words.append(word)
                if let id = aliases[words.joined(separator: " ")] { best = (id, begin, position) }
            }
            if let best { return best }
        }
        return nil
    }

    // MARK: 6–8. Places

    private mutating func prepositionalPlaces() {
        var index = 0
        while index < tokens.count {
            guard let first = word(index) else {
                index += 1
                continue
            }
            let relation: PlaceRelation
            if let preposition = lexicon.placePrepositions[first] {
                relation = preposition
            } else if first == "to", index > 0, lexicon.toTriggers.contains(tokens[index - 1].text) {
                relation = .to
            } else {
                index += 1
                continue
            }
            guard let run = placeText(from: index + 1) else {
                index += 1
                continue
            }
            let parts = run.parts.map { place($0, relation: relation) }
            let value: PlaceExpression = parts.count == 1 ? parts[0] : .anyOf(parts)
            add(.place(value), first: run.parts[0].lowerBound, last: run.parts[run.parts.count - 1].upperBound, claimed: index..<run.end)
            index = run.end
        }
    }

    /// A place name after a preposition: words up to the next claimed word, stop word, preposition, filler (but
    /// "of" and "the" inside a name) or punctuation, at most 6, without a leading "the" or "a"; several joined by "or".
    private func placeText(from start: Int) -> (parts: [ClosedRange<Int>], end: Int)? {
        var parts: [ClosedRange<Int>] = []
        var position = start
        var end = start
        while true {
            while let word = word(position), ["the", "a", "an"].contains(word) { position += 1 }
            let first = position
            while let word = word(position), position - first < 6 {
                if position > first, tokens[position].followsPunctuation { break }
                if lexicon.stopWords.contains(word) || lexicon.placePrepositions[word] != nil || word == "to" { break }
                if lexicon.filler.contains(word), word != "of", word != "the" { break }
                position += 1
            }
            var last = position - 1
            while last >= first, ["of", "the"].contains(tokens[last].text) { last -= 1 }
            guard last >= first else { break }
            parts.append(first...last)
            end = last + 1
            guard word(end) == "or", isFree(end + 1) else { break }
            position = end + 1
        }
        return parts.isEmpty ? nil : (parts, end)
    }

    /// The expression for words a preposition introduced: a category word alone is "the beach"; otherwise a name,
    /// certain when it is a known place.
    private func place(_ words: ClosedRange<Int>, relation: PlaceRelation) -> PlaceExpression {
        let phrase = folded(words.lowerBound, words.upperBound)
        if let category = lexicon.categories[phrase] { return .category(category, relation: relation) }
        let known = PlaceNames.variants(phrase).contains { context.vocabulary.knows($0, bare: false, lexicon: lexicon) }
        return .named(original(words.lowerBound, words.upperBound), relation: relation, confidence: known ? .certain : .maybe)
    }

    /// "the beach", "a park": a category word right after an article, with nothing else.
    private mutating func categoryPlaces() {
        for index in tokens.indices {
            guard let article = word(index), ["the", "a", "an"].contains(article), let next = word(index + 1),
                  let category = lexicon.categories[next] else { continue }
            if let after = word(index + 2), !lexicon.filler.contains(after), !lexicon.stopWords.contains(after),
               !tokens[index + 2].followsPunctuation { continue }
            add(.place(.category(category, relation: .at)), first: index + 1, last: index + 1, claimed: index..<index + 2)
        }
    }

    /// Known place names without a preposition (up to 5 words): saved, own, countries, cities of 100,000 people that
    /// aren't common words. A city or country directly followed by a place word ("Dubai Mall") is left for the
    /// leftovers, which keep the whole name.
    private mutating func barePlaces() {
        var index = 0
        while index < tokens.count {
            guard isFree(index) else {
                index += 1
                continue
            }
            var matched: Int?
            var length = 0
            while length < 5, isFree(index + length), length == 0 || !tokens[index + length].followsPunctuation { length += 1 }
            for count in stride(from: length, through: 1, by: -1) {
                let phrase = folded(index, index + count - 1)
                if count == 1, lexicon.filler.contains(phrase) || lexicon.stopWords.contains(phrase) { continue }
                guard context.vocabulary.knows(phrase, bare: true, lexicon: lexicon) else { continue }
                if context.vocabulary.savedAliases[phrase] != nil, !startsAName(index, index + count - 1) { continue }
                let own = context.vocabulary.ownNames.contains(phrase) || context.vocabulary.savedAliases[phrase] != nil
                if !own, let next = word(index + count), Self.placeWords.contains(next), !tokens[index + count].followsPunctuation { continue }
                matched = count
                break
            }
            guard let count = matched else {
                index += 1
                continue
            }
            add(.place(.named(original(index, index + count - 1), relation: .in, confidence: .certain)), first: index, last: index + count - 1,
                claimed: index..<index + count)
            index += count
        }
    }

    // MARK: 9–11. Trips, people, filler

    private mutating func events() {
        for index in tokens.indices {
            guard let word = word(index), let event = lexicon.events[word] else { continue }
            add(.event(event), first: index, last: index, claimed: index..<index + 1)
        }
    }

    private mutating func people() {
        var index = 0
        while index < tokens.count {
            guard let first = word(index) else {
                index += 1
                continue
            }
            if first == "with" {
                let start = index + 1
                var position = start
                if let determiner = word(position), ["my", "our", "the"].contains(determiner) { position += 1 }
                let nameStart = position
                while let word = word(position), position - start < 4, position == start || !tokens[position].followsPunctuation {
                    if word == "and", position > nameStart, let next = self.word(position + 1), !lexicon.stopWords.contains(next),
                       !lexicon.filler.contains(next), lexicon.placePrepositions[next] == nil {
                        position += 1
                        continue
                    }
                    if lexicon.stopWords.contains(word) || lexicon.placePrepositions[word] != nil || lexicon.filler.contains(word) { break }
                    position += 1
                }
                if position > nameStart {
                    add(.people(original(start, position - 1)), first: start, last: position - 1, claimed: index..<position)
                    index = position
                    continue
                }
            }
            if let (name, length) = longest(lexicon.people, at: index) {
                let afterRequest = index > 0 && ["show", "give", "find", "get", "send", "tell", "help"].contains(tokens[index - 1].text)
                if !(name == "me" && afterRequest) {
                    add(.people(original(index, index + length - 1)), first: index, last: index + length - 1, claimed: index..<index + length)
                    index += length
                    continue
                }
            }
            index += 1
        }
    }

    private mutating func filler() {
        for index in tokens.indices where isFree(index) && lexicon.filler.contains(tokens[index].text) { taken[index] = true }
    }

    // MARK: 12. Leftovers

    /// Words that name a kind of place: after other words they belong to a name ("Salam Park", "Sufra Grill").
    static let placeWords: Set<String> = [
        "park", "parks", "beach", "mall", "centre", "center", "tower", "towers", "grill", "cafe", "restaurant", "bridge", "square", "market",
        "souq", "souk", "island", "lake", "river", "hotel", "museum", "palace", "castle", "fort", "fortress", "gate", "garden", "gardens",
        "street", "road", "avenue", "bay", "port", "station", "mosque", "church", "temple", "stadium", "marina", "zoo", "airport", "university",
        "school", "house", "hall", "club", "resort", "village", "farm", "plaza", "theatre", "theater", "arena", "cinema", "library",
        "hospital", "campus", "harbour", "harbor", "pier", "boulevard", "walk", "corniche", "falls", "mountain", "mountains", "hill", "valley",
        "desert", "oasis", "dam", "lagoon", "reef", "point", "cape", "quarter", "district", "town", "city", "opera", "kitchen", "bistro",
        "diner", "bakery", "lounge", "court", "pitch", "field", "ground", "grounds", "circuit", "track",
    ]

    /// Words left over split into runs: words about what's in photos become unsupported chips; other runs of 1–4 words
    /// (with any place words after them) might be a place.
    private mutating func leftovers() {
        let separators = Set(lexicon.placePrepositions.keys).union(lexicon.timePrepositions).union(lexicon.stopWords)
            .union(["to", "or", "and", "no", "not", "only", "just"])
        var index = 0
        while index < tokens.count {
            guard let word = word(index), !separators.contains(word) else {
                if isFree(index) { taken[index] = true }
                index += 1
                continue
            }
            var end = index + 1
            while let next = self.word(end), !separators.contains(next), !tokens[end].followsPunctuation { end += 1 }
            emitLeftovers(index..<end)
            index = end
        }
    }

    private mutating func emitLeftovers(_ run: Range<Int>) {
        // Content words, including two-word ones ("ice cream", "golden hour").
        var content = run.map { lexicon.contentWords.contains(tokens[$0].text) }
        for position in run.dropLast() where lexicon.contentWords.contains(tokens[position].text + " " + tokens[position + 1].text) {
            content[position - run.lowerBound] = true
            content[position + 1 - run.lowerBound] = true
        }
        // A place word before a name starts it ("Café de Flore", "Hotel Ritz").
        for position in run.dropLast() where Self.placeWords.contains(tokens[position].text) && !content[position + 1 - run.lowerBound] {
            content[position - run.lowerBound] = false
        }
        var position = run.lowerBound
        while position < run.upperBound {
            let isContent = content[position - run.lowerBound]
            var end = position + 1
            if isContent {
                while end < run.upperBound, content[end - run.lowerBound] { end += 1 }
                add(.visual(original(position, end - 1)), first: position, last: end - 1, claimed: position..<end)
            } else {
                while end < run.upperBound, !content[end - run.lowerBound] { end += 1 }
                // A name keeps the place words that follow it ("Salam Park").
                while end < run.upperBound, Self.placeWords.contains(tokens[end].text) { end += 1 }
                let words = tokens[position..<end]
                if words.count <= 4, !words.allSatisfy(\.isNumeric), words.contains(where: { $0.text.count >= 2 }) {
                    add(.place(.named(original(position, end - 1), relation: .in, confidence: .maybe)), first: position, last: end - 1,
                        claimed: position..<end)
                } else {
                    add(.visual(original(position, end - 1)), first: position, last: end - 1, claimed: position..<end)
                }
            }
            position = end
        }
    }

    // MARK: Merging

    /// Time slots side by side ("Saturday evening" "in July 2023") are one slot: every part must hold.
    private mutating func mergeTimes() {
        found.sort { $0.first < $1.first }
        var merged: [Found] = []
        for item in found {
            if let previous = merged.last, case .time(let earlier) = previous.value, case .time(let later) = item.value,
               previous.claimed.upperBound == item.claimed.lowerBound, !tokens[item.claimed.lowerBound].followsPunctuation {
                merged[merged.count - 1] = Found(value: .time(.all(Self.parts(earlier) + Self.parts(later))), first: previous.first, last: item.last,
                                                 claimed: previous.claimed.lowerBound..<item.claimed.upperBound)
            } else {
                merged.append(item)
            }
        }
        found = merged
    }

    static func parts(_ expression: TimeExpression) -> [TimeExpression] {
        if case .all(let parts) = expression { return parts.flatMap(Self.parts) }
        return [expression]
    }

    /// Known places joined by "and" or "or" ("Dubai and Abu Dhabi") are one place: any of them.
    private mutating func mergePlaces() {
        found.sort { $0.first < $1.first }
        var merged: [Found] = []
        for item in found {
            if let previous = merged.last, case .place(let earlier) = previous.value, case .place(let later) = item.value,
               item.claimed.lowerBound == previous.claimed.upperBound + 1, ["and", "or"].contains(tokens[previous.claimed.upperBound].text),
               earlier.isNamed, later.isNamed {
                let parts = (earlier.anyOfParts + later.anyOfParts)
                merged[merged.count - 1] = Found(value: .place(.anyOf(parts)), first: previous.first, last: item.last,
                                                 claimed: previous.claimed.lowerBound..<item.claimed.upperBound)
            } else {
                merged.append(item)
            }
        }
        found = merged
    }
}

private extension PlaceExpression {
    var isNamed: Bool {
        switch self {
        case .named, .anyOf: true
        default: false
        }
    }

    var anyOfParts: [PlaceExpression] {
        if case .anyOf(let parts) = self { return parts }
        return [self]
    }
}
