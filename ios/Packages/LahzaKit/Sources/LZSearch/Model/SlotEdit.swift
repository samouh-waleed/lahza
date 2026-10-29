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
    /// (untouched slots keep the words typed for them) and every span points into the new text. The other slots keep
    /// their ids and values.
    public func applying(_ edits: [SlotEdit], locale: Locale = .autoupdatingCurrent) -> ParsedQuery {
        var slots = self.slots.map { slot in (slot: slot, typed: slot.span.flatMap { $0.substring(of: text) }) }
        func index(_ id: Int) -> Int? { slots.firstIndex { $0.slot.id == id } }
        for edit in edits {
            switch edit {
            case .remove(let id):
                slots.removeAll { $0.slot.id == id }
            case .replacePlace(let id, let key, let name):
                guard let position = index(id), case .place(let place) = slots[position].slot.value else { continue }
                slots[position] = (QuerySlot(id: id, value: .place(.picked(placeKey: key, name: name, relation: place.relation)), span: nil), nil)
            case .setRadius, .searchAppleMaps:
                continue
            case .setNear(let id, let near):
                guard let position = index(id), case .place(let place) = slots[position].slot.value else { continue }
                let relation: PlaceRelation = near ? .near : (place.relation == .near ? .in : place.relation)
                slots[position].slot.value = .place(place.with(relation: relation))
            case .replaceTime(let id, let time):
                guard let position = index(id) else { continue }
                slots[position] = (QuerySlot(id: id, value: .time(time), span: nil), nil)
            case .replaceMedia(let id, let media):
                guard let position = index(id) else { continue }
                slots[position] = (QuerySlot(id: id, value: .media(media), span: nil), nil)
            case .add(let value):
                let id = (slots.map(\.slot.id).max() ?? -1) + 1
                slots.append((QuerySlot(id: id, value: value, span: nil), nil))
            }
        }
        // Render: the typed words for untouched slots, the canonical phrase for the rest.
        var text = ""
        var rendered: [QuerySlot] = []
        for (slot, typed) in slots {
            let phrase = typed.map { slot.value.prefixed($0) } ?? slot.value.phrase(locale: locale)
            guard !phrase.isEmpty else { continue }
            if !text.isEmpty { text += " " }
            let start = text.utf16.count
            text += phrase
            var slot = slot
            slot.span = TextSpan(location: start, length: phrase.utf16.count)
            rendered.append(slot)
        }
        return ParsedQuery(text: text, slots: rendered, parser: parser, isEdited: true)
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

    /// The typed words of an untouched slot, with the relation words its span leaves out ("near").
    func prefixed(_ typed: String) -> String {
        if case .place(let place) = self, place.relation == .near { return "near \(typed)" }
        if case .people = self { return "with \(typed)" }
        return typed
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
