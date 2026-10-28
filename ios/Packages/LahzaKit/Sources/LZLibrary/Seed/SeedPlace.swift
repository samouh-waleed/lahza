#if DEBUG
import Foundation
import LZGeo

/// A place in a seed scenario: a name, a position and the time zone its local times are in. The
/// positions are real landmarks' or synthetic but realistic (the home, the pitches, the family house).
public struct SeedPlace: Sendable, Hashable {
    public var name: String
    public var coordinate: Coordinate
    /// IANA identifier.
    public var zone: String

    init(_ name: String, _ latitude: Double, _ longitude: Double, _ zone: String) {
        self.name = name
        coordinate = Coordinate(latitude: latitude, longitude: longitude)
        self.zone = zone
    }

    public var timeZone: TimeZone { TimeZone(identifier: zone) ?? .gmt }
}

extension SeedPlace {
    static let riyadh = "Asia/Riyadh", dubai = "Asia/Dubai", athens = "Europe/Athens", london = "Europe/London",
               sydney = "Australia/Sydney"

    public static let home = SeedPlace("Home", 24.7480, 46.6330, riyadh)
    public static let alNakheelPark = SeedPlace("Al-Nakheel Park", 24.7590, 46.6440, riyadh)
    /// A second football pitch, 5.7 km from the park.
    public static let otherPitch = SeedPlace("Second pitch", 24.7960, 46.6830, riyadh)
    public static let salamPark = SeedPlace("Salam Park", 24.6236, 46.7070, riyadh)
    public static let kingdomCentre = SeedPlace("Kingdom Centre", 24.7114, 46.6744, riyadh)
    /// A fictional restaurant, 651 m from Kingdom Centre.
    public static let sufraGrill = SeedPlace("Sufra Grill", 24.7155, 46.6790, riyadh)
    public static let atTuraif = SeedPlace("At-Turaif", 24.7339, 46.5753, riyadh)
    /// A camp 80 km north of Riyadh.
    public static let desertCamp = SeedPlace("Desert camp", 25.4700, 46.6000, riyadh)
    public static let familyHouse = SeedPlace("Family house", 24.7000, 46.7000, riyadh)

    public static let burjKhalifa = SeedPlace("Burj Khalifa", 25.1972, 55.2744, dubai)
    public static let dubaiMall = SeedPlace("Dubai Mall", 25.1985, 55.2796, dubai)
    public static let jbrBeach = SeedPlace("JBR Beach", 25.0780, 55.1330, dubai)
    /// A fictional twin of Riyadh's Salam Park, so "Salam Park" is ambiguous.
    public static let salamParkDubai = SeedPlace("Salam Park", 25.2310, 55.3000, dubai)
    public static let dubaiMarina = SeedPlace("Dubai Marina", 25.0805, 55.1403, dubai)

    public static let acropolis = SeedPlace("Acropolis", 37.9715, 23.7257, athens)
    public static let mykonos = SeedPlace("Mykonos", 37.4467, 25.3289, athens)
    public static let oia = SeedPlace("Oia", 36.4618, 25.3753, athens)
    public static let fira = SeedPlace("Fira", 36.4167, 25.4318, athens)

    public static let hydePark = SeedPlace("Hyde Park", 51.5073, -0.1657, london)
    public static let towerBridge = SeedPlace("Tower Bridge", 51.5055, -0.0754, london)

    public static let bondiBeach = SeedPlace("Bondi Beach", -33.8915, 151.2767, sydney)
    public static let operaHouse = SeedPlace("Sydney Opera House", -33.8568, 151.2153, sydney)
}
#endif
