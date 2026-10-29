import Foundation
import LZGeo

/// The words the rules parser knows, folded (``PlaceNames/fold(_:)``). English only in v0.
public struct Lexicon: Sendable {
    public var months: [String: Int]
    /// Month words that are also ordinary words ("may", "march" is fine): months only next to a year, a day or "in".
    public var ambiguousMonths: Set<String>
    /// 1 Sunday … 7 Saturday.
    public var weekdays: [String: Int]
    public var weekdayPlurals: [String: Int]
    /// Weekday words that are also ordinary words ("sun", "sat"): weekdays only after "on" or before a part of day.
    public var ambiguousWeekdays: Set<String>
    public var seasons: [String: Season]
    /// Season words that are also ordinary words ("fall"): seasons only with a year, a qualifier or "in the".
    public var ambiguousSeasons: Set<String>
    public var units: [String: TimeUnit]
    public var partsOfDay: [String: PartOfDay]
    public var numbers: [String: Int]
    public var media: [[String]: MediaFilter]
    /// Words for photos in general ("photos", "pics"): filler, except in "only photos".
    public var photoWords: Set<String>
    public var hijri: [[String]: HijriEvent]
    public var holidays: [[String]: Holiday]
    public var categories: [String: PlaceCategory]
    public var events: [String: EventKind]
    public var placePrepositions: [String: PlaceRelation]
    /// Words after which "to" introduces a place ("trip to", "went to").
    public var toTriggers: Set<String>
    /// Prepositions a time expression may follow without them changing it ("in June", "on Saturday").
    public var timePrepositions: Set<String>
    public var filler: Set<String>
    /// Words that end a place name's run ("with", "and", "when"…).
    public var stopWords: Set<String>
    /// People words that stand alone ("me", "my family").
    public var people: [[String]: String]
    /// Large cities whose names are ordinary words ("nice", "reading"): never places without a preposition.
    public var commonWordCities: Set<String>
    /// Country names or synonyms that are ordinary words ("us"): never places without a preposition.
    public var notBareCountries: Set<String>
    /// Words about what's in photos ("soccer", "sunset", "cake"): never guessed to be places.
    public var contentWords: Set<String>

    /// The English lexicon, with the content words from `ContentWords.txt`.
    public static let english = Lexicon.makeEnglish()

    /// The longest media, Hijri, holiday or people phrase, in words.
    public var longestPhrase = 3

    private static func makeEnglish() -> Lexicon {
        let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        var months: [String: Int] = [:]
        for (index, name) in monthNames.enumerated() { months[name] = index + 1 }
        for (abbreviation, month) in [("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("jun", 6), ("jul", 7), ("aug", 8), ("sep", 9), ("sept", 9),
                                      ("oct", 10), ("nov", 11), ("dec", 12)] { months[abbreviation] = month }
        let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        var weekdays: [String: Int] = [:], plurals: [String: Int] = [:]
        for (index, name) in weekdayNames.enumerated() {
            weekdays[name] = index + 1
            plurals[name + "s"] = index + 1
        }
        for (abbreviation, day) in [("sun", 1), ("mon", 2), ("tue", 3), ("tues", 3), ("wed", 4), ("thu", 5), ("thur", 5), ("thurs", 5),
                                    ("fri", 6), ("sat", 7)] { weekdays[abbreviation] = day }
        var numbers: [String: Int] = [:]
        let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
                           "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        for (index, word) in numberWords.enumerated() { numbers[word] = index + 1 }

        func filter(_ kinds: Set<MediaKind> = [], _ flags: Set<MediaFlag> = []) -> MediaFilter { MediaFilter(kinds: kinds, flags: flags) }
        var media: [[String]: MediaFilter] = [:]
        for word in ["video", "videos", "clip", "clips", "footage", "movie", "movies"] { media[[word]] = .videos }
        for words in [["screenshot"], ["screenshots"], ["screen", "shot"], ["screen", "shots"]] { media[words] = filter([], [.screenshot]) }
        for words in [["screen", "recording"], ["screen", "recordings"], ["screen", "record"]] {
            media[words] = filter([], [.screenRecording])
        }
        for word in ["selfie", "selfies"] { media[[word]] = filter([], [.selfie]) }
        for word in ["favorite", "favorites", "favourite", "favourites", "fave", "faves", "starred", "hearted", "loved"] {
            media[[word]] = filter([], [.favorite])
        }
        for words in [["live", "photo"], ["live", "photos"]] { media[words] = filter([], [.livePhoto]) }
        for word in ["portrait", "portraits"] { media[[word]] = filter([], [.portrait]) }
        for word in ["panorama", "panoramas", "pano", "panos"] { media[[word]] = filter([], [.panorama]) }
        for words in [["slo", "mo"], ["slomo"], ["slow", "motion"], ["slow", "mo"]] { media[words] = filter([], [.sloMo]) }
        for words in [["time", "lapse"], ["time", "lapses"], ["timelapse"], ["timelapses"]] { media[words] = filter([], [.timeLapse]) }
        for word in ["burst", "bursts"] { media[[word]] = filter([], [.burst]) }

        var hijri: [[String]: HijriEvent] = [:]
        for word in ["ramadan", "ramadhan", "ramzan", "ramazan"] { hijri[[word]] = .ramadan }
        for linker in ["al", "ul", "el"] {
            hijri[["eid", linker, "fitr"]] = .eidAlFitr
            hijri[["eid", linker, "adha"]] = .eidAlAdha
        }
        for words in [["eid", "alfitr"], ["eid", "fitr"], ["fitr"], ["small", "eid"]] { hijri[words] = .eidAlFitr }
        for words in [["eid", "aladha"], ["eid", "adha"], ["adha"], ["big", "eid"]] { hijri[words] = .eidAlAdha }
        hijri[["eid"]] = .eid
        hijri[["eids"]] = .eid
        hijri[["hajj"]] = .hajj
        hijri[["haj"]] = .hajj

        var holidays: [[String]: Holiday] = [:]
        for words in [["christmas"], ["xmas"], ["christmas", "eve"], ["christmas", "day"]] { holidays[words] = .christmas }
        for words in [["new", "years", "eve"], ["new", "year", "eve"], ["nye"]] { holidays[words] = .newYearsEve }
        for words in [["new", "years", "day"], ["new", "year", "day"], ["new", "year"], ["new", "years"]] { holidays[words] = .newYearsDay }
        holidays[["national", "day"]] = .nationalDay
        holidays[["founding", "day"]] = .foundingDay

        var categories: [String: PlaceCategory] = [:]
        let categoryWords: [(PlaceCategory, [String])] = [
            (.park, ["park", "parks"]), (.beach, ["beach", "beaches"]), (.restaurant, ["restaurant", "restaurants"]),
            (.cafe, ["cafe", "cafes", "coffee shop"]), (.stadium, ["stadium", "stadiums"]), (.hotel, ["hotel", "hotels"]),
            (.museum, ["museum", "museums"]), (.airport, ["airport", "airports"]), (.store, ["mall", "malls"]), (.zoo, ["zoo", "zoos"]),
            (.marina, ["marina", "marinas"]), (.campground, ["campsite", "campsites", "campground", "campgrounds"]),
            (.university, ["university", "universities"]),
        ]
        for (category, words) in categoryWords { for word in words { categories[word] = category } }

        let content = Set((Bundle.module.url(forResource: "ContentWords", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map(PlaceNames.fold))

        var lexicon = Lexicon(
            months: months, ambiguousMonths: ["may"],
            weekdays: weekdays, weekdayPlurals: plurals, ambiguousWeekdays: ["sun", "sat", "wed"],
            seasons: ["summer": .summer, "summers": .summer, "winter": .winter, "winters": .winter, "spring": .spring, "springs": .spring,
                      "autumn": .autumn, "autumns": .autumn, "fall": .autumn],
            ambiguousSeasons: ["fall"],
            units: ["day": .day, "days": .day, "week": .week, "weeks": .week, "month": .month, "months": .month, "year": .year, "years": .year],
            partsOfDay: ["morning": .morning, "mornings": .morning, "noon": .noon, "midday": .noon, "lunchtime": .noon, "afternoon": .afternoon,
                         "afternoons": .afternoon, "evening": .evening, "evenings": .evening, "night": .night, "nights": .night,
                         "nighttime": .night],
            numbers: numbers,
            media: media,
            photoWords: ["photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "shot", "shots", "pix"],
            hijri: hijri, holidays: holidays, categories: categories,
            events: ["trip": .trip, "trips": .trip, "vacation": .trip, "vacations": .trip, "holiday": .trip, "holidays": .trip, "travel": .trip,
                     "travels": .trip, "travelling": .trip, "traveling": .trip, "abroad": .abroad, "overseas": .abroad],
            placePrepositions: ["in": .in, "inside": .in, "at": .at, "near": .near, "around": .near, "by": .near, "from": .from],
            toTriggers: ["trip", "trips", "travel", "travelled", "traveled", "travelling", "traveling", "went", "go", "going", "visit", "visited",
                         "visiting", "flew", "fly", "flight", "drove", "drive", "vacation", "holiday", "moved", "back"],
            timePrepositions: ["in", "on", "during", "from", "of", "at", "around"],
            filler: ["show", "me", "find", "give", "get", "all", "my", "our", "the", "a", "an", "of", "from", "photos", "photo", "pictures",
                     "picture", "pics", "pic", "images", "image", "shots", "shot", "pix", "ones", "those", "these", "that", "this", "i", "we",
                     "took", "taken", "take", "was", "were", "is", "are", "be", "been", "when", "some", "any", "please", "have", "has", "had",
                     "did", "do", "can", "could", "may", "might", "it", "its", "there", "where", "what", "which", "everything", "every",
                     "stuff", "just", "only", "and", "or", "to", "for", "about", "like", "lahza", "search", "look", "see", "want", "need",
                     "sat", "wed", "you", "your", "us", "they", "them", "he", "she", "him", "her", "his", "with"],
            stopWords: ["with", "and", "when", "while", "during", "last", "this", "or", "but", "where", "who", "that", "which", "me", "us",
                        "him", "her", "them", "you", "i", "we", "trip", "trips", "vacation", "vacations", "holiday", "holidays"],
            people: [["me"]: "me", ["my", "family"]: "my family", ["my", "friends"]: "my friends", ["the", "family"]: "the family",
                     ["family"]: "family", ["friends"]: "friends", ["us"]: "us"],
            commonWordCities: ["nice", "mobile", "reading", "split", "bath", "hope", "orange", "victoria", "florence", "paris hilton", "surprise",
                               "independence", "temple", "sale", "male", "tours", "nancy", "bend", "norman", "cork", "derby", "hull", "batman",
                               "van", "kent", "irving", "eugene", "best", "most", "deal", "eagle", "buffalo", "concord", "march", "may", "home",
                               "garden", "sunrise", "pleasant", "pearl", "fortune", "liberty", "union", "harmony", "unity", "joy", "grace",
                               "mercedes", "date", "kota", "bo", "ho", "of", "as", "ede", "ise"],
            notBareCountries: ["us", "the us", "me"],
            contentWords: content
        )
        lexicon.longestPhrase = (Array(media.keys) + Array(hijri.keys) + Array(holidays.keys) + Array(lexicon.people.keys)).map(\.count).max() ?? 1
        return lexicon
    }
}
