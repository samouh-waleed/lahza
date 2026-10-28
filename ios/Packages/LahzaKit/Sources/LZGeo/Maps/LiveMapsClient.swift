#if canImport(MapKit) && os(iOS)
import Foundation
import MapKit

/// ``MapsClient`` over MapKit. Every MapKit object is created and read on the main actor; only the
/// plain values cross back. Needs no account or key.
public struct LiveMapsClient: MapsClient {
    /// The area categories place naming asks for, mapped back by ``category(_:)``. Only these can be asked
    /// for; an empty set asks for all of them.
    static let areaFilter: [MKPointOfInterestCategory] = [
        .park, .nationalPark, .beach, .stadium, .soccer, .tennis, .basketball, .golf, .campground, .amusementPark,
        .zoo, .university, .airport, .marina, .landmark, .museum, .castle, .fortress, .hiking,
    ]

    private let searchTimeout: Duration

    public init(searchTimeout: Duration = .milliseconds(2_500)) {
        self.searchTimeout = searchTimeout
    }

    public func pointsOfInterest(near c: Coordinate, radius: Double, categories: Set<PlaceCategory>) async throws(MapsError) -> [MapPlace] {
        do {
            return try await Self.pointsOfInterest(near: c, radius: radius, categories: categories)
        } catch {
            throw Self.mapsError(error)
        }
    }

    public func reverseGeocode(_ c: Coordinate) async throws(MapsError) -> MapAddress? {
        do {
            return try await Self.reverseGeocode(c)
        } catch {
            throw Self.mapsError(error)
        }
    }

    public func search(_ text: String, near region: GeoRegion?) async throws(MapsError) -> [MapPlace] {
        do {
            return try await firstOf(timeout: searchTimeout, orThrow: MapsError.other("timeout")) { try await Self.search(text, near: region) }
        } catch {
            throw Self.mapsError(error)
        }
    }

    // MARK: MapKit (main actor)

    @MainActor
    private static func pointsOfInterest(near c: Coordinate, radius: Double, categories: Set<PlaceCategory>) async throws -> [MapPlace] {
        let request = MKLocalPointsOfInterestRequest(center: CLLocationCoordinate2D(c), radius: min(radius, MKLocalPointsOfInterestRequest.maxRadius))
        let wanted = areaFilter.filter { categories.isEmpty || categories.contains(category($0)) }
        guard !wanted.isEmpty else { throw MapsError.notFound }
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: wanted)
        let response = try await MKLocalSearch(request: request).start()
        let places = response.mapItems.compactMap { place($0, boundingRadius: nil) }
        guard !places.isEmpty else { throw MapsError.notFound }
        return places
    }

    @MainActor
    private static func reverseGeocode(_ c: Coordinate) async throws -> MapAddress? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)) else {
            throw MapsError.notFound
        }
        guard let item = try await request.mapItems.first else { throw MapsError.notFound }
        return MapAddress(cityName: item.addressRepresentations?.cityName, countryCode: item.addressRepresentations?.region?.identifier)
    }

    @MainActor
    private static func search(_ text: String, near region: GeoRegion?) async throws -> [MapPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let region {
            request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(region.center),
                                                span: MKCoordinateSpan(latitudeDelta: region.spanDegrees, longitudeDelta: region.spanDegrees))
        }
        request.resultTypes = [.pointOfInterest, .address, .physicalFeature]
        request.regionPriority = .default
        let response = try await MKLocalSearch(request: request).start()
        let bounding = halfDiagonal(response.boundingRegion)
        let places = response.mapItems.compactMap { place($0, boundingRadius: bounding) }
        guard !places.isEmpty else { throw MapsError.notFound }
        return places
    }

    /// A map item as a ``MapPlace``. Without a POI category it is a locality when it is named like its
    /// city, a physical feature when the response covers more than a kilometre, and an address otherwise
    /// (a heuristic to check on a device).
    @MainActor
    private static func place(_ item: MKMapItem, boundingRadius: Double?) -> MapPlace? {
        guard let name = item.name, !name.isEmpty else { return nil }
        let representations = item.addressRepresentations
        let coordinate = Coordinate(latitude: item.location.coordinate.latitude, longitude: item.location.coordinate.longitude)
        var place = MapPlace(appleID: item.identifier?.rawValue, name: name, category: .otherPOI, coordinate: coordinate,
                             cityName: representations?.cityName, countryCode: representations?.region?.identifier)
        if let poi = item.pointOfInterestCategory {
            place.category = category(poi)
        } else {
            if let city = representations?.cityName, city.caseInsensitiveCompare(name) == .orderedSame {
                place.kind = .locality
                place.category = .locality
            } else if let boundingRadius, boundingRadius > 1_000 {
                place.kind = .physicalFeature
                place.category = .physicalFeature
            } else {
                place.kind = .address
                place.category = .address
            }
            place.boundingRadius = boundingRadius
        }
        return place
    }

    static func category(_ poi: MKPointOfInterestCategory) -> PlaceCategory {
        switch poi {
        case .restaurant: .restaurant
        case .cafe: .cafe
        case .bakery: .bakery
        case .store: .store
        case .foodMarket: .foodMarket
        case .fitnessCenter: .fitness
        case .hotel: .hotel
        case .museum: .museum
        case .landmark, .nationalMonument: .landmark
        case .castle, .fortress: .castle
        case .school: .school
        case .soccer, .tennis, .basketball, .baseball, .volleyball: .sportsField
        case .stadium: .stadium
        case .marina: .marina
        case .park: .park
        case .campground: .campground
        case .zoo: .zoo
        case .amusementPark: .amusementPark
        case .beach: .beach
        case .university: .university
        case .golf: .golf
        case .airport: .airport
        case .nationalPark: .nationalPark
        case .hiking: .hiking
        default:
            if #available(iOS 27, *), poi == .airportTerminal { .airport } else { .otherPOI }
        }
    }

    /// Metres from the region's centre to a corner.
    private static func halfDiagonal(_ region: MKCoordinateRegion) -> Double {
        let center = Coordinate(latitude: region.center.latitude, longitude: region.center.longitude)
        let corner = Coordinate(latitude: min(90, region.center.latitude + region.span.latitudeDelta / 2),
                                longitude: region.center.longitude + region.span.longitudeDelta / 2)
        return center.distance(to: corner)
    }

    // MARK: Errors

    static func mapsError(_ error: any Error) -> MapsError {
        if let error = error as? MapsError { return error }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if let mkError = error as? MKError {
            switch mkError.code {
            case .loadingThrottled: return .throttled
            case .placemarkNotFound: return .notFound
            case .serverFailure:
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, isOffline(underlying) { return .offline }
            default: break
            }
        }
        return isOffline(nsError) ? .offline : .other("\(nsError.domain) \(nsError.code)")
    }

    private static func isOffline(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && offlineCodes.contains(error.code)
    }

    private static let offlineCodes: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost]
}

extension CLLocationCoordinate2D {
    fileprivate init(_ c: Coordinate) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }
}
#endif
