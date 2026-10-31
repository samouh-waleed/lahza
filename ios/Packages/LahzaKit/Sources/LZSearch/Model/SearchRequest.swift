import Foundation

/// One search: the typed text, or slots after chip edits (the slots are then the truth), with any picks.
public struct SearchRequest: Sendable, Hashable {
    public var text: String
    /// Set after chip edits; nil means parse `text`.
    public var parsed: ParsedQuery?
    /// Picked places and radii, per slot.
    public var overrides: ResolutionOverrides
    /// What a search covers: the whole library, or since a date (a free search: hits taken before it are counted as
    /// locked after tiering, never shown).
    public var scope: SearchScope
    public var showWeaker: Bool
    /// What finds content words: everything the index has, unless the scoreboard measures a layer without the others.
    public var content: ContentSignals

    public init(text: String, parsed: ParsedQuery? = nil, overrides: ResolutionOverrides = .init(), scope: SearchScope = .wholeLibrary,
                showWeaker: Bool = false, content: ContentSignals = .all) {
        self.text = text
        self.parsed = parsed
        self.overrides = overrides
        self.scope = scope
        self.showWeaker = showWeaker
        self.content = content
    }
}

/// The signals that find words about what's in photos (the scoreboard's layers, content search 5a and 8).
public struct ContentSignals: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The Vision pass's photo tags (Milestone A).
    public static let tags = ContentSignals(rawValue: 1)
    /// The image model: descriptions scored against the photos' vectors (Milestone B).
    public static let model = ContentSignals(rawValue: 2)
    /// The model's scores judged against the library (robust z-scores); without it, SigLIP's own probability.
    public static let calibration = ContentSignals(rawValue: 4)
    /// An activity's whole outing comes with its confident photos (step 4).
    public static let outings = ContentSignals(rawValue: 8)

    public static let all: ContentSignals = [.tags, .model, .calibration, .outings]
    /// Search v0: places, dates and order only.
    public static let none: ContentSignals = []
}

public enum SearchScope: Sendable, Hashable {
    case wholeLibrary
    /// Photos taken on or after the date (undated ones too: nothing says they are older).
    case since(Date)
}

/// What the person chose for slots while editing: a place from the picker, a radius, "near", no related tags.
public struct ResolutionOverrides: Sendable, Hashable, Codable {
    /// By slot id.
    public var places: [Int: PlaceOverride]
    /// Visual slots searched by their own tags only: the related tags were removed (E24).
    public var withoutRelatedTags: Set<Int>

    public init(places: [Int: PlaceOverride] = [:], withoutRelatedTags: Set<Int> = []) {
        self.places = places
        self.withoutRelatedTags = withoutRelatedTags
    }
}

public struct PlaceOverride: Sendable, Hashable, Codable {
    /// The picked place (``LZIndex/PlaceKey``).
    public var placeKey: String?
    /// Metres; replaces the place's own radius.
    public var radius: Double?
    /// Doubles an area's radius.
    public var near: Bool?
    /// Look the words up on Apple Maps even when a place in the library matches (the place editor asked).
    public var searchesAppleMaps: Bool?
    /// The words typed for the slot before a place was picked for it: what later picks are remembered under, and what
    /// the place editor lists places for.
    public var typedWords: String?

    public init(placeKey: String? = nil, radius: Double? = nil, near: Bool? = nil, searchesAppleMaps: Bool? = nil, typedWords: String? = nil) {
        self.placeKey = placeKey
        self.radius = radius
        self.near = near
        self.searchesAppleMaps = searchesAppleMaps
        self.typedWords = typedWords
    }
}
