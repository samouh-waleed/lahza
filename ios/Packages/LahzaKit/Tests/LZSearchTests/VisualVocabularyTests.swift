import Foundation
import LZGeo
import Testing
@testable import LZIndex
@testable import LZSearch

/// Words for what's in photos mapped to Vision's photo tags (content search L1): every form people type, synonyms,
/// the other tags by their own names, and the words with no tag. Content words never become places, so none of them is
/// looked up on Apple Maps.
@Suite struct VisualVocabularyTests {
    let vocabulary = VisualVocabulary.english

    struct Case: Sendable, CustomTestStringConvertible {
        var words: String
        /// The concept's own tags; nil when no tag shows it.
        var tags: [String]?
        var testDescription: String { "“\(words)”" }
    }

    static func c(_ words: String, _ tags: String...) -> Case { Case(words: words, tags: tags.isEmpty ? nil : tags) }

    static let cases: [Case] = [
        // Hiking and its forms.
        c("hike", "hiking"), c("hikes", "hiking"), c("hiked", "hiking"), c("hiking", "hiking"), c("hiker", "hiking"), c("hikers", "hiking"),
        c("trek", "hiking"), c("treks", "hiking"), c("trekked", "hiking"), c("trekking", "hiking"), c("Hiking", "hiking"), c("HIKES", "hiking"),
        c("hill walking", "hiking"), c("trail", "trail"), c("trails", "trail"), c("hiking trail", "trail"), c("mountains", "mountain"),
        // Soccer.
        c("soccer", "soccer"), c("futsal", "soccer"), c("footy", "soccer"), c("soccer game", "soccer"), c("soccer match", "soccer"),
        c("football match", "soccer"), c("playing soccer", "soccer"), c("play soccer", "soccer"), c("football", "soccer", "football"),
        c("footballs", "soccer", "football"), c("playing football", "soccer", "football"),
        // Snow.
        c("ski", "skiing"), c("skis", "skiing"), c("skied", "skiing"), c("skiing", "skiing"), c("skier", "skiing"), c("ski trip", "skiing"),
        c("slopes", "skiing"), c("snowboarding", "snowboarding"), c("snowboarded", "snowboarding"), c("snowboard", "snowboard"),
        c("sled", "sledding"), c("sledging", "sledding"), c("snow", "snow"), c("snowy", "snow"), c("snowman", "snowman"),
        // Camping and the desert.
        c("camp", "camping"), c("camps", "camping"), c("camped", "camping"), c("camping", "camping"), c("campers", "camping"),
        c("tent", "tent"), c("tents", "tent"), c("desert", "desert"), c("deserts", "desert"), c("dune", "sand_dune"), c("dunes", "sand_dune"),
        c("sand dunes", "sand_dune"), c("atv", "atv"), c("quad", "atv"), c("quad bike", "atv"), c("buggy", "atv"), c("buggies", "atv"),
        c("dune buggy", "atv"), c("dune bashing", "atv"), c("four wheeler", "atv"),
        // Water.
        c("beach", "beach"), c("beaches", "beach"), c("seaside", "beach"), c("sea", "ocean"), c("ocean", "ocean"), c("oceans", "ocean"),
        c("swim", "swimming"), c("swam", "swimming"), c("swimming", "swimming"), c("pool", "pool"), c("scuba", "scuba", "diving"),
        c("scuba diving", "scuba", "diving"), c("diving", "scuba", "diving"), c("dived", "scuba", "diving"), c("divers", "scuba", "diving"),
        c("snorkel", "snorkeling"), c("snorkelling", "snorkeling"), c("snorkelled", "snorkeling"), c("surf", "surfing"), c("surfer", "surfing"),
        c("kayak", "kayak", "canoe"), c("canoeing", "kayak", "canoe"), c("jet ski", "jetski"), c("jet-ski", "jetski"),
        c("boat", "boat", "sailboat", "yacht", "speedboat"), c("sailing", "boat", "sailboat", "yacht", "speedboat"), c("fishing", "fishing"),
        c("waterfall", "waterfall"), c("waterfalls", "waterfall"), c("lake", "lake"), c("lakes", "lake"),
        // Sky.
        c("sunset", "sunset_sunrise"), c("sunsets", "sunset_sunrise"), c("sunrise", "sunset_sunrise"), c("sundown", "sunset_sunrise"),
        c("golden hour", "sunset_sunrise"), c("stars", "night_sky"), c("night sky", "night_sky"), c("milky way", "night_sky"),
        c("fireworks", "fireworks"), c("firework", "fireworks"), c("sparklers", "fireworks"), c("storm", "storm", "thunderstorm"),
        c("rainbow", "rainbow"), c("clouds", "cloudy"), c("moon", "moon"),
        // Food.
        c("sushi", "sushi"), c("sashimi", "sushi"), c("pizza", "pizza"), c("pizzas", "pizza"), c("burger", "hamburger"), c("burgers", "hamburger"),
        c("bbq", "grill"), c("barbecue", "grill"), c("coffee", "coffee"), c("latte", "coffee"), c("tea", "tea_drink"), c("ice cream", "ice_cream"),
        c("gelato", "ice_cream"), c("cake", "cake", "cake_regular", "birthday_cake", "wedding_cake", "cupcake", "cheesecake", "fruitcake"),
        c("dessert", "dessert"), c("food", "food"), c("dinner", "food"), c("breakfast", "food"), c("kebab", "kebab"), c("steak", "steak"),
        c("salad", "salad"),
        // Occasions.
        c("birthday", "birthday_cake"), c("birthdays", "birthday_cake"), c("bday", "birthday_cake"), c("birthday party", "birthday_cake"),
        c("wedding", "wedding"), c("weddings", "wedding"), c("graduation", "graduation"), c("concert", "concert"), c("gig", "concert"),
        c("christmas tree", "christmas_tree"), c("dancing", "dancing"), c("dance", "dancing"),
        // Documents.
        c("receipt", "receipt"), c("receipts", "receipt"), c("invoice", "receipt"), c("passport", "passport"), c("passports", "passport"),
        c("ticket", "ticket"), c("boarding pass", "ticket"), c("document", "document"), c("documents", "document"),
        // Sport and things by their own tag names.
        c("tennis", "tennis"), c("golf", "golf"), c("golfing", "golf"), c("basketball", "basketball"), c("cricket", "cricket_sport"),
        c("climbing", "rock_climbing"), c("bouldering", "rock_climbing"), c("cycling", "cycling"), c("bike", "bicycle"), c("bikes", "bicycle"),
        c("yoga", "yoga"), c("skydiving", "skydiving"), c("ice skating", "ice_skating"), c("dog", "dog"), c("dogs", "dog"), c("cat", "cat"),
        c("cats", "cat"), c("horse", "horse"), c("horses", "horse"), c("camel", "camel"), c("camels", "camel"), c("child", "child"),
        c("children", "child"), c("hospital", "hospital"), c("tower", "tower"), c("skyscraper", "skyscraper"), c("skyscrapers", "skyscraper"),
        c("bridge", "bridge"), c("castle", "castle"), c("ruins", "ruins"), c("fountain", "fountain"), c("lighthouse", "lighthouse"),
        c("train", "train", "train_real"), c("plane", "airplane", "aircraft"), c("car", "car"), c("cars", "car"),
        // No tag: they stay "not yet" until the image model.
        c("party"), c("parties"), c("gym"), c("selfie"), c("friends"), c("haircut"), c("fitness"), c("purple"), c("narnia"), c(""),
    ]

    @Test(arguments: cases) func mapsWordsToTags(_ testCase: Case) {
        #expect(vocabulary.concept(for: testCase.words)?.labels == testCase.tags)
    }

    @Test func theTableIsLargeEnough() {
        #expect(Self.cases.count >= 150)
    }

    /// The curated concepts use only Vision's own identifiers (macOS 26.6.2's list; the iPhone's is checked in the
    /// label lab), each concept name finds itself, and no curated word maps to two concepts.
    @Test func curatedTagsAreVisionIdentifiers() {
        let known = Set(vocabulary.labels)
        #expect(known.count == 1_303)
        #expect(vocabulary.curatedLabels.subtracting(known).isEmpty, "\(vocabulary.curatedLabels.subtracting(known).sorted())")
        for concept in vocabulary.concepts { #expect(vocabulary.concept(exactly: concept.name)?.name == concept.name, "\(concept.name)") }
    }

    @Test func conceptsCarryTheirKind() {
        #expect(vocabulary.concept(for: "receipts")?.kind == .document)
        #expect(vocabulary.concept(for: "hike")?.kind == .occasion)
        #expect(vocabulary.concept(for: "hike")?.needsPerson == true)
        #expect(vocabulary.concept(for: "sunset")?.kind == .thing)
        #expect(vocabulary.concept(for: "hike")?.related == ["trail", "mountain", "cliff", "canyon", "hill", "forest"])
        #expect(vocabulary.concept(for: "sand dunes")?.name == "sand dune")
        #expect(vocabulary.concept(for: "waterfalls")?.name == "waterfall")
        #expect(vocabulary.concept(for: "cricket")?.name == "cricket")
    }

    @Test func tagsReadAsWords() {
        #expect(VisualVocabulary.readable("sand_dune") == "sand dune")
        #expect(VisualVocabulary.readable("sunset_sunrise") == "sunset")
        #expect(VisualVocabulary.readable("cricket_sport") == "cricket")
        #expect(VisualVocabulary.readable("atv") == "quad bike")
    }

    @Test func formsLandOnlyOnKnownWords() {
        #expect(vocabulary.forms(of: "hikes").contains("hike"))
        #expect(vocabulary.forms(of: "snorkelled").contains("snorkel"))
        #expect(vocabulary.forms(of: "buggies").contains("buggy"))
        #expect(vocabulary.forms(of: "sand dunes").contains("sand dune"))
        // A wrong lemma ("parties" → "partie") or form maps nowhere.
        #expect(vocabulary.concept(for: "parties") == nil)
    }

    // MARK: Parsing

    /// Every curated word and every tag name (but place words, "grill" in "Sufra Grill") is a content word, so it is
    /// never guessed to be a place.
    @Test func curatedWordsAreContentWords() {
        let lexicon = Lexicon.english
        #expect(vocabulary.curatedWords.subtracting(lexicon.contentWords).isEmpty)
        for word in ["hikes", "hiked", "trail", "trails", "trek", "trekking", "skied", "camped", "buggies", "waterfalls", "dunes", "receipts"] {
            #expect(lexicon.contentWords.contains(word), "\(word)")
        }
        #expect(!lexicon.contentWords.contains("grill"), "a place word ends a place's name")
    }

    @Test func eachTaggedWordIsItsOwnSlot() {
        #expect(SearchFixture.parse("hikes").values == [.visual("hikes")])
        #expect(SearchFixture.parse("trail").values == [.visual("trail")])
        #expect(SearchFixture.parse("trek").values == [.visual("trek")])
        #expect(SearchFixture.parse("beach sunset").values == [.visual("beach"), .visual("sunset")])
        #expect(SearchFixture.parse("sand dunes").values == [.visual("sand dunes")])
        #expect(SearchFixture.parse("playing soccer").values == [.visual("playing soccer")])
        #expect(SearchFixture.parse("cute funny").values == [.visual("cute funny")], "words with no tag stay together")
        #expect(SearchFixture.parse("red car").values == [.visual("red"), .visual("car")])
        #expect(SearchFixture.parse("Sufra Grill").values == [.place(.named("Sufra Grill", relation: .in, confidence: .maybe))])
    }

    /// No form of a content word reaches Apple Maps: each is searched by its tags (or stays "not yet") without a lookup.
    @Test func contentWordsNeverReachAppleMaps() async throws {
        let search = try await HeroSearch()
        for text in ["hikes", "hiked", "trail", "trails", "trek", "trekking", "skied", "camped", "dune buggies", "waterfalls", "snorkelling",
                     "receipts", "passports"] {
            let result = try await search.search(text)
            #expect(result.query.slots.allSatisfy { $0.slot.kind == .visual }, "\(text)")
        }
        #expect(search.mapsSearches == 0)
    }
}
