#if DEBUG
import Foundation
import LZGeo

/// The fake Apple Maps for the seed scenario (spec §8.1): the POIs, reverse geocodes and searches
/// the hero library needs, as a ``FakeMapsClient`` table.
public enum SeedMaps {
    public static let hero = FakeMapsClient.Table(
        places: [
            poi(.alNakheelPark, .park, city: "Riyadh", country: "SA"),
            poi(.salamPark, .park, city: "Riyadh", country: "SA"),
            poi(.salamParkDubai, .park, city: "Dubai", country: "AE", id: "salam-park-dubai"),
            poi(.kingdomCentre, .landmark, city: "Riyadh", country: "SA"),
            poi(.atTuraif, .landmark, city: "Diriyah", country: "SA"),
            poi(.burjKhalifa, .landmark, city: "Dubai", country: "AE"),
            // A store, not an area: never a place-name label.
            poi(.dubaiMall, .store, city: "Dubai", country: "AE"),
            poi(.jbrBeach, .beach, city: "Dubai", country: "AE"),
            poi(.acropolis, .landmark, city: "Athens", country: "GR"),
            poi(.hydePark, .park, city: "London", country: "GB"),
            poi(.bondiBeach, .beach, city: "Sydney", country: "AU"),
            poi(.operaHouse, .landmark, city: "Sydney", country: "AU"),
        ],
        addresses: [
            .init(SeedPlace.mykonos.coordinate, MapAddress(cityName: "Mykonos", countryCode: "GR")),
            .init(SeedPlace.oia.coordinate, MapAddress(cityName: "Oia", countryCode: "GR")),
            .init(SeedPlace.fira.coordinate, MapAddress(cityName: "Thira", countryCode: "GR")),
            .init(SeedPlace.desertCamp.coordinate, MapAddress(cityName: "Rumah", countryCode: "SA")),
        ],
        searches: [
            "Sufra Grill": [poi(.sufraGrill, .restaurant, city: "Riyadh", country: "SA")],
            "Santorini": [MapPlace(name: "Santorini", category: .physicalFeature, coordinate: Coordinate(latitude: 36.4072, longitude: 25.4567),
                                   kind: .physicalFeature, boundingRadius: 10_000, countryCode: "GR")],
            "Mykonos": [MapPlace(name: "Mykonos", category: .physicalFeature, coordinate: SeedPlace.mykonos.coordinate,
                                 kind: .physicalFeature, boundingRadius: 9_000, countryCode: "GR")],
            "Al-Nakheel Park": [
                poi(.alNakheelPark, .park, city: "Riyadh", country: "SA"),
                MapPlace(appleID: "seed.al-nakheel-park-dammam", name: "Al Nakheel Park", category: .park,
                         coordinate: Coordinate(latitude: 26.43, longitude: 50.10), cityName: "Dammam", countryCode: "SA"),
            ],
            "Salam Park": [
                poi(.salamPark, .park, city: "Riyadh", country: "SA"),
                poi(.salamParkDubai, .park, city: "Dubai", country: "AE", id: "salam-park-dubai"),
            ],
            "Paris": [MapPlace(name: "Paris", category: .locality, coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522), kind: .locality,
                               cityName: "Paris", countryCode: "FR")],
        ]
    )

    /// A fake client over ``hero``; DEBUG launches use about 150 ms of latency, tests none.
    public static func client(latency: Duration = .zero) -> FakeMapsClient {
        FakeMapsClient(hero, latency: latency)
    }

    private static func poi(_ place: SeedPlace, _ category: PlaceCategory, city: String, country: String, id: String? = nil) -> MapPlace {
        let slug = id ?? place.name.lowercased().replacingOccurrences(of: " ", with: "-")
        return MapPlace(appleID: "seed." + slug, name: place.name, category: category, coordinate: place.coordinate, cityName: city,
                        countryCode: country)
    }
}
#endif
