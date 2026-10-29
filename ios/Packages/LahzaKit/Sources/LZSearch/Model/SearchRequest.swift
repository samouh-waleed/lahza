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

    public init(text: String, parsed: ParsedQuery? = nil, overrides: ResolutionOverrides = .init(), scope: SearchScope = .wholeLibrary,
                showWeaker: Bool = false) {
        self.text = text
        self.parsed = parsed
        self.overrides = overrides
        self.scope = scope
        self.showWeaker = showWeaker
    }
}

public enum SearchScope: Sendable, Hashable {
    case wholeLibrary
    /// Photos taken on or after the date (undated ones too: nothing says they are older).
    case since(Date)
}

/// What the person chose for slots while editing: a place from the picker, a radius, "near".
public struct ResolutionOverrides: Sendable, Hashable, Codable {
    /// By slot id.
    public var places: [Int: PlaceOverride]

    public init(places: [Int: PlaceOverride] = [:]) {
        self.places = places
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
