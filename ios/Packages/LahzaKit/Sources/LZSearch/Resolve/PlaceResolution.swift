import Foundation
import LZGeo
import LZIndex

/// A place search can score photos against.
public indirect enum ResolvedPlace: Sendable, Hashable {
    /// Photos within `radius` metres of `center` (a park, a restaurant, an island, home).
    case area(center: Coordinate, radius: Double, category: PlaceCategory, placeKey: String)
    /// Photos the index placed in it. `placeID` is nil for a gazetteer place no photo is in.
    case membership(level: MembershipLevel, placeID: Int64?, placeKey: String, center: Coordinate?)
    /// "at the beach": every place of a category with photos; a photo scores by its best one.
    case categoryUnion([ResolvedPlace])
    /// "Dubai or Abu Dhabi".
    case anyOf([ResolvedPlace])

    /// The place's key (the first one for a union).
    public var placeKey: String? {
        switch self {
        case .area(_, _, _, let key), .membership(_, _, let key, _): key
        case .categoryUnion(let places), .anyOf(let places): places.first?.placeKey
        }
    }

    /// The same place with its area radii multiplied by `factor` ("near" doubles them).
    func scaled(by factor: Double) -> ResolvedPlace {
        switch self {
        case .area(let center, let radius, let category, let key): .area(center: center, radius: radius * factor, category: category, placeKey: key)
        case .membership: self
        case .categoryUnion(let places): .categoryUnion(places.map { $0.scaled(by: factor) })
        case .anyOf(let places): .anyOf(places.map { $0.scaled(by: factor) })
        }
    }
}

/// Which index column a membership place matches: a city counts its own photos and those it is the metro of (search
/// spec §6.4); localities, regions and countries their own.
public enum MembershipLevel: String, Sendable, Hashable, Codable {
    case country, region, city, locality
}

/// How well a candidate's name matched the phrase.
public enum MatchQuality: Double, Sendable, Hashable, Comparable {
    case exact = 1.0
    case alias = 0.9
    case allTokens = 0.8
    case prefix = 0.7
    case typo = 0.6

    public static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool { lhs.rawValue < rhs.rawValue }

    init(_ match: PlaceMatch) {
        self = switch match {
        case .exact: .exact
        case .allTokens: .allTokens
        case .prefix: .prefix
        case .typo: .typo
        }
    }
}

/// Where a candidate came from; earlier sources win a tie.
public enum CandidateSource: Int, Sendable, Hashable, Comparable {
    case saved, home, ownIndex, gazetteer, appleMaps

    public static func < (lhs: CandidateSource, rhs: CandidateSource) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A place a phrase may mean, with how many photos it holds (the picker's rows).
public struct PlaceCandidate: Sendable, Hashable, Identifiable {
    /// The place key.
    public var id: String
    public var name: String
    /// "Riyadh, Saudi Arabia", "Park · Riyadh".
    public var subtitle: String
    /// The city, else the country, that tells places of the same name apart (the picker's chips: "Riyadh · 10").
    public var context: String?
    public var photoCount: Int
    public var match: MatchQuality
    public var source: CandidateSource
    public var resolved: ResolvedPlace

    public init(id: String, name: String, subtitle: String, context: String? = nil, photoCount: Int, match: MatchQuality, source: CandidateSource,
                resolved: ResolvedPlace) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.context = context
        self.photoCount = photoCount
        self.match = match
        self.source = source
        self.resolved = resolved
    }
}

/// Why a phrase resolved to no place.
public enum PlaceNotFound: String, Sendable, Hashable {
    /// "home" before Lahza has worked out a home or one is saved.
    case noHome
    /// Not in the index or the gazetteer, and Apple Maps couldn't be asked (offline, throttled, out of requests).
    case offline
    /// Not in the index or the gazetteer, and Apple Maps place names are turned off.
    case appleMapsOff
    /// Nowhere, Apple Maps included.
    case notFound
    /// "at the beach" when no place of that category has photos.
    case noPlacesOfCategory
    /// Maybe-place words that match no place exactly ("shawarma"): they are words about what's in photos.
    case notAPlace
}

/// What a place expression resolves to.
public enum PlaceResolution: Sendable, Hashable {
    /// One place, and the other candidates (best first) for the picker.
    case resolved(PlaceCandidate, alternatives: [PlaceCandidate])
    /// Search runs with `top`; a non-blocking picker offers `candidates` (top first) with their counts.
    case ambiguous(top: PlaceCandidate, candidates: [PlaceCandidate])
    case notFound(PlaceNotFound)

    /// The place search runs with.
    public var place: ResolvedPlace? { chosen?.resolved }

    /// The candidate search runs with (its name goes on the chip).
    public var chosen: PlaceCandidate? {
        switch self {
        case .resolved(let candidate, _), .ambiguous(let candidate, _): candidate
        case .notFound: nil
        }
    }
}
