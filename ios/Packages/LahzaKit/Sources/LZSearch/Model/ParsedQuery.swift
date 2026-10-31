import Foundation

/// A range of the query text in UTF-16 code units (what `NSRange` and text fields count), so a chip can point back at
/// the words it came from.
public struct TextSpan: Sendable, Hashable, Codable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var end: Int { location + length }

    /// The spanned text, or nil when the span doesn't fit `text`.
    public func substring(of text: String) -> String? {
        let utf16 = text.utf16
        guard location >= 0, length >= 0, end <= utf16.count,
              let start = utf16.index(utf16.startIndex, offsetBy: location, limitedBy: utf16.endIndex),
              let stop = utf16.index(start, offsetBy: length, limitedBy: utf16.endIndex),
              let lower = start.samePosition(in: text.unicodeScalars), let upper = stop.samePosition(in: text.unicodeScalars) else { return nil }
        return String(text.unicodeScalars[lower..<upper])
    }
}

/// Which parser produced a query.
public enum ParserKind: String, Sendable, Hashable, Codable {
    /// The English rules parser (v0).
    case rules
    /// Apple's on-device model, later; it fills the same model.
    case foundationModels
}

/// What a query asks for, as slots tied to the words they came from. The contract every parser fills (the rules
/// parser now, a Foundation Models parser later): `Codable`, so a model can emit it, and slot-first, so chip edits
/// change slots and the text is then rendered from them.
public struct ParsedQuery: Sendable, Hashable, Codable {
    /// What the person typed, or the rendering of edited slots.
    public var text: String
    /// In text order; ids are unique within the query.
    public var slots: [QuerySlot]
    public var parser: ParserKind
    /// The slots were changed through chips (the text is their rendering, not something typed).
    public var isEdited: Bool

    public init(text: String, slots: [QuerySlot], parser: ParserKind = .rules, isEdited: Bool = false) {
        self.text = text
        self.slots = slots
        self.parser = parser
        self.isEdited = isEdited
    }

    /// The slots this version of Lahza can't search yet (people, what's in photos, text in photos), in text order.
    public func unsupported(_ capabilities: SearchCapabilities = .v0) -> [QuerySlot] {
        slots.filter { !capabilities.supports($0.value) }
    }

    /// The slots it can search.
    public func supported(_ capabilities: SearchCapabilities = .v0) -> [QuerySlot] {
        slots.filter { capabilities.supports($0.value) }
    }

    public func slot(_ id: Int) -> QuerySlot? { slots.first { $0.id == id } }

    /// Every time expression, in text order (search intersects them).
    public var timeExpressions: [TimeExpression] {
        slots.compactMap { if case .time(let time) = $0.value { time } else { nil } }
    }

    /// The order the query asks for: its first order slot ("the first time", "oldest first"), nil when none.
    public var order: (slot: Int, order: SearchOrder)? {
        for slot in slots { if case .order(let order) = slot.value { return (slot.id, order) } }
        return nil
    }

    /// Every media filter merged: kinds of one slot combine with OR, slots and flags with AND (nil when none is stated).
    public var mediaFilter: MediaFilter? {
        let filters = slots.compactMap { if case .media(let media) = $0.value { media } else { nil } }
        guard var merged = filters.first else { return nil }
        for filter in filters.dropFirst() {
            merged.kinds = merged.kinds.isEmpty ? filter.kinds : filter.kinds.isEmpty ? merged.kinds : merged.kinds.intersection(filter.kinds)
            merged.flags.formUnion(filter.flags)
        }
        return merged
    }
}

/// One thing the query asks for, and where it was said.
public struct QuerySlot: Sendable, Hashable, Codable, Identifiable {
    public var id: Int
    public var value: SlotValue
    /// Nil when the slot was added by an edit and the text hasn't been rendered since.
    public var span: TextSpan?

    public init(id: Int, value: SlotValue, span: TextSpan?) {
        self.id = id
        self.value = value
        self.span = span
    }

    public var kind: SlotKind { value.kind }
}

/// A slot's meaning.
public enum SlotValue: Sendable, Hashable, Codable {
    case place(PlaceExpression)
    case time(TimeExpression)
    case media(MediaFilter)
    case event(EventKind)
    /// Which occasion, or what order ("the first time", "oldest first").
    case order(SearchOrder)
    /// Parsed but not searchable in v0 ("with Ahmed").
    case people(String)
    /// Words about what's in the photos ("soccer", "sunset"): searched by photo tags once the index has a Vision pass,
    /// when the words map to one.
    case visual(String)
    /// Text in photos; reserved for OCR, never produced in v0.
    case text(String)

    public var kind: SlotKind {
        switch self {
        case .place: .place
        case .time: .time
        case .media: .media
        case .event: .event
        case .order: .order
        case .people: .people
        case .visual: .visual
        case .text: .text
        }
    }
}

public enum SlotKind: String, Sendable, Hashable, Codable, CaseIterable {
    case place, time, media, event, order, people, visual, text
}

/// What search can do in this version.
public struct SearchCapabilities: Sendable, Hashable {
    public var visual = false
    /// Any description, through the image model (Milestone B): words without a photo tag are searched too.
    public var freeText = false
    public var people = false
    public var text = false

    public init(visual: Bool = false, freeText: Bool = false, people: Bool = false, text: Bool = false) {
        self.visual = visual
        self.freeText = freeText
        self.people = people
        self.text = text
    }

    /// Places, dates, photo types, trips and order; nothing about what's in the photos.
    public static let v0 = SearchCapabilities()

    /// Words about what's in photos count only when they map to a photo tag ("soccer", not "party").
    public func supports(_ value: SlotValue) -> Bool {
        switch value {
        case .place, .time, .media, .event, .order: true
        case .people: people
        case .visual(let words): freeText || visual && VisualVocabulary.english.concept(for: words) != nil
        case .text: text
        }
    }
}

/// Trips and being away.
public enum EventKind: String, Sendable, Hashable, Codable {
    /// Photos from a trip ("trips", "vacation").
    case trip
    /// Photos from a trip abroad.
    case abroad
}

/// Which occasion a query asks for, or the order to list them in.
public enum SearchOrder: String, Sendable, Hashable, Codable, CaseIterable {
    /// Only the earliest occasion ("the first time", "my first", "earliest"): a whole trip, or a moment.
    case first
    /// Only the most recent occasion ("the last time", "most recent", "latest").
    case last
    /// Every occasion, oldest to newest ("oldest first", "in order", "over the years").
    case oldestFirst
    /// Every occasion, newest to oldest ("newest first"): the usual order, said out loud.
    case newestFirst

    /// One occasion rather than an order of all of them.
    public var isOccasion: Bool { self == .first || self == .last }
}
