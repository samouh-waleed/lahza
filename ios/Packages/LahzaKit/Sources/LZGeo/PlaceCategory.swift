import Foundation

/// What kind of place a name stands for, and how far around its centre a photo still counts as
/// "at" it. Apple Maps' response region is never used as a POI's extent; the radius comes from here
/// (placeholders to tune with on-device tests).
public enum PlaceCategory: String, Sendable, Codable, CaseIterable {
    case restaurant, cafe, bakery
    case store, foodMarket, fitness, address
    case hotel, home, otherPOI
    /// Castle includes fortresses.
    case museum, landmark, castle, school
    /// Soccer, tennis, basketball and similar pitches and courts.
    case sportsField, stadium
    case marina
    case park, campground
    case zoo, amusementPark, beach, university
    case golf
    case airport
    case nationalPark, hiking
    /// A natural feature or region from an Apple Maps search ("Santorini").
    case physicalFeature
    /// A town or city from an Apple Maps search.
    case locality
    /// A place the person saved.
    case saved

    /// Metres; for the two search kinds it is the radius used when the response has no region.
    public var defaultRadius: Double {
        switch self {
        case .restaurant, .cafe, .bakery: 75
        case .store, .foodMarket, .fitness, .address: 100
        case .hotel, .home, .otherPOI: 150
        case .museum, .landmark, .castle, .school: 200
        case .sportsField, .stadium: 250
        case .marina: 300
        case .park, .campground: 400
        case .zoo, .amusementPark, .beach, .university: 500
        case .golf: 600
        case .airport: 2_000
        case .nationalPark, .hiking: 3_000
        case .physicalFeature, .locality: 3_000
        case .saved: Self.defaultSavedRadius
        }
    }

    /// The radius for a place of this category. A physical feature or locality from an Apple Maps search
    /// uses its response region's half-diagonal, clamped to 2–30 km; everything else ignores it.
    public func radius(boundingRadius: Double?) -> Double {
        switch self {
        case .physicalFeature, .locality:
            guard let boundingRadius else { return defaultRadius }
            return min(max(boundingRadius, 2_000), 30_000)
        default:
            return defaultRadius
        }
    }

    /// The radii a saved place offers.
    public static let savedRadii: [Double] = [100, 250, 1_000]
    public static let defaultSavedRadius: Double = 250

    /// Areas with an extent worth naming a photo cell after. Place naming asks Apple Maps only for these,
    /// so restaurants and shops in a dense block can't crowd them out of the result cap.
    public var isArea: Bool { Self.areas.contains(self) }

    public static let areas: Set<PlaceCategory> = [
        .park, .nationalPark, .beach, .stadium, .sportsField, .golf, .campground, .amusementPark, .zoo,
        .university, .airport, .marina, .landmark, .museum, .castle, .hiking,
    ]
}
