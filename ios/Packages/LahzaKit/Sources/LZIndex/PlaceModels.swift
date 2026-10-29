import Foundation
import LZGeo

/// `place.key` values, built the same way by the index and by search.
public enum PlaceKey {
    /// The estimated home (kind 7).
    public static let home = "home"

    /// A country: `cc:SA`.
    public static func country(_ code: String) -> String { "cc:\(code.uppercased())" }

    /// A gazetteer city or locality: `gn:<geonameid>`.
    public static func city(geonameID: Int32) -> String { "gn:\(geonameID)" }

    /// A gazetteer first-level region: `a1:<geonameid>`.
    public static func region(geonameID: Int32) -> String { "a1:\(geonameID)" }

    /// A saved place: `saved:<id>`.
    public static func saved(_ id: Int64) -> String { "saved:\(id)" }

    /// An Apple Maps place: `mk:<Apple id>`, else `mkn:<folded name>@<lat4>,<lon4>`.
    public static func mapPlace(_ place: MapPlace) -> String {
        if let appleID = place.appleID, !appleID.isEmpty { return "mk:" + appleID }
        return String(format: "mkn:%@@%.4f,%.4f", PlaceNames.fold(place.name), place.coordinate.latitude, place.coordinate.longitude)
    }
}

/// How a place name matched a typed phrase (``IndexReader/searchPlaces(_:limit:)``).
public enum PlaceMatch: Int, Sendable, Hashable, Comparable {
    /// A name variant equals the phrase.
    case exact = 0
    /// Every word of the phrase is a whole word of the name ("salam" → "salam park").
    case allTokens
    /// The last word is only the start of a name's word ("salam pa" → "salam park").
    case prefix
    /// Every word is within one edit of a name's word ("nakhel prk" → "al nakheel park").
    case typo

    public static func < (lhs: PlaceMatch, rhs: PlaceMatch) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One place of the own index: a country, region, city, locality, Apple Maps place, saved place or the home.
public struct PlaceRow: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var kind: PlaceKind
    public var key: String
    public var name: String
    public var category: PlaceCategory?
    /// Nil for countries and regions.
    public var center: Coordinate?
    /// Metres; nil for membership kinds (country, region, city, locality).
    public var radius: Double?
    /// ISO 3166 alpha-2.
    public var countryCode: String?
    /// Photos and videos in it, as of the latest structure run.
    public var photoCount: Int
    public var lastUTC: Int64?
    /// Where the row came from (Apple Maps for points of interest and search results).
    public var isFromAppleMaps: Bool
    /// The folded name variant a search matched, and how (``IndexReader/searchPlaces(_:limit:)`` only).
    public var matchedName: String?
    public var match: PlaceMatch?

    public init(id: Int64, kind: PlaceKind, key: String, name: String, category: PlaceCategory? = nil, center: Coordinate? = nil,
                radius: Double? = nil, countryCode: String? = nil, photoCount: Int = 0, lastUTC: Int64? = nil, isFromAppleMaps: Bool = false,
                matchedName: String? = nil, match: PlaceMatch? = nil) {
        self.id = id
        self.kind = kind
        self.key = key
        self.name = name
        self.category = category
        self.center = center
        self.radius = radius
        self.countryCode = countryCode
        self.photoCount = photoCount
        self.lastUTC = lastUTC
        self.isFromAppleMaps = isFromAppleMaps
        self.matchedName = matchedName
        self.match = match
    }
}

/// A place the person picked for a phrase ("Salam Park" → the Dubai one), kept across searches.
public struct PlaceChoiceRow: Sendable, Hashable {
    /// Folded.
    public var phrase: String
    public var placeKey: String
    /// Metres, when the person also chose a radius.
    public var radius: Double?
    public var updated: Date
}

/// A place the person saved (PR 4 writes them; search reads them as aliases).
public struct SavedPlaceRow: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var name: String
    public var center: Coordinate
    /// Metres.
    public var radius: Double
    public var isHome: Bool

    public var key: String { PlaceKey.saved(id) }
}
