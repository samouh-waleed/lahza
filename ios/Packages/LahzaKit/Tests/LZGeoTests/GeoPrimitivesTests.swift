import Foundation
import Testing
@testable import LZGeo

/// Geohash cells, name folding, country names, category radii and the scripted Maps client.
@Suite struct GeoPrimitivesTests {
    // MARK: Coordinate

    @Test func coordinatesAreValidOffNullIslandAndRoundTripAsJSON() throws {
        let riyadh = Coordinate(latitude: 24.7590, longitude: 46.6440)
        #expect(riyadh.isValid)
        #expect(!Coordinate(latitude: 0, longitude: 0).isValid)
        #expect(!Coordinate(latitude: 91, longitude: 0).isValid)
        #expect(!Coordinate(latitude: 0, longitude: -180.5).isValid)
        #expect(try JSONDecoder().decode(Coordinate.self, from: JSONEncoder().encode(riyadh)) == riyadh)
        // 0.0108° of latitude is 1.2 km.
        #expect(abs(riyadh.distance(to: Coordinate(latitude: 24.7698, longitude: 46.6440)) - 1_201) < 1)
    }

    // MARK: GeoHash

    @Test func geohashesEncodeAndDecode() {
        let point = Coordinate(latitude: 57.64911, longitude: 10.40744)
        #expect(GeoHash.encode(point, precision: 11) == "u4pruydqqvj")
        let centre = GeoHash.center("u4pruydqqvj")
        #expect(abs(centre.latitude - point.latitude) < 0.00001 && abs(centre.longitude - point.longitude) < 0.00001)
        // A precision-7 cell is about 153 m across, so its centre is within ~110 m of any point in it.
        let park = Coordinate(latitude: 24.7590, longitude: 46.6440)
        let cell = GeoHash.encode(park, precision: 7)
        #expect(cell.count == 7)
        #expect(GeoHash.center(cell).distance(to: park) < 110)
        #expect(GeoHash.encode(GeoHash.center(cell), precision: 7) == cell)
        // Decoding stops at a character outside the alphabet.
        #expect(GeoHash.center(String(cell.prefix(5)) + "a") == GeoHash.center(String(cell.prefix(5))))
    }

    @Test func neighboursSurroundTheCellAndWrapAtTheAntimeridian() {
        let cell = GeoHash.encode(Coordinate(latitude: 24.7590, longitude: 46.6440), precision: 6)
        let around = GeoHash.neighbours(cell)
        #expect(around.count == 8)
        #expect(Set(around).count == 8 && !around.contains(cell))
        for neighbour in around {
            let a = GeoHash.center(neighbour), b = GeoHash.center(cell)
            #expect(abs(a.latitude - b.latitude) < 0.01 && abs(a.longitude - b.longitude) < 0.02)
        }
        // The cell touching 180° has neighbours just east of −180°.
        let east = GeoHash.encode(Coordinate(latitude: -16.8, longitude: 179.99), precision: 5)
        let wrapped = GeoHash.neighbours(east)
        #expect(wrapped.count == 8)
        #expect(wrapped.contains(GeoHash.encode(Coordinate(latitude: -16.8, longitude: -179.99), precision: 5)))
        #expect(wrapped.filter { GeoHash.center($0).longitude < 0 }.count == 3)
        // Near a pole there is no row beyond.
        #expect(GeoHash.neighbours(GeoHash.encode(Coordinate(latitude: 89.99, longitude: 0), precision: 3)).count == 5)
    }

    // MARK: PlaceNames

    @Test(arguments: [
        ("Ad Dir‘īyah", "ad diriyah"), ("Ad Dir'iyah", "ad diriyah"), ("AD-DIRIYAH", "ad diriyah"), ("Al-Nakheel Park", "al nakheel park"),
        ("Ar Riyāḑ", "ar riyad"), ("  São   Paulo!! ", "sao paulo"), ("Zürich", "zurich"), ("Irákleion", "irakleion"), ("AlUla", "alula"),
        ("Al-`Ula", "al ula"), ("Xi’an", "xian"), ("Ta’if", "taif"), ("Côte d’Ivoire", "cote divoire"), ("´Accent", "accent"),
        ("St. Kitts & Nevis", "st kitts nevis"), ("1st Street", "1st street"), ("الرياض", "الرياض"), ("Nuku‘alofa", "nukualofa"), ("", ""),
    ])
    func namesFold(_ name: String, _ folded: String) {
        #expect(PlaceNames.fold(name) == folded)
        #expect(PlaceNames.fold(folded) == folded)
    }

    @Test func variantsDropALeadingArabicArticle() {
        #expect(PlaceNames.variants("Ad Dir'iyah") == ["ad diriyah", "diriyah"])
        #expect(PlaceNames.variants("Al-Nakheel Park") == ["al nakheel park", "nakheel park"])
        #expect(PlaceNames.variants("Ash Shamiyah") == ["ash shamiyah", "shamiyah"])
        #expect(PlaceNames.variants("Al Ain") == ["al ain", "ain"])
        #expect(PlaceNames.variants("As Sa") == ["as sa"])          // fewer than 3 characters would remain
        #expect(PlaceNames.variants("Alula") == ["alula"])         // not a separate word
        #expect(PlaceNames.variants("Riyadh") == ["riyadh"])
        #expect(PlaceNames.variants("Al") == ["al"])
        #expect(PlaceNames.variants("!!").isEmpty)
    }

    // MARK: CountryNames

    @Test func countriesHaveEnglishNamesAndSynonyms() {
        #expect(CountryNames.name("AE") == "United Arab Emirates")
        #expect(CountryNames.name("SA") == "Saudi Arabia")
        #expect(CountryNames.name("ZZZ") == "ZZZ")
        #expect(CountryNames.codes(matching: "uae") == ["AE"])
        #expect(CountryNames.codes(matching: "ksa") == ["SA"])
        #expect(CountryNames.codes(matching: "saudi arabia") == ["SA"])
        #expect(CountryNames.codes(matching: "holland") == ["NL"])
        #expect(CountryNames.codes(matching: "netherlands") == ["NL"])
        #expect(CountryNames.codes(matching: "united kingdom") == ["GB"])
        #expect(CountryNames.codes(matching: "uk") == ["GB"])
        #expect(CountryNames.codes(matching: "usa") == ["US"])
        #expect(CountryNames.codes(matching: "greece") == ["GR"])
        #expect(CountryNames.codes(matching: "turkey") == ["TR"])
        #expect(CountryNames.codes(matching: "burma") == ["MM"])
        #expect(CountryNames.codes(matching: "myanmar") == ["MM"])
        #expect(CountryNames.codes(matching: "bosnia and herzegovina") == ["BA"])
        #expect(CountryNames.codes(matching: "congo") == ["CD", "CG"])
        #expect(CountryNames.codes(matching: PlaceNames.fold("Côte d’Ivoire")) == ["CI"])
        #expect(CountryNames.codes(matching: "riyadh").isEmpty)
        #expect(CountryNames.codes(matching: "").isEmpty)
    }

    // MARK: PlaceCategory

    @Test func categoriesHaveTheSpecRadii() {
        let expected: [PlaceCategory: Double] = [
            .restaurant: 75, .cafe: 75, .bakery: 75, .store: 100, .foodMarket: 100, .fitness: 100, .address: 100,
            .hotel: 150, .home: 150, .otherPOI: 150, .museum: 200, .landmark: 200, .castle: 200, .school: 200,
            .sportsField: 250, .stadium: 250, .marina: 300, .park: 400, .campground: 400, .zoo: 500, .amusementPark: 500,
            .beach: 500, .university: 500, .golf: 600, .airport: 2_000, .nationalPark: 3_000, .hiking: 3_000,
            .physicalFeature: 3_000, .locality: 3_000, .saved: 250,
        ]
        #expect(Set(expected.keys) == Set(PlaceCategory.allCases))
        for category in PlaceCategory.allCases { #expect(category.defaultRadius == expected[category], "\(category)") }
        // Search results with a region use its half-diagonal, clamped to 2–30 km; POIs never do.
        #expect(PlaceCategory.physicalFeature.radius(boundingRadius: 500) == 2_000)
        #expect(PlaceCategory.physicalFeature.radius(boundingRadius: 10_000) == 10_000)
        #expect(PlaceCategory.locality.radius(boundingRadius: 90_000) == 30_000)
        #expect(PlaceCategory.locality.radius(boundingRadius: nil) == 3_000)
        #expect(PlaceCategory.park.radius(boundingRadius: 9_000) == 400)
        #expect(PlaceCategory.savedRadii == [100, 250, 1_000])
        #expect(PlaceCategory.park.isArea && PlaceCategory.beach.isArea && PlaceCategory.landmark.isArea)
        #expect(!PlaceCategory.restaurant.isArea && !PlaceCategory.store.isArea && !PlaceCategory.hotel.isArea)
    }

    // MARK: FakeMapsClient

    @Test func theFakeMapsClientAnswersFromItsTableAndLogsCalls() async throws {
        let park = MapPlace(appleID: "park", name: "Al-Nakheel Park", category: .park, coordinate: Coordinate(latitude: 24.7590, longitude: 46.6440))
        let cafe = MapPlace(name: "Corner Cafe", category: .cafe, coordinate: Coordinate(latitude: 24.7595, longitude: 46.6445))
        let far = MapPlace(name: "Salam Park", category: .park, coordinate: Coordinate(latitude: 24.6236, longitude: 46.7070))
        let mykonos = Coordinate(latitude: 37.4467, longitude: 25.3289)
        let maps = FakeMapsClient(FakeMapsClient.Table(
            places: [far, cafe, park],
            addresses: [.init(mykonos, MapAddress(cityName: "Mykonos", countryCode: "GR"))],
            searches: ["Al-Nakheel Park": [park]]))
        let centre = Coordinate(latitude: 24.7592, longitude: 46.6442)

        #expect(try await maps.pointsOfInterest(near: centre, radius: 500, categories: PlaceCategory.areas) == [park])
        #expect(try await maps.pointsOfInterest(near: centre, radius: 500, categories: []).map(\.name) == ["Al-Nakheel Park", "Corner Cafe"])
        await #expect(throws: MapsError.notFound) { try await maps.pointsOfInterest(near: centre, radius: 500, categories: [.beach]) }
        #expect(try await maps.reverseGeocode(Coordinate(latitude: 37.45, longitude: 25.33)) == MapAddress(cityName: "Mykonos", countryCode: "GR"))
        await #expect(throws: MapsError.notFound) { try await maps.reverseGeocode(centre) }
        #expect(try await maps.search("al nakheel park", near: nil) == [park])
        await #expect(throws: MapsError.notFound) { try await maps.search("shawarma", near: nil) }
        #expect(maps.calls.count == 7)
        #expect(maps.calls.first == .pointsOfInterest(centre, radius: 500, categories: PlaceCategory.areas))
        #expect(maps.calls.last == .search("shawarma", nil))
    }

    @Test func theFakeMapsClientCanBeThrottledOrOffline() async throws {
        let maps = FakeMapsClient(FakeMapsClient.Table(searches: ["Paris": [MapPlace(name: "Paris", category: .locality,
                                                                                         coordinate: Coordinate(latitude: 48.8566, longitude: 2.3522),
                                                                                         kind: .locality)]]))
        maps.failNext(.offline)
        await #expect(throws: MapsError.offline) { try await maps.search("Paris", near: nil) }
        #expect(try await maps.search("Paris", near: nil).count == 1)
        maps.setFailure(.throttled)
        await #expect(throws: MapsError.throttled) { try await maps.search("Paris", near: nil) }
        await #expect(throws: MapsError.throttled) { try await maps.reverseGeocode(Coordinate(latitude: 1, longitude: 1)) }
        maps.setFailure(nil)
        #expect(try await maps.search("paris", near: GeoRegion(center: Coordinate(latitude: 24.7, longitude: 46.7), spanDegrees: 4)).count == 1)
        #expect(maps.calls.count == 5)
    }
}
