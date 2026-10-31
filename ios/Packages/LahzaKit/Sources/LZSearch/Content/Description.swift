import Foundation
import LZGeo

/// What a query says about its photos, as one description for the image model (content search with SigLIP 2): the
/// typed words from its first part to its last, without the words other slots understood ("people dancing at a party"
/// from "people dancing at a party in Riyadh last year"), trimmed of articles and prepositions at either end. The model
/// reads a whole phrase better than its pieces, and only the words about the photos (E30: score a part only when the
/// search names it).
enum Description {
    /// Words dropped at either end of a description.
    static let edgeWords: Set<String> = ["a", "an", "the", "at", "in", "on", "by", "of", "with", "near", "from", "for", "and", "or", "to", "my", "our",
                                         "some", "any", "photos", "photo", "pictures", "picture", "pics", "pic", "images", "image", "show", "me", "find"]

    /// The description of `parts` (slot ids) and the span it covers; nil when nothing is left.
    static func text(_ parsed: ParsedQuery, parts: Set<Int>) -> (text: String, span: TextSpan?)? {
        let partSlots = parsed.slots.filter { parts.contains($0.id) }
        guard !partSlots.isEmpty else { return nil }
        let spans = partSlots.compactMap(\.span)
        var raw: String
        var covered: TextSpan?
        let units = Array(parsed.text.utf16)
        if spans.count == partSlots.count, let start = spans.map(\.location).min(), let end = spans.map(\.end).max(), end <= units.count {
            var keep = [Bool](repeating: true, count: end - start)
            for slot in parsed.slots where !parts.contains(slot.id) {
                guard let span = slot.span, span.end > start, span.location < end else { continue }
                for index in max(start, span.location)..<min(end, span.end) { keep[index - start] = false }
            }
            raw = String(decoding: zip(units[start..<end], keep).map { $0.1 ? $0.0 : 0x20 }, as: UTF16.self)
            covered = TextSpan(location: start, length: end - start)
        } else {
            raw = partSlots.map { $0.value.phrase() }.joined(separator: " ")
        }
        var words = raw.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        while let first = words.first, edgeWords.contains(first.lowercased()) { words.removeFirst() }
        while let last = words.last, edgeWords.contains(last.lowercased()) { words.removeLast() }
        raw = words.joined(separator: " ")
        return raw.isEmpty ? nil : (raw, covered)
    }

    /// The concepts with photo tags a description names, in order, each once: the longest known phrase at each word,
    /// as written or as a plain plural ("red car parked by the sea" → car, sea; "beach sunsets" → beach, sunset). The
    /// word map's other forms ("parked" → park) suit one typed word, not a sentence.
    static func concepts(in text: String, vocabulary: VisualVocabulary = .english) -> [VisualConcept] {
        let words = PlaceNames.fold(text).split(separator: " ").map(String.init)
        func concept(_ phrase: String) -> VisualConcept? {
            if let concept = vocabulary.concept(exactly: phrase) { return concept }
            for ending in ["es", "s"] where phrase.hasSuffix(ending) && phrase.count > ending.count + 2 {
                if let concept = vocabulary.concept(exactly: String(phrase.dropLast(ending.count))) { return concept }
            }
            return nil
        }
        var found: [VisualConcept] = []
        var position = 0
        while position < words.count {
            let longest = min(3, words.count - position)
            let match = (1...longest).reversed().lazy.compactMap { length in
                concept(words[position..<(position + length)].joined(separator: " ")).map { (length, $0) }
            }.first
            if let (length, concept) = match {
                if !found.contains(where: { $0.name == concept.name }) { found.append(concept) }
                position += length
            } else {
                position += 1
            }
        }
        return found
    }

    /// Words that are about what's in photos as a whole (a concept, a Vision tag's name, a content word): with the image
    /// model they are never looked up as a place ("party" in "people dancing at a party").
    static func isContent(_ words: String, table: ConceptTable?, vocabulary: VisualVocabulary = .english, lexicon: Lexicon = .english) -> Bool {
        let folded = PlaceNames.fold(words)
        if vocabulary.concept(for: folded) != nil || table?.concept(for: folded) != nil || lexicon.contentWords.contains(folded) { return true }
        // Counts and "without": never a place ("two people", "beach without people").
        let parts = folded.split(separator: " ").map(String.init)
        if !parts.isEmpty, parts.allSatisfy({ PeopleWords.numbers[$0] != nil || Int($0) != nil || ["without", "nobody", "alone", "group"].contains($0) }) {
            return true
        }
        return vocabulary.forms(of: folded).contains { lexicon.contentWords.contains($0) }
    }
}

/// How many people a description asks for (E30: "not"/"without" and counts go to Vision's face and person counts, which
/// the image model can't do): "without people", "nobody" → none; "alone", "solo" → one; "two people", "3 friends" →
/// that many; "a group", "a crowd" → three or more. The count's words leave the description; a counted noun stays
/// ("two people at the beach" → "people at the beach").
enum PeopleWords {
    static let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
    static let nobody = ["without people", "with no people", "without anyone", "no people", "nobody", "no one"]
    static let alone = ["by myself", "on my own", "alone", "solo"]
    static let groups = ["lots of people", "many people", "a big group of", "a group of", "a group", "a crowd of", "a crowd", "group photo"]
    static let nouns: Set<String> = ["people", "persons", "friends", "kids", "children", "guys", "girls", "boys", "of us", "adults"]

    /// The description without the count's words, and the count; nil when it asks for none.
    static func parse(_ text: String) -> (rest: String, count: PeopleCount?) {
        let lower = text.lowercased()
        for phrase in nobody where contains(lower, phrase) { return (remove(phrase, from: text), PeopleCount(minimum: 0, maximum: 0, words: phrase)) }
        for phrase in alone where contains(lower, phrase) { return (remove(phrase, from: text), PeopleCount(minimum: 1, maximum: 1, words: phrase)) }
        for phrase in groups where contains(lower, phrase) {
            return (remove(phrase, from: text), PeopleCount(minimum: 3, maximum: nil, words: phrase.hasPrefix("a ") ? phrase : "a group"))
        }
        let words = lower.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() where index + 1 < words.count {
            guard let number = numbers[word] ?? Int(word), (1...20).contains(number) else { continue }
            let next = words[index + 1], pair = index + 2 < words.count ? next + " " + words[index + 2] : next
            guard nouns.contains(next) || nouns.contains(pair) else { continue }
            var rest = words
            rest.remove(at: index)
            return (rest.joined(separator: " "), PeopleCount(minimum: number, maximum: number, words: "\(word) \(next)"))
        }
        return (text, nil)
    }

    private static func contains(_ text: String, _ phrase: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }

    private static func remove(_ phrase: String, from text: String) -> String {
        let padded = " " + text + " "
        guard let range = padded.range(of: " " + phrase + " ", options: .caseInsensitive) else { return text }
        var words = padded.replacingCharacters(in: range, with: " ").split(separator: " ").map(String.init)
        while let last = words.last, Description.edgeWords.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, Description.edgeWords.contains(first.lowercased()) { words.removeFirst() }
        return words.joined(separator: " ")
    }
}
