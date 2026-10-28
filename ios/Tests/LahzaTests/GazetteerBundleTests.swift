import Foundation
import LZGeo
import Testing

/// The offline place list ships inside the app and answers on the iOS runtime.
@Suite struct GazetteerBundleTests {
    @Test func theBundledGazetteerLoadsAndLocatesRiyadh() throws {
        let gazetteer = try Gazetteer.bundled()
        #expect(gazetteer.sourceDate == 20261028)
        let park = gazetteer.locate(Coordinate(latitude: 24.7590, longitude: 46.6440))
        #expect(park.city?.name == "Riyadh")
        #expect(park.timeZone == "Asia/Riyadh")
        #expect(gazetteer.cities(named: "mecca", limit: 1).first?.name == "Makkah")
    }

    @Test func theGeoNamesCreditShipsWithTheApp() throws {
        let url = try #require(Bundle.main.url(forResource: "GeoNames-CC-BY-4.0", withExtension: "txt"))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("creativecommons.org/licenses/by/4.0"))
    }
}
