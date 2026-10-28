import Foundation

/// Apple Maps as plain values: area POIs around a photo cell, a reverse geocode where the gazetteer
/// has no city, and one place search per query. Only cell centroids and typed place names are sent,
/// never photo positions. ``LiveMapsClient`` is the MapKit adapter; ``FakeMapsClient`` is scripted.
public protocol MapsClient: Sendable {
    func pointsOfInterest(near c: Coordinate, radius: Double, categories: Set<PlaceCategory>) async throws(MapsError) -> [MapPlace]
    func reverseGeocode(_ c: Coordinate) async throws(MapsError) -> MapAddress?
    func search(_ text: String, near region: GeoRegion?) async throws(MapsError) -> [MapPlace]
}

/// A place Apple Maps returned.
public struct MapPlace: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case poi, address, physicalFeature, locality
    }

    /// Apple's stable identifier for the place, when it has one.
    public var appleID: String?
    public var name: String
    public var category: PlaceCategory
    public var coordinate: Coordinate
    public var kind: Kind
    /// Metres: the half-diagonal of the response region, for non-POI results only.
    public var boundingRadius: Double?
    public var cityName: String?
    /// ISO 3166 alpha-2.
    public var countryCode: String?

    public init(appleID: String? = nil, name: String, category: PlaceCategory, coordinate: Coordinate, kind: Kind = .poi,
                boundingRadius: Double? = nil, cityName: String? = nil, countryCode: String? = nil) {
        self.appleID = appleID
        self.name = name
        self.category = category
        self.coordinate = coordinate
        self.kind = kind
        self.boundingRadius = boundingRadius
        self.cityName = cityName
        self.countryCode = countryCode
    }
}

/// What a reverse geocode keeps: the town and the country, never the street.
public struct MapAddress: Sendable, Hashable, Codable {
    public var cityName: String?
    /// ISO 3166 alpha-2.
    public var countryCode: String?

    public init(cityName: String?, countryCode: String?) {
        self.cityName = cityName
        self.countryCode = countryCode
    }
}

/// The area a search is biased towards (not restricted to).
public struct GeoRegion: Sendable, Hashable {
    public var center: Coordinate
    /// Degrees of latitude and longitude across.
    public var spanDegrees: Double

    public init(center: Coordinate, spanDegrees: Double) {
        self.center = center
        self.spanDegrees = spanDegrees
    }
}

public enum MapsError: Error, Sendable, Hashable {
    /// Apple Maps asked us to slow down.
    case throttled
    /// No network.
    case offline
    /// No result.
    case notFound
    case cancelled
    case other(String)
}
