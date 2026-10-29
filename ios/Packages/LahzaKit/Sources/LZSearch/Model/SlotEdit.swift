import Foundation
import LZGeo

/// A chip edit. Edits change slots first; the field's text is then rendered from the slots (search spec S19), so the
/// text never disagrees with the chips. Typing again parses from scratch.
public enum SlotEdit: Sendable, Hashable {
    case remove(slot: Int)
    /// A place picked from the picker or the place editor (its key and display name).
    case replacePlace(slot: Int, placeKey: String, name: String)
    /// An area's radius in metres (kept in ``ResolutionOverrides``).
    case setRadius(slot: Int, metres: Double)
    case setNear(slot: Int, Bool)
    case replaceTime(slot: Int, TimeExpression)
    case replaceMedia(slot: Int, MediaFilter)
    case add(SlotValue)
    /// The place editor's "Search Apple Maps for “X”": the slot's words are looked up even when a place in the
    /// library matches, spending the query's one Apple Maps search (kept in ``ResolutionOverrides``).
    case searchAppleMaps(slot: Int)
}

extension ParsedQuery {
    /// The query after `edits`: changed and added slots lose their span, then the text is rendered from the slots
    /// (untouched slots keep the words typed for them, and a place the preposition typed before it) and every span
    /// points into the new text, at the words alone as the parser's do ("Al-Nakheel Park" in "near Al-Nakheel Park"),
    /// so a later edit renders the same words again. The other slots keep their ids and values.
    public func applying(_ edits: [SlotEdit], locale: Locale = .autoupdatingCurrent) -> ParsedQuery {
        var slots = self.slots.map { slot in (slot: slot, typed: slot.span.flatMap { $0.substring(of: text) }, lead: placeLead(of: slot)) }
        func index(_ id: Int) -> Int? { slots.firstIndex { $0.slot.id == id } }
        for edit in edits {
            switch edit {
            case .remove(let id):
                slots.removeAll { $0.slot.id == id }
            case .replacePlace(let id, let key, let name):
                // A picked place keeps the preposition typed for the words it replaces ("at Salam Park").
                guard let position = index(id), case .place(let place) = slots[position].slot.value else { continue }
                slots[position] = (QuerySlot(id: id, value: .place(.picked(placeKey: key, name: name, relation: place.relation)), span: nil), nil,
                                   slots[position].lead)
            case .setRadius, .searchAppleMaps:
                continue
            case .setNear(let id, let near):
                guard let position = index(id), case .place(let place) = slots[position].slot.value else { continue }
                let relation: PlaceRelation = near ? .near : (place.relation == .near ? .in : place.relation)
                slots[position].slot.value = .place(place.with(relation: relation))
            case .replaceTime(let id, let time):
                guard let position = index(id) else { continue }
                slots[position] = (QuerySlot(id: id, value: .time(time), span: nil), nil, nil)
            case .replaceMedia(let id, let media):
                guard let position = index(id) else { continue }
                slots[position] = (QuerySlot(id: id, value: .media(media), span: nil), nil, nil)
            case .add(let value):
                let id = (slots.map(\.slot.id).max() ?? -1) + 1
                slots.append((QuerySlot(id: id, value: value, span: nil), nil, nil))
            }
        }
        // Render: the typed words for untouched slots, the canonical words for the rest, each after the words its span
        // leaves out.
        var text = ""
        var rendered: [QuerySlot] = []
        for (slot, typed, lead) in slots {
            let words = typed ?? slot.value.spanWords(locale: locale)
            guard !words.isEmpty else { continue }
            let before = slot.value.lead(lead, wordsTyped: typed != nil)
            if !text.isEmpty { text += " " }
            text += before
            let start = text.utf16.count
            text += words
            var slot = slot
            slot.span = TextSpan(location: start, length: words.utf16.count)
            rendered.append(slot)
        }
        return ParsedQuery(text: text, slots: rendered, parser: parser, isEdited: true)
    }

    /// The preposition typed right before a place slot's words, with any article after it ("at the "): the parser
    /// leaves it out of the span.
    func placeLead(of slot: QuerySlot) -> PlaceLead? {
        guard case .place = slot.value, let span = slot.span else { return nil }
        let previous = slots.compactMap(\.span).filter { $0.end <= span.location }.map(\.end).max() ?? 0
        guard let between = TextSpan(location: previous, length: span.location - previous).substring(of: text) else { return nil }
        var words = between.split(whereSeparator: \.isWhitespace)
        var articles: [Substring] = []
        while let last = words.last, PlaceLead.articles.contains(last.lowercased()) {
            articles.insert(last, at: 0)
            words.removeLast()
        }
        guard let preposition = words.last, let relation = PlaceLead.relation(of: preposition.lowercased()) else { return nil }
        return PlaceLead(preposition: String(preposition), articles: articles.map(String.init), relation: relation)
    }
}

/// The words typed before a place that its span leaves out: a preposition and the articles after it ("at the").
struct PlaceLead: Sendable, Hashable {
    /// As typed: "at", "near", "to".
    var preposition: String
    /// "the", "my"; usually none.
    var articles: [String]
    var relation: PlaceRelation

    static let articles: Set<String> = ["the", "a", "an", "my", "our"]

    static func relation(of word: String) -> PlaceRelation? {
        word == "to" ? .to : Lexicon.english.placePrepositions[word]
    }
}

extension ResolutionOverrides {
    /// Keeps what an edit says about resolving a slot: the picked place and the radius.
    public mutating func apply(_ edit: SlotEdit) {
        switch edit {
        case .replacePlace(let slot, let key, _): places[slot, default: PlaceOverride()].placeKey = key
        case .setRadius(let slot, let metres): places[slot, default: PlaceOverride()].radius = metres
        case .setNear(let slot, let near): places[slot, default: PlaceOverride()].near = near
        case .searchAppleMaps(let slot): places[slot, default: PlaceOverride()].searchesAppleMaps = true
        case .remove(let slot): places[slot] = nil
        case .replaceTime, .replaceMedia, .add: break
        }
    }

    /// Keeps what edits to `query` say about resolving its slots. The first place picked for a slot keeps the words
    /// typed for it: a later pick is remembered under them, and the place editor lists and looks up what they may mean.
    public mutating func apply(_ edits: [SlotEdit], to query: ParsedQuery) {
        for edit in edits {
            if case .replacePlace(let slot, _, _) = edit, places[slot]?.typedWords == nil,
               let words = query.slot(slot)?.span?.substring(of: query.text) {
                places[slot, default: PlaceOverride()].typedWords = words
            }
            apply(edit)
        }
    }
}

// MARK: Phrases

extension SlotValue {
    /// Canonical English for a slot, used when the text is rendered from edited slots.
    public func phrase(locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case .place(let place): place.phrase
        case .time(let time): time.phrase(locale: locale)
        case .media(let media): media.phrase
        case .event(.trip): "trips"
        case .event(.abroad): "abroad"
        case .people(let words): "with \(words)"
        case .visual(let words), .text(let words): words
        }
    }

    /// The words a slot's span covers when it is rendered from its value: a place without its relation word, people
    /// without "with" (as the parser's spans leave them out).
    func spanWords(locale: Locale) -> String {
        switch self {
        case .place(let place): place.with(relation: .at).phrase
        case .people(let words): words
        default: phrase(locale: locale)
        }
    }

    /// The words rendered before the span: "with" for people; for a place the preposition typed for it while it still
    /// says the same ("at", "from", "near"), else "near" when near, and the articles typed before the words themselves
    /// ("at the beach" turned near is "near the beach"; a picked name drops them).
    func lead(_ lead: PlaceLead?, wordsTyped: Bool) -> String {
        switch self {
        case .people:
            return "with "
        case .place(let place):
            let near = place.relation == .near
            var words: [String] = []
            if let lead, (lead.relation == .near) == near { words.append(lead.preposition) } else if near { words.append("near") }
            if wordsTyped, let lead { words += lead.articles }
            return words.map { $0 + " " }.joined()
        default:
            return ""
        }
    }
}

extension PlaceExpression {
    /// "Al-Nakheel Park", "near home", "the beach", "Dubai or Abu Dhabi".
    public var phrase: String {
        let prefix = relation == .near ? "near " : ""
        switch self {
        case .named(let name, _, _): return prefix + name
        case .alias(.home, _): return prefix + "home"
        case .alias(.saved, _): return prefix + "my place"
        case .category(let category, _): return prefix + "the " + (Self.categoryWords[category] ?? category.rawValue)
        case .picked(_, let name, _): return prefix + name
        case .anyOf(let parts): return parts.map(\.phrase).joined(separator: " or ")
        }
    }

    private static let categoryWords: [PlaceCategory: String] = [
        .park: "park", .beach: "beach", .restaurant: "restaurant", .cafe: "cafe", .stadium: "stadium", .hotel: "hotel", .museum: "museum",
        .airport: "airport", .store: "mall", .zoo: "zoo", .marina: "marina", .campground: "campground", .university: "university",
    ]
}

extension MediaFilter {
    /// "videos", "favorite videos", "screenshots", "only photos".
    public var phrase: String {
        let flagWords: [MediaFlag: String] = [
            .screenshot: "screenshots", .screenRecording: "screen recordings", .selfie: "selfies", .favorite: "favorites",
            .livePhoto: "live photos", .portrait: "portraits", .panorama: "panoramas", .sloMo: "slo-mo", .timeLapse: "time-lapses", .burst: "bursts",
        ]
        var words = MediaFlag.allCases.filter(flags.contains).compactMap { flagWords[$0] }
        if kinds == [.video] { words.append("videos") } else if kinds == [.photo] { words.insert("only photos", at: 0) }
        return words.joined(separator: " ")
    }
}

extension TimeExpression {
    /// Canonical English the rules parser reads back to the same value ("summer 2025", "last Saturday",
    /// "14 June 2025" or "June 14, 2025" in the region's order).
    public func phrase(locale: Locale = .autoupdatingCurrent) -> String {
        func month(_ number: Int) -> String { Self.monthNames[min(max(1, number), 12) - 1] }
        func weekday(_ number: Int) -> String { Self.weekdayNames[min(max(1, number), 7) - 1] }
        func qualified(_ name: String, _ qualifier: Qualifier, every: String? = nil) -> String {
            switch qualifier {
            case .every: every ?? "every \(name)"
            case .last: "last \(name)"
            case .this: "this \(name)"
            case .year(let year): "\(name) \(year)"
            }
        }
        func units(_ count: Int, _ unit: TimeUnit) -> String { count == 1 ? "1 \(unit.rawValue)" : "\(count) \(unit.rawValue)s" }
        switch self {
        case .year(let year):
            return String(year)
        case .month(let number, let qualifier):
            return qualified(month(number), qualifier)
        case .date(let day, let number, let year):
            let monthFirst = LocalDateFormat.monthComesFirst(locale)
            switch (monthFirst, year) {
            case (true, let year?): return "\(month(number)) \(day), \(year)"
            case (true, nil): return "\(month(number)) \(day)"
            case (false, let year?): return "\(day) \(month(number)) \(year)"
            case (false, nil): return "\(day) \(month(number))"
            }
        case .relativeDay(let offset):
            return offset == 0 ? "today" : offset == -1 ? "yesterday" : "\(units(abs(offset), .day)) ago"
        case .calendarUnit(let unit, let offset):
            return offset == 0 ? "this \(unit.rawValue)" : offset == -1 ? "last \(unit.rawValue)" : "\(units(abs(offset), unit)) ago"
        case .rolling(let unit, let count):
            return count == 1 && unit != .day ? "past \(unit.rawValue)" : "past \(count) \(unit.rawValue)s"
        case .ago(let unit, let count, let onThisDay):
            if onThisDay { return count == 0 ? "on this day" : "\(units(count, unit)) ago today" }
            return "\(units(count, unit)) ago"
        case .season(let season, let qualifier):
            return qualified(season.rawValue, qualifier)
        case .weekday(let number, let qualifier):
            return qualifier == .last || qualifier == .this ? qualified(weekday(number), qualifier) : "every \(weekday(number))"
        case .weekend(let qualifier):
            return qualifier == .last || qualifier == .this ? qualified("weekend", qualifier) : "weekends"
        case .workdays:
            return "weekdays"
        case .partOfDay(let part):
            return switch part {
            case .night: "at night"
            case .lateNight: "late at night"
            default: part.rawValue
            }
        case .hijri(let event, let qualifier, let hijriYear):
            let name = TimeResolver.hijriName(event)
            if let hijriYear { return "\(name) \(hijriYear)" }
            return qualified(name, qualifier, every: name)
        case .holiday(let holiday, let qualifier):
            return qualified(TimeResolver.holidayName(holiday), qualifier, every: TimeResolver.holidayName(holiday))
        case .range(let from, let to):
            switch (from, to) {
            case (let from?, let to?): return "between \(from.phrase(locale: locale)) and \(to.phrase(locale: locale))"
            case (let from?, nil): return "since \(from.phrase(locale: locale))"
            case (nil, let to?): return "before \(to.phrase(locale: locale))"
            case (nil, nil): return ""
            }
        case .all(let parts):
            return Self.combinedPhrase(parts, locale: locale)
        }
    }

    private static func combinedPhrase(_ parts: [TimeExpression], locale: Locale) -> String {
        var words: [String] = []
        var index = 0
        while index < parts.count {
            let next = index + 1 < parts.count ? parts[index + 1] : nil
            switch (parts[index], next) {
            case (.relativeDay(0), .partOfDay(.tonight)?):
                words.append("tonight")
                index += 2
            case (.relativeDay(-1), .partOfDay(.night)?):
                words.append("last night")
                index += 2
            case (.relativeDay(0), .partOfDay(let part)?) where part != .lateNight && part != .tonight:
                words.append("this \(part.rawValue)")
                index += 2
            case (.weekday(let weekday, let qualifier), .partOfDay(let part)?) where part != .lateNight && part != .tonight:
                words.append("\(TimeExpression.weekday(weekday, qualifier).phrase(locale: locale)) \(part.rawValue)")
                index += 2
            default:
                words.append(parts[index].phrase(locale: locale))
                index += 1
            }
        }
        return words.joined(separator: " ")
    }

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
}
