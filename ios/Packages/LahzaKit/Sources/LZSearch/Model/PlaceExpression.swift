import Foundation
import LZGeo

/// Where the photos were taken, as the query says it.
public indirect enum PlaceExpression: Sendable, Hashable, Codable {
    /// A typed name ("Al-Nakheel Park", "Greece"). `.maybe` when only its position in the query suggests a place:
    /// it then resolves only to an exact name. Otherwise it is the place search couldn't find, or, when another place
    /// is searched, words about what's in the photos.
    case named(String, relation: PlaceRelation, confidence: Confidence)
    /// "home", or a saved place's name.
    case alias(PlaceAlias, relation: PlaceRelation)
    /// "at the beach": every place of that category with photos.
    case category(PlaceCategory, relation: PlaceRelation)
    /// A place picked through a chip (its key and display name).
    case picked(placeKey: String, name: String, relation: PlaceRelation)
    /// "Dubai or Abu Dhabi".
    case anyOf([PlaceExpression])

    public var relation: PlaceRelation {
        switch self {
        case .named(_, let relation, _), .alias(_, let relation), .category(_, let relation), .picked(_, _, let relation): relation
        case .anyOf(let parts): parts.first?.relation ?? .in
        }
    }

    /// A name that only might be a place.
    var isMaybe: Bool {
        if case .named(_, _, .maybe) = self { true } else { false }
    }

    /// The same place with another relation ("near" doubles an area's radius).
    public func with(relation: PlaceRelation) -> PlaceExpression {
        switch self {
        case .named(let name, _, let confidence): .named(name, relation: relation, confidence: confidence)
        case .alias(let alias, _): .alias(alias, relation: relation)
        case .category(let category, _): .category(category, relation: relation)
        case .picked(let key, let name, _): .picked(placeKey: key, name: name, relation: relation)
        case .anyOf(let parts): .anyOf(parts.map { $0.with(relation: relation) })
        }
    }
}

/// How the query relates the photos to the place.
public enum PlaceRelation: String, Sendable, Hashable, Codable {
    case `in`, at, near, from, to
}

public enum Confidence: String, Sendable, Hashable, Codable {
    /// The words are a known place: the person's own, a saved one, a country or a large city.
    case certain
    /// Leftover words that might be a place.
    case maybe
}

public enum PlaceAlias: Sendable, Hashable, Codable {
    case home
    /// A saved place's row id.
    case saved(Int64)
}
